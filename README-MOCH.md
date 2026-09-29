# Moch Backend

The backend that powers the **Moch** mobile app — a focused distribution of
[hermes-agent](https://github.com/NousResearch/hermes-agent) (MIT, © 2025 Nous
Research) that runs one thing well: the WebSocket gateway your phone pairs
with. No chat-platform integrations, no interactive CLI wizard, no browser or
computer-use tooling — the phone is the only client.

## Install

One command, then scan the QR it prints. Pick whichever route you have tools for:

```bash
# npm
npm install -g moch-backend && moch-backend

# bun (same package, bun's global install)
bun install -g moch-backend && moch-backend

# plain shell — nothing but curl and git needed
curl -fsSL https://raw.githubusercontent.com/SoftLand-Tech/moch/main/scripts/install.sh | bash
```

That single command:

1. clones this repo to `~/.moch/moch-backend` and installs the locked
   dependency environment (via uv + the repo's package manager),
2. prepares `~/.moch` (config, sessions, skills…),
3. generates a persistent pairing token → `~/.config/moch-serve.env`,
4. installs and starts systemd user units:
   - `moch-serve.service` — `serve` on `127.0.0.1:9222` (the gateway's
     static-token WS auth is loopback-only by upstream design),
   - `moch-proxy.service` — `scripts/moch-proxy.js` on `0.0.0.0:9223`,
     the phone-facing port; rewrites Host so LAN/Tailnet clients pass the
     backend's host-header defence (same pattern as a tailscale-serve setup),
   - `moch-cron.timer` — one `cron tick` per minute (scheduled jobs without
     the always-on messaging gateway),
5. installs the `moch` command, and
6. prints a **QR code** to pair the app.

Then add a model provider key (once): `moch auth login`.

### Pairing

The QR encodes `moch://pair?host=<lan-ip>&port=9223&tls=0&token=<token>`.
Until in-app QR scanning ships, enter the two printed values manually in the
app's pair form — Host `192.168.x.x:9223`, Token from the QR caption
(`moch qr` reprints it anytime).

- **Away from home?** Use Tailscale: `tailscale serve --bg tcp:9223`, then pair
  with `<machine>.tailnet.ts.net:443` (tls on).
- **Headless server?** `sudo loginctl enable-linger $USER` so the user units
  start at boot.

## Layout

| Path | What |
|---|---|
| `~/.moch/` | `HERMES_HOME` — config.yaml, sessions, skills, logs |
| `~/.moch/moch-backend/` | this repo + managed runtimes (`.hermes/bin/hermes`) |
| `~/.config/moch-serve.env` | pairing token (`HERMES_DASHBOARD_SESSION_TOKEN`) |
| `~/.config/systemd/user/moch-*` | serve (9222 loopback), proxy (9223 LAN), cron timer |
| `~/.local/bin/moch` | `moch` command wrapper (serve/status/qr/auth/…) |

`hermes` the command is never installed or touched — `cli.expose_on_path:
false` is written into `~/.moch/config.yaml`, so a pre-existing hermes
install on the same machine (default port 9119) keeps working untouched.

## Useful commands

```bash
moch qr               # pairing QR + token
moch status           # service + port health
journalctl --user -u moch-serve.service -f
scripts/moch-serve.sh uninstall [--purge]
```

## Staying close to upstream

This fork intentionally carries a **tiny diff** (installer specialization +
`moch-serve.sh`; zero Python changes so far), so syncing upstream is cheap:

```bash
git remote add upstream https://github.com/NousResearch/hermes-agent.git
git config rerere.enabled true
git fetch upstream && git merge upstream/main
```

The hermes MIT license and copyright notice are retained in `LICENSE`.
