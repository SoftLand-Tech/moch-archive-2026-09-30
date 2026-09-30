#!/bin/bash
# ============================================================================
# Moch — mobile backend setup & control
# ============================================================================
# Turns a fresh `moch-backend` install into a running phone-ready backend:
#   • generates a persistent pairing token   (~/.config/moch-serve.env)
#   • installs service units for the platform:
#     Linux: systemd user units
#       moch-serve.service  — `serve` on 127.0.0.1:<port> (token auth is
#                             loopback-only in hermes >= 0.21.3)
#       moch-proxy.service  — scripts/moch-proxy.js on 0.0.0.0:<proxy-port>,
#                             rewriting Host so phones on LAN/Tailnet can pair
#       moch-cron.timer     — one `cron tick` per minute (scheduled jobs
#                             without the always-on messaging gateway)
#     macOS: the same three as launchd agents in ~/Library/LaunchAgents
#       (com.moch.serve / com.moch.proxy / com.moch.cron)
#   • links the machine to a Tailscale tailnet (best-effort, no root):
#       Linux  — static tailscaled into ~/.local/bin + systemd user unit
#       macOS  — binaries via Homebrew (no sudo), run as our own rootless
#                userspace launchd agent (com.moch.tailscaled); an existing
#                system tailscale / Mac App Store install is detected and used
#       tailscale serve     — publishes wss://<host>.ts.net → the proxy, so
#                             the phone pairs over the tailnet from ANY
#                             network (Wi-Fi, mobile data, away from home)
#   • installs the `moch` command            (~/.local/bin/moch)
#   • starts everything and prints a QR code to pair the mobile app
#
# Usage:
#   scripts/moch-serve.sh setup   # default; idempotent — safe to re-run
#   scripts/moch-serve.sh status | restart | stop
#   scripts/moch-serve.sh qr      # reprint the pairing QR + token
#   scripts/moch-serve.sh uninstall [--purge]
#
# Environment:
#   MOCH_PORT        backend port on loopback   (default 9222)
#   MOCH_PROXY_PORT  phone-facing proxy port    (default 9223)
#   MOCH_NO_TAILSCALE=1  skip the tailscale/remote step (LAN pairing only)
#
# The hermes internals stay as installed; this script only layers the mobile
# service on top and never touches a ~/.hermes install or its `hermes` command.
# ============================================================================

set -euo pipefail

MOCH_HOME="${HERMES_HOME:-$HOME/.moch}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$MOCH_HOME/moch-backend"
MOCH_CMD="$INSTALL_DIR/.hermes/bin/hermes"
ENV_FILE="$HOME/.config/moch-serve.env"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_DIR="$HOME/.local/bin"
MOCH_PORT="${MOCH_PORT:-9222}"
MOCH_PROXY_PORT="${MOCH_PROXY_PORT:-9223}"
MOCH_COMMAND="${MOCH_COMMAND:-moch}"

# Tailscale (remote pairing over a private tailnet). Pinned static build; the
# userspace daemon needs no root and no /dev/tun, so it installs cleanly
# beside a system tailscale without touching it.
TS_VERSION="1.102.3"
TS_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/tailscaled.sock"
TS_STATE_DIR="$HOME/.local/share/tailscale"
TS_SOCKS_PORT=1055
TS_CLI=""          # resolved by ts_find_daemon
TS_HOST=""         # this machine's <name>.ts.net once linked + serving

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[moch]${NC} $*"; }
log_success() { echo -e "${GREEN}[moch ✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[moch !]${NC} $*"; }
log_error()   { echo -e "${RED}[moch ✗]${NC} $*" >&2; }

require_install() {
    if [ ! -x "$MOCH_CMD" ]; then
        log_error "No Moch install found at $INSTALL_DIR (missing .hermes/bin/hermes)."
        log_error "Run the installer first:  curl -fsSL <moch install.sh> | bash"
        exit 1
    fi
}

# The checkout launcher is `exec <store-python> -I -c <script>` (path bare or
# quoted); the managed interpreter on that line carries the dependency
# environment under an HERMES_HOME-scoped tools prefix.
store_python() {
    local py
    py="$(awk '/^exec /{print $2; exit}' "$MOCH_CMD" 2>/dev/null)"
    py="${py%\'}"; py="${py#\'}"; py="${py%\"}"; py="${py#\"}"
    if [ -n "$py" ] && [ -x "$py" ]; then
        printf '%s' "$py"
        return 0
    fi
    return 1
}

# Node for the proxy: prefer the system one, else pm's managed runtime.
node_bin() {
    local n
    if n="$(command -v node)"; then printf '%s' "$n"; return 0; fi
    n="$(ls -d "$MOCH_HOME"/tools/node-*/bin/node 2>/dev/null | sort -V | tail -1)"
    if [ -n "$n" ] && [ -x "$n" ]; then printf '%s' "$n"; return 0; fi
    return 1
}

lan_ip() {
    case "$(uname -s)" in
        Darwin)
            # en0 is the default on modern macs; en1 covers USB adapters.
            ipconfig getifaddr en0 2>/dev/null \
                || ipconfig getifaddr en1 2>/dev/null \
                || echo "127.0.0.1"
            ;;
        *)
            ip -4 route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' \
                || hostname -I 2>/dev/null | awk '{print $1; exit}' \
                || echo "127.0.0.1"
            ;;
    esac
}

# ---- Tailscale: pairing that works from ANY network -------------------------
# The tailnet name gives the phone a wss:// endpoint with a real TLS cert,
# reachable over WireGuard from any network — no router ports, no public
# exposure. Every step is best-effort: on any failure the QR stays LAN-only.
ts_ctl() {
    # TS_NO_SOCKET=1 → CLI's own default transport (macOS GUI-app variant
    # owns its socket; passing --socket there breaks it).
    if [ "${TS_NO_SOCKET:-0}" = "1" ]; then "$TS_CLI" "$@"; else "$TS_CLI" --socket="$TS_SOCKET" "$@"; fi
}

# Daemon state string ("Running", "NeedsLogin", …); empty output = unreachable.
ts_backend_state() {
    ts_ctl status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1
}

ts_dns_name() {
    ts_ctl status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -1 | sed 's/\.$//'
}

# Find a live daemon: ours (user socket) first, then a system tailscaled
# (default socket), then the CLI's own default (macOS Tailscale.app). Checks
# each candidate CLI against every transport before moving to the next.
ts_find_daemon() {
    if [ -n "$TS_CLI" ]; then return 0; fi
    local c
    for c in "$BIN_DIR/tailscale" "$(command -v tailscale || true)" \
             "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
        [ -n "$c" ] && [ -x "$c" ] || continue
        TS_CLI="$c"; TS_NO_SOCKET=0
        TS_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/tailscaled.sock"
        [ -n "$(ts_backend_state)" ] && return 0
        TS_SOCKET="/var/run/tailscale/tailscaled.sock"
        [ -n "$(ts_backend_state)" ] && return 0
        TS_NO_SOCKET=1
        [ -n "$("$TS_CLI" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1)" ] && return 0
        TS_NO_SOCKET=0
    done
    TS_CLI=""
    TS_SOCKET="${XDG_RUNTIME_DIR:-/tmp}/tailscaled.sock"
    return 1
}

install_tailscale_user() {
    case "$(uname -s)" in
        Linux)  install_tailscale_linux ;;
        Darwin) install_tailscale_darwin ;;
        *) log_info "No tailscale auto-install for $(uname -s) — LAN pairing only."; return 1 ;;
    esac
}

install_tailscale_linux() {
    local arch tgz tmp dir
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        armv7l|armv6l) arch=arm ;;
        *) log_info "No tailscale static build for $(uname -m) — LAN pairing only."; return 1 ;;
    esac
    mkdir -p "$BIN_DIR"
    if [ ! -x "$BIN_DIR/tailscaled" ] || [ ! -x "$BIN_DIR/tailscale" ]; then
        tgz="tailscale_${TS_VERSION}_${arch}.tgz"
        tmp="$(mktemp -d)"
        log_info "Downloading tailscale $TS_VERSION ($arch) — one time…"
        curl -fsSL "https://pkgs.tailscale.com/stable/$tgz" -o "$tmp/$tgz" \
            || { log_warn "tailscale download failed — LAN pairing only."; rm -rf "$tmp"; return 1; }
        tar -xzf "$tmp/$tgz" -C "$tmp" || { rm -rf "$tmp"; return 1; }
        dir="$tmp/tailscale_${TS_VERSION}_${arch}"
        install -m755 "$dir/tailscale"  "$BIN_DIR/tailscale"
        install -m755 "$dir/tailscaled" "$BIN_DIR/tailscaled"
        rm -rf "$tmp"
        log_success "Installed tailscale → $BIN_DIR"
    fi
    mkdir -p "$UNIT_DIR" "$TS_STATE_DIR"
    cat > "$UNIT_DIR/tailscaled.service" <<EOF
[Unit]
Description=Moch tailscale daemon (userspace networking, no root)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN_DIR/tailscaled --tun=userspace-networking --socket=$TS_SOCKET --statedir=$TS_STATE_DIR --socks5-server=localhost:$TS_SOCKS_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now tailscaled.service >/dev/null 2>&1 \
        || { log_warn "tailscaled failed to start — LAN pairing only."; return 1; }
    TS_CLI="$BIN_DIR/tailscale"
    local i
    for i in $(seq 1 10); do
        [ -n "$(ts_backend_state)" ] && return 0
        sleep 1
    done
    log_warn "tailscaled not responding — LAN pairing only."
    return 1
}

install_tailscale_darwin() {
    # Homebrew only FETCHES the binaries — brew's own service runs tailscaled
    # as root, which we don't want. We run the binaries as our own rootless
    # userspace launchd agent, mirroring the Linux user unit exactly.
    if ! command -v brew >/dev/null 2>&1; then
        log_info "macOS: install Homebrew (https://brew.sh) or the Tailscale app"
        log_info "from the Mac App Store, then re-run: moch  (LAN pairing meanwhile)"
        return 1
    fi
    if ! command -v tailscaled >/dev/null 2>&1; then
        log_info "Installing tailscale via Homebrew (one time)…"
        brew install tailscale \
            || { log_warn "brew install failed — LAN pairing only."; return 1; }
        log_success "tailscale installed via Homebrew"
    fi
    local bin
    bin="$(dirname "$(command -v tailscaled)")"
    mkdir -p "$TS_STATE_DIR" "$HOME/Library/LaunchAgents"
    cat > "$HOME/Library/LaunchAgents/com.moch.tailscaled.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.moch.tailscaled</string>
    <key>ProgramArguments</key>
    <array>
        <string>$bin/tailscaled</string>
        <string>--tun=userspace-networking</string>
        <string>--socket=$TS_SOCKET</string>
        <string>--statedir=$TS_STATE_DIR</string>
        <string>--socks5-server=localhost:$TS_SOCKS_PORT</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>$TS_STATE_DIR/tailscaled.log</string>
    <key>StandardErrorPath</key><string>$TS_STATE_DIR/tailscaled.log</string>
</dict>
</plist>
EOF
    launchctl_load com.moch.tailscaled \
        || { log_warn "tailscaled launch agent failed to load — LAN pairing only."; return 1; }
    TS_CLI="$bin/tailscale"
    local i
    for i in $(seq 1 10); do
        [ -n "$(ts_backend_state)" ] && return 0
        sleep 1
    done
    log_warn "tailscaled not responding — LAN pairing only."
    return 1
}

# Set TS_HOST when a linked tailnet is available (no side effects).
ts_pair_host() {
    ts_find_daemon || return 1
    [ "$(ts_backend_state)" = "Running" ] || return 1
    TS_HOST="$(ts_dns_name)"
    [ -n "$TS_HOST" ]
}

# Full wiring: daemon (install if missing) → login if needed → serve → TS_HOST.
ensure_tailscale() {
    [ "${MOCH_NO_TAILSCALE:-0}" = "1" ] && { log_info "Tailscale skipped (MOCH_NO_TAILSCALE=1)."; return 0; }
    ts_find_daemon || install_tailscale_user || return 0
    ts_find_daemon || return 0
    if [ "$(ts_backend_state)" != "Running" ]; then
        if [ -t 0 ] && (: </dev/tty) 2>/dev/null; then
            log_info "One-time tailnet sign-in — open the URL printed below in any browser:"
            ts_ctl up --timeout=180s \
                || { log_warn "Login not finished — LAN pairing for now. Re-run \`moch\` to retry."; return 0; }
        else
            local url out i
            out="$(ts_ctl up --timeout=10s 2>&1 || true)"
            url="$(printf '%s' "$out" | sed -n 's/.*\(https:\/\/login\.tailscale\.com[^ ]*\).*/\1/p' | head -1)"
            log_info "Remote pairing needs a one-time tailscale sign-in:"
            if [ -n "$url" ]; then
                log_info "  open this in any browser — sign in (or create a free"
                log_info "  account) with the SAME account the phone's Tailscale"
                log_info "  app will use:"
                echo
                echo -e "    ${BOLD}$url${NC}"
                echo
                log_info "  waiting up to 2 min for the sign-in… (re-run \`moch\` anytime later)"
                for i in $(seq 1 24); do
                    sleep 5
                    [ "$(ts_backend_state)" = "Running" ] && break
                done
                if [ "$(ts_backend_state)" != "Running" ]; then
                    log_warn "Login not finished yet — LAN pairing for now. Open the link above, then re-run: moch"
                    return 0
                fi
            else
                log_info "  run \`moch\` in a terminal to sign in."
                return 0
            fi
        fi
    fi
    if ts_ctl serve --bg "http://127.0.0.1:$MOCH_PROXY_PORT" >/dev/null 2>&1; then
        log_success "tailscale serve active — pairing works from ANY network"
    else
        log_warn "tailscale serve failed — QR stays LAN-only."
        return 0
    fi
    TS_HOST="$(ts_dns_name)"
    [ -n "$TS_HOST" ] && log_success "Tailnet host: $TS_HOST"
}

ensure_token() {
    mkdir -p "$(dirname "$ENV_FILE")"
    chmod 700 "$(dirname "$ENV_FILE")"
    if [ -f "$ENV_FILE" ] && grep -q '^HERMES_DASHBOARD_SESSION_TOKEN=' "$ENV_FILE"; then
        log_info "Pairing token already present ($ENV_FILE)"
        return
    fi
    # Shell equivalent of secrets.token_urlsafe(32): 32 random bytes, base64url.
    local token
    token="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')"
    cat > "$ENV_FILE" <<EOF
# Moch backend secrets — generated by moch-serve.sh. Do not commit.
HERMES_DASHBOARD_SESSION_TOKEN=$token
EOF
    chmod 600 "$ENV_FILE"
    log_success "Generated new pairing token → $ENV_FILE"
}

token_value() { sed -n 's/^HERMES_DASHBOARD_SESSION_TOKEN=//p' "$ENV_FILE" | head -1; }

install_moch_command() {
    # npm/bun installs already put a `moch` shim on PATH (the package's bin);
    # writing ours too would leave two `moch` commands shadowing each other.
    if command -v "$MOCH_COMMAND" >/dev/null 2>&1; then
        log_info "\`$MOCH_COMMAND\` already on PATH ($(command -v "$MOCH_COMMAND")) — leaving it alone"
        return 0
    fi
    mkdir -p "$BIN_DIR"
    # Same routing as the npm shim: control subcommands → moch-serve.sh,
    # bare `moch` → the node wizard when possible (nicer for non-terminal
    # people), anything else → the backend's own CLI.
    cat > "$BIN_DIR/$MOCH_COMMAND" <<EOF
#!/usr/bin/env bash
case "\$1" in
  "")
    if command -v node >/dev/null 2>&1 && [ -f "$INSTALL_DIR/npm/bin/moch.js" ]; then
      exec node "$INSTALL_DIR/npm/bin/moch.js" "\$@"
    fi
    exec "$INSTALL_DIR/scripts/moch-serve.sh" setup ;;
  setup|status|restart|stop|qr|import-hermes|uninstall) exec "$INSTALL_DIR/scripts/moch-serve.sh" "\$@" ;;
  *) export HERMES_HOME="$MOCH_HOME"; exec "$MOCH_CMD" "\$@" ;;
esac
EOF
    chmod +x "$BIN_DIR/$MOCH_COMMAND"
    log_success "Installed \`$MOCH_COMMAND\` command → $BIN_DIR/$MOCH_COMMAND"
}

install_units() {
    local node
    if ! node="$(node_bin)"; then
        log_error "No node found (system or managed) — the phone proxy needs it."
        exit 1
    fi
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/moch-serve.service" <<EOF
[Unit]
Description=Moch backend (WebSocket gateway for the Moch mobile app)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ENV_FILE
Environment=HERMES_HOME=$MOCH_HOME
WorkingDirectory=$MOCH_HOME
ExecStart=$MOCH_CMD serve --host 127.0.0.1 --port $MOCH_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    cat > "$UNIT_DIR/moch-proxy.service" <<EOF
[Unit]
Description=Moch phone proxy (LAN/Tailnet -> loopback, Host rewrite)
After=moch-serve.service
Wants=moch-serve.service

[Service]
Environment=PORT=$MOCH_PROXY_PORT
Environment=UPSTREAM_PORT=$MOCH_PORT
ExecStart=$node $INSTALL_DIR/scripts/moch-proxy.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    # Without the always-on messaging gateway, scheduled jobs tick from here.
    cat > "$UNIT_DIR/moch-cron.service" <<EOF
[Unit]
Description=Moch scheduled jobs (one cron tick)

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment=HERMES_HOME=$MOCH_HOME
WorkingDirectory=$MOCH_HOME
ExecStart=$MOCH_CMD cron tick
EOF
    cat > "$UNIT_DIR/moch-cron.timer" <<EOF
[Unit]
Description=Run Moch cron ticks every minute

[Timer]
OnBootSec=90
OnCalendar=*-*-* *:*:00
AccuracySec=15
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl --user daemon-reload
    log_success "Installed systemd user units (moch-serve, moch-proxy, moch-cron.timer)"
    # User units only run at boot while the user has a session — or lingering.
    if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q '^Linger=yes'; then
        log_info "Headless server? Enable boot startup with:  sudo loginctl enable-linger $USER"
    fi
}

port_open() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1" && exec 3>&-) 2>/dev/null
}

# ---- macOS: launchd agents instead of systemd user units --------------------
LA_DIR="$HOME/Library/LaunchAgents"
MOCH_LABELS="com.moch.serve com.moch.proxy com.moch.cron"

launchctl_load() {
    local label="$1"
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$LA_DIR/$label.plist" \
        || launchctl load -w "$LA_DIR/$label.plist" \
        || { log_warn "$label failed to load"; return 1; }
}

launchctl_unload() {
    launchctl bootout "gui/$(id -u)/$1" >/dev/null 2>&1 \
        || launchctl unload -w "$LA_DIR/$1.plist" >/dev/null 2>&1 || true
}

plist_head() { # label logfile -> common plist skeleton on stdout
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n'
    printf '    <key>Label</key><string>%s</string>\n' "$1"
    printf '    <key>StandardOutPath</key><string>%s</string>\n' "$2"
    printf '    <key>StandardErrorPath</key><string>%s</string>\n' "$2"
}

plist_tail() { printf '</dict>\n</plist>\n'; }

install_units_darwin() {
    local node token
    if ! node="$(node_bin)"; then
        log_error "No node found (system or managed) — the phone proxy needs it."
        exit 1
    fi
    token="$(token_value)"
    mkdir -p "$LA_DIR" "$MOCH_HOME/logs"

    # Backend — the pairing token must ride the plist (launchd has no
    # EnvironmentFile); the file is chmod 600 like the env file itself.
    { plist_head com.moch.serve "$MOCH_HOME/logs/moch-serve.launchd.log"
      printf '    <key>ProgramArguments</key>\n    <array>\n'
      printf '        <string>%s</string>\n        <string>serve</string>\n' "$MOCH_CMD"
      printf '        <string>--host</string>\n        <string>127.0.0.1</string>\n'
      printf '        <string>--port</string>\n        <string>%s</string>\n    </array>\n' "$MOCH_PORT"
      printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
      printf '        <key>HERMES_HOME</key><string>%s</string>\n' "$MOCH_HOME"
      printf '        <key>HERMES_DASHBOARD_SESSION_TOKEN</key><string>%s</string>\n' "$token"
      printf '    </dict>\n'
      printf '    <key>WorkingDirectory</key><string>%s</string>\n' "$MOCH_HOME"
      printf '    <key>RunAtLoad</key><true/>\n    <key>KeepAlive</key><true/>\n'
      plist_tail; } > "$LA_DIR/com.moch.serve.plist"
    chmod 600 "$LA_DIR/com.moch.serve.plist"

    # Phone-facing proxy
    { plist_head com.moch.proxy "$MOCH_HOME/logs/moch-proxy.launchd.log"
      printf '    <key>ProgramArguments</key>\n    <array>\n'
      printf '        <string>%s</string>\n        <string>%s/scripts/moch-proxy.js</string>\n    </array>\n' "$node" "$INSTALL_DIR"
      printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
      printf '        <key>PORT</key><string>%s</string>\n' "$MOCH_PROXY_PORT"
      printf '        <key>UPSTREAM_PORT</key><string>%s</string>\n' "$MOCH_PORT"
      printf '    </dict>\n'
      printf '    <key>RunAtLoad</key><true/>\n    <key>KeepAlive</key><true/>\n'
      plist_tail; } > "$LA_DIR/com.moch.proxy.plist"

    # Scheduled jobs — one tick per minute (launchd has no */1 cron sugar;
    # an explicit Minute list does the same).
    { plist_head com.moch.cron "$MOCH_HOME/logs/moch-cron.launchd.log"
      printf '    <key>ProgramArguments</key>\n    <array>\n'
      printf '        <string>%s</string>\n        <string>cron</string>\n        <string>tick</string>\n    </array>\n' "$MOCH_CMD"
      printf '    <key>EnvironmentVariables</key>\n    <dict>\n'
      printf '        <key>HERMES_HOME</key><string>%s</string>\n' "$MOCH_HOME"
      printf '        <key>HERMES_DASHBOARD_SESSION_TOKEN</key><string>%s</string>\n' "$token"
      printf '    </dict>\n'
      printf '    <key>WorkingDirectory</key><string>%s</string>\n' "$MOCH_HOME"
      printf '    <key>StartCalendarInterval</key>\n    <array>\n'
      local m
      for m in $(seq 0 59); do
          printf '        <dict><key>Minute</key><integer>%s</integer></dict>\n' "$m"
      done
      printf '    </array>\n'
      plist_tail; } > "$LA_DIR/com.moch.cron.plist"

    local u ok=0
    for u in $MOCH_LABELS; do launchctl_load "$u" || ok=1; done
    [ "$ok" = 0 ] && log_success "Installed launchd agents (com.moch.serve, com.moch.proxy, com.moch.cron)"
    return 0
}

start_services_darwin() {
    local i
    for i in $(seq 1 30); do
        if port_open "$MOCH_PORT" && port_open "$MOCH_PROXY_PORT"; then
            log_success "Moch backend up: loopback:$MOCH_PORT, phone-facing :$MOCH_PROXY_PORT"
            return 0
        fi
        sleep 1
    done
    log_warn "Ports not accepting yet — recent logs:"
    tail -n 15 "$MOCH_HOME/logs/moch-serve.launchd.log" "$MOCH_HOME/logs/moch-proxy.launchd.log" 2>/dev/null || true
    return 1
}


start_services() {
    # Always restart when units were rewritten: `enable --now` alone leaves an
    # already-running service on its old ExecStart/env (seen with a bind change).
    systemctl --user enable moch-serve.service moch-proxy.service moch-cron.timer >/dev/null 2>&1 || true
    systemctl --user restart moch-serve.service moch-proxy.service
    systemctl --user start moch-cron.timer >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do
        if port_open "$MOCH_PORT" && port_open "$MOCH_PROXY_PORT"; then
            log_success "Moch backend up: loopback:$MOCH_PORT, phone-facing :$MOCH_PROXY_PORT"
            return 0
        fi
        sleep 1
    done
    log_warn "Ports not accepting yet — recent logs:"
    journalctl --user -u moch-serve.service -u moch-proxy.service -n 15 --no-pager 2>/dev/null || true
    return 1
}

print_qr() {
    local lan token py qr_host qr_tls
    lan="$(lan_ip)"
    token="$(token_value)"
    # Tailnet host (set by ensure_tailscale/ts_pair_host) pairs from ANY
    # network; the LAN address only works on the same Wi-Fi.
    if [ -n "$TS_HOST" ]; then
        qr_host="$TS_HOST"; qr_tls=1
    else
        qr_host="$lan:$MOCH_PROXY_PORT"; qr_tls=0
    fi
    echo -e "${BOLD}═══════════════════════ Moch is ready ═══════════════════════${NC}"
    echo
    # Vendored dependency-free generator (scripts/vendor/qrcodegen.py, MIT,
    # © Project Nayuki) — any python3 renders it; failure never hides the token.
    py="$(store_python || command -v python3 || true)"
    if [ -n "$py" ]; then
        "$py" - "$SCRIPT_DIR/vendor" "$qr_host" "$qr_tls" "$token" <<'PY' \
            || log_warn "QR rendering failed — pair with the text values below"
import sys
sys.path.insert(0, sys.argv[1])
from qrcodegen import QrCode
payload = "hermes://connect?host=%s&tls=%s&token=%s" % tuple(sys.argv[2:5])
q = QrCode.encode_text(payload, QrCode.Ecc.MEDIUM)
b, get = q.get_size(), q.get_module
for y in range(-2, b + 2, 2):
    print("".join(
        "█" if (get(x, y) if 0 <= x < b and 0 <= y < b else False)
             and (get(x, y + 1) if 0 <= x < b and 0 <= y + 1 < b else False)
        else "▀" if (get(x, y) if 0 <= x < b and 0 <= y < b else False)
        else "▄" if (get(x, y + 1) if 0 <= x < b and 0 <= y + 1 < b else False)
        else " "
        for x in range(-2, b + 2)))
PY
    else
        log_warn "No python found — printing text pairing only."
    fi
    echo " Scan this in the Moch app — or enter manually:"
    if [ -n "$TS_HOST" ]; then
        echo " Works from ANY network (Wi-Fi, mobile data, away from home) —"
        echo " needs the Tailscale app on the phone, signed in to the SAME"
        echo " account as this machine, and connected:"
        echo -e "   Host:  ${BOLD}wss://$TS_HOST${NC}"
        echo -e "   Token: ${BOLD}$token${NC}"
        echo -e "   Link:  ${BOLD}hermes://connect?host=$TS_HOST&tls=1&token=$token${NC}"
        echo
        echo " Same Wi-Fi only, no Tailscale app needed (fallback):"
        echo -e "   Host:  ${BOLD}ws://$lan:$MOCH_PROXY_PORT${NC}"
    else
        echo -e "   Host:  ${BOLD}ws://$lan:$MOCH_PROXY_PORT${NC}  (same Wi-Fi only)"
        echo -e "   Token: ${BOLD}$token${NC}"
        echo -e "   Link:  ${BOLD}hermes://connect?host=$lan:$MOCH_PROXY_PORT&tls=0&token=$token${NC}"
        echo
        echo " Want pairing from ANY network (mobile data, away from home)?"
        echo " Install the Tailscale app on the phone, then re-run:  moch"
    fi
    echo
    echo " Next steps:"
    echo "   moch auth login    # add a model provider key (needed before chatting)"
    echo "   moch qr            # show this QR again anytime"
    echo "   moch status        # backend health"
    echo -e "${BOLD}═════════════════════════════════════════════════════════════${NC}"
}

# Machine-readable pairing state for the interactive wizard (bin/wizard.js).
# KEY=VALUE lines; HOST empty means tailnet pairing is not available yet.
cmd_pairinfo() {
    require_install
    local state="down" ts="absent" host=""
    if port_open "$MOCH_PORT" && port_open "$MOCH_PROXY_PORT"; then state="up"; fi
    if ts_find_daemon; then
        case "$(ts_backend_state)" in
            Running) ts="running" ;;
            *)       ts="needs-login" ;;
        esac
    fi
    [ "$ts" = "running" ] && host="$(ts_dns_name)"
    printf 'SERVICES=%s\nTS=%s\nHOST=%s\nLAN=%s\nTOKEN=%s\n' \
        "$state" "$ts" "$host" "$(lan_ip):$MOCH_PROXY_PORT" "$(token_value)"
}

# Link the tailnet, wizard-friendly protocol on stdout (one line per event):
#   URL <login-url>   sign-in needed — open the URL in a browser
#   LINKED <host>     linked and serve published — pairing ready from anywhere
#   FAIL <reason>     could not link (caller falls back to LAN pairing)
cmd_ts_link() {
    require_install
    local i out url h
    ts_find_daemon || install_tailscale_user || { echo "FAIL no-tailscale"; return 0; }
    ts_find_daemon || { echo "FAIL no-daemon"; return 0; }
    if [ "$(ts_backend_state)" != "Running" ]; then
        out="$(ts_ctl up --timeout=10s 2>&1 || true)"
        url="$(printf '%s' "$out" | sed -n 's/.*\(https:\/\/login\.tailscale\.com[^ ]*\).*/\1/p' | head -1)"
        [ -n "$url" ] || { echo "FAIL no-url"; return 0; }
        echo "URL $url"
        for i in $(seq 1 60); do
            sleep 5
            [ "$(ts_backend_state)" = "Running" ] && break
        done
        [ "$(ts_backend_state)" = "Running" ] || { echo "FAIL timeout"; return 0; }
    fi
    ts_ctl serve --bg "http://127.0.0.1:$MOCH_PROXY_PORT" >/dev/null 2>&1 || { echo "FAIL serve"; return 0; }
    h="$(ts_dns_name)"
    [ -n "$h" ] || { echo "FAIL dns"; return 0; }
    echo "LINKED $h"
}

# First run on a machine that already has Hermes: offer to bring its data over.
maybe_offer_hermes_import() {
    [ -d "$HOME/.hermes" ] || return 0
    [ -f "$MOCH_HOME/auth.json" ] && return 0   # already imported / own auth
    echo
    log_info "Found an existing Hermes install at ~/.hermes."
    if [ -t 0 ] && (: </dev/tty) 2>/dev/null; then
        local answer
        printf "%s Import its providers, skills, memories, cron jobs and sessions? [Y/n] " "$(printf '%s[moch]%s' "$CYAN" "$NC")"
        read -r answer </dev/tty || answer="y"
        case "$answer" in
            n*|N*)
                log_info "Skipped. Import later anytime with:  moch import-hermes"
                return 0 ;;
            *)
                bash "$SCRIPT_DIR/moch-import-hermes.sh" || true ;;
        esac
    else
        log_info "Import its data (providers/skills/memories/cron/sessions) with:"
        log_info "  moch import-hermes"
    fi
}

cmd_setup() {
    require_install
    ensure_token
    install_moch_command
    case "$(uname -s)" in
        Darwin)
            install_units_darwin
            start_services_darwin
            ;;
        *)
            if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
                install_units
                start_services
            else
                log_warn "systemd --user unavailable — skipping service install."
                log_warn "Run the backend manually:  HERMES_HOME=$MOCH_HOME $MOCH_CMD serve --host 127.0.0.1 --port $MOCH_PORT"
            fi
            ;;
    esac
    ensure_tailscale
    maybe_offer_hermes_import
    print_qr
}

cmd_status() {
    require_install
    echo -e "${BOLD}moch backend${NC}  (home: $MOCH_HOME)"
    local u ok=1
    case "$(uname -s)" in
        Darwin)
            for u in $MOCH_LABELS; do
                if launchctl print "gui/$(id -u)/$u" >/dev/null 2>&1; then
                    log_success "$u loaded"
                else
                    log_warn "$u not loaded (logs: $MOCH_HOME/logs)"
                    ok=0
                fi
            done
            ;;
        *)
            for u in moch-serve.service moch-proxy.service moch-cron.timer; do
                if systemctl --user is-active --quiet "$u" 2>/dev/null; then
                    log_success "$u active"
                else
                    log_warn "$u inactive (see: journalctl --user -u $u -n 30)"
                    ok=0
                fi
            done
            ;;
    esac
    port_open "$MOCH_PORT" && log_success "loopback:$MOCH_PORT accepting" || { log_warn "loopback:$MOCH_PORT not accepting"; ok=0; }
    port_open "$MOCH_PROXY_PORT" && log_success "phone port :$MOCH_PROXY_PORT accepting" || { log_warn "phone port :$MOCH_PROXY_PORT not accepting"; ok=0; }
    if ts_pair_host; then
        log_success "tailnet pairing: wss://$TS_HOST (works from any network)"
    else
        log_info "tailnet pairing inactive — LAN only (install tailscale + re-run setup)"
    fi
    [ "$ok" = 1 ] || exit 1
}

cmd_restart() {
    require_install
    case "$(uname -s)" in
        Darwin)
            launchctl_load com.moch.serve
            launchctl_load com.moch.proxy
            ;;
        *)
            systemctl --user restart moch-serve.service moch-proxy.service
            ;;
    esac
    log_success "restarted"
}

cmd_stop() {
    require_install
    case "$(uname -s)" in
        Darwin)
            local u
            for u in $MOCH_LABELS; do launchctl_unload "$u"; done
            ;;
        *)
            systemctl --user stop moch-serve.service moch-proxy.service moch-cron.timer
            ;;
    esac
    log_success "stopped"
}

cmd_uninstall() {
    if ts_find_daemon; then ts_ctl serve off >/dev/null 2>&1 || true; fi
    case "$(uname -s)" in
        Darwin)
            local u
            for u in $MOCH_LABELS; do launchctl_unload "$u"; done
            rm -f "$LA_DIR"/com.moch.serve.plist "$LA_DIR"/com.moch.proxy.plist "$LA_DIR"/com.moch.cron.plist
            ;;
        *)
            systemctl --user disable --now moch-serve.service moch-proxy.service moch-cron.timer >/dev/null 2>&1 || true
            rm -f "$UNIT_DIR/moch-serve.service" "$UNIT_DIR/moch-proxy.service" \
                  "$UNIT_DIR/moch-cron.service" "$UNIT_DIR/moch-cron.timer"
            ;;
    esac
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    rm -f "$BIN_DIR/$MOCH_COMMAND"
    log_success "Removed services and the \`$MOCH_COMMAND\` command."
    if [ "${1:-}" = "--purge" ]; then
        log_warn "Deleting $MOCH_HOME and $ENV_FILE (all sessions, config, history!)"
        launchctl_unload com.moch.tailscaled 2>/dev/null || true
        rm -f "$LA_DIR/com.moch.tailscaled.plist"
        rm -rf "$MOCH_HOME"
        rm -f "$ENV_FILE"
    else
        log_info "Data kept at $MOCH_HOME — re-run setup anytime, or pass --purge to delete."
    fi
}

case "${1:-setup}" in
    setup)     cmd_setup ;;
    status)    cmd_status ;;
    restart)   cmd_restart ;;
    stop)      cmd_stop ;;
    qr)        require_install; ensure_token; ts_pair_host || true; print_qr ;;
    import-hermes) shift; exec bash "$SCRIPT_DIR/moch-import-hermes.sh" "$@" ;;
    pairinfo|ts-link) "cmd_${1//-/_}" ;;
    uninstall) shift; cmd_uninstall "${1:-}" ;;
    *) echo "Usage: moch-serve.sh {setup|status|restart|stop|qr|import-hermes|uninstall [--purge]}"; exit 1 ;;
esac
