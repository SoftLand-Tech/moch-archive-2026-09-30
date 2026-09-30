#!/bin/bash
# ============================================================================
# moch import-hermes — bring an existing Hermes install into Moch
# ============================================================================
# Brings over everything that makes your agent YOURS from a hermes home:
#   • providers + env secrets  — MERGED: keys Moch already has are kept,
#     missing ones are added; providers from the Hermes side win. A fresh
#     Moch's empty auth.json skeleton no longer blocks the import.
#   • chat history             — a REAL database migration: sessions are
#     exported read-only from the Hermes state.db and imported through the
#     backend's own validated import path (existing ids skipped, idempotent).
#   • skills, memories, cron jobs, hooks, raw session dumps — file copies.
# Read-only on the source; re-runs are incremental no-clobber merges.
#
# Usage:
#   scripts/moch-import-hermes.sh [--dry-run] [--src PATH]
#
# Not migrated on purpose: config.yaml (platform bindings like WhatsApp and
# gateway ports are exactly what Moch replaces), caches, kanban state.
# ============================================================================

set -euo pipefail

MOCH_HOME="${HERMES_HOME:-$HOME/.moch}"
SRC="$HOME/.hermes"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --src) SRC="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: moch import-hermes [--dry-run] [--src PATH]"
            echo "  Merges providers (auth.json + .env), skills, memories, cron jobs,"
            echo "  chat history (state.db export->import) and hooks from a hermes"
            echo "  home (default ~/.hermes) into the Moch home ($MOCH_HOME)."
            echo "  Secrets are merged, not clobbered; sessions import is idempotent."
            exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
log_info()    { echo -e "${CYAN}[moch]${NC} $*"; }
log_success() { echo -e "${GREEN}[moch ✓]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[moch !]${NC} $*"; }

if [ ! -d "$SRC" ]; then
    log_info "No Hermes install at $SRC — nothing to import."
    exit 0
fi

DRY=""
[ "$DRY_RUN" = true ] && DRY="echo"
COPIED_FILES=0
SKIPPED_FILES=0
SECRETS_MERGED=false
SESSIONS_IMPORTED=0

copy_tree() {  # copy_tree RELATIVE_DIR LABEL
    local rel="$1" label="$2" s="$SRC/$1" d="$MOCH_HOME/$1"
    if [ ! -d "$s" ] || [ -z "$(ls -A "$s" 2>/dev/null)" ]; then
        log_warn "  $label: empty or missing in $SRC — skipped"
        return 0
    fi
    mkdir -p "$d"
    local before
    before="$(find "$d" -type f | wc -l)"
    $DRY cp -rn "$s"/. "$d"/
    local after
    after="$(find "$d" -type f | wc -l)"
    local n=$((after - before))
    if [ "$n" -gt 0 ]; then
        COPIED_FILES=$((COPIED_FILES + n))
        log_success "  $label: imported $n item(s) ($(du -sh "$s" | cut -f1))"
    else
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        log_info "  $label: nothing new — Moch already has everything"
    fi
}

BACKEND_DIR="$MOCH_HOME/moch-backend"
MOCH_CMD="$BACKEND_DIR/.hermes/bin/hermes"

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

# Secrets import with MERGE semantics: a fresh Moch's auth.json skeleton (or a
# dashboard-token .env) must not silently block the real keys from Hermes.
merge_secrets() {
    local src_auth="$SRC/auth.json" src_env="$SRC/.env"
    local tgt_auth="$MOCH_HOME/auth.json" tgt_env="$MOCH_HOME/.env"
    local have_src=false
    { [ -f "$src_auth" ] || [ -f "$src_env" ]; } && have_src=true
    if [ "$have_src" = false ]; then
        log_warn "  Providers/auth: not present in $SRC — skipped"
        return 0
    fi
    local py
    py="$(store_python || command -v python3 || true)"
    if [ -z "$py" ]; then
        log_warn "  Providers/auth: no python available to merge — skipped"
        return 0
    fi
    local merge_out
    if ! merge_out="$(DRY_RUN="$DRY_RUN" "$py" - "$src_auth" "$src_env" "$tgt_auth" "$tgt_env" 2>&1 <<'PY'
import json, os, shutil, sys
src_auth, src_env, tgt_auth, tgt_env = sys.argv[1:5]
dry = os.environ.get("DRY_RUN") == "true"

added_providers, added_env = [], []
if os.path.isfile(src_auth):
    src = json.load(open(src_auth))
    if os.path.isfile(tgt_auth):
        tgt = json.load(open(tgt_auth))
        providers = dict(tgt.get("providers") or {})
        pool = {p: {e.get("id"): e for e in lst} for p, lst in (tgt.get("credential_pool") or {}).items()}
        for name, cfg in (src.get("providers") or {}).items():
            if providers.get(name) != cfg:
                providers[name] = cfg
                added_providers.append(name)
        for p, lst in (src.get("credential_pool") or {}).items():
            slot = pool.setdefault(p, {})
            for e in lst:
                if slot.get(e.get("id")) != e:
                    slot[e.get("id")] = e
        merged = {"version": tgt.get("version", 1), "providers": providers,
                  "credential_pool": {p: list(d.values()) for p, d in pool.items()}}
        if added_providers:
            if dry:
                print("  [dry] would merge auth.json providers: " + ", ".join(added_providers))
            else:
                if not os.path.exists(tgt_auth + ".pre-import"):
                    shutil.copy2(tgt_auth, tgt_auth + ".pre-import")
                tmp = tgt_auth + ".tmp"
                with open(tmp, "w") as f:
                    json.dump(merged, f, indent=2)
                os.replace(tmp, tgt_auth)
                os.chmod(tgt_auth, 0o600)
                print("  auth.json: merged providers " + ", ".join(added_providers) + " (backup: auth.json.pre-import)")
        else:
            print("  auth.json: already has every provider from Hermes")
    elif not dry:
        shutil.copy2(src_auth, tgt_auth); os.chmod(tgt_auth, 0o600)
        added_providers = list((src.get("providers") or {}).keys())
        print("  auth.json: imported (" + ", ".join(added_providers) + ")")
if os.path.isfile(src_env):
    if os.path.isfile(tgt_env):
        tgt_lines = open(tgt_env).read().splitlines()
        tgt_keys = {l.split("=", 1)[0].strip() for l in tgt_lines if "=" in l and not l.lstrip().startswith("#")}
        new_lines = [l for l in open(src_env).read().splitlines()
                     if "=" in l and not l.lstrip().startswith("#")
                     and l.split("=", 1)[0].strip() not in tgt_keys]
        if new_lines:
            if dry:
                print("  [dry] would add %d .env key(s): %s" % (len(new_lines), ", ".join(sorted(l.split('=',1)[0] for l in new_lines))))
            else:
                if not os.path.exists(tgt_env + ".pre-import"):
                    shutil.copy2(tgt_env, tgt_env + ".pre-import")
                with open(tgt_env, "a") as f:
                    f.write("\n" + "\n".join(new_lines) + "\n")
                os.chmod(tgt_env, 0o600)
                print("  .env: added %d key(s) (backup: .env.pre-import)" % len(new_lines))
        else:
            print("  .env: already has every key from Hermes")
    elif not dry:
        shutil.copy2(src_env, tgt_env); os.chmod(tgt_env, 0o600)
        print("  .env: imported")
PY
)"; then
        log_warn "  Providers/auth: merge failed — your files are unchanged"
    fi
    echo "$merge_out"
    case "$merge_out" in
        *"merged providers"*|*".env: added"*|"auth.json: imported"|".env: imported")
            SECRETS_MERGED=true ;;
    esac
}

# Real chat-history migration: export_all() from the Hermes state.db
# (read-only, WAL-safe — through the backend's own DB layer, never a file
# copy) piped into import_sessions() against the Moch state.db. Existing ids
# are skipped, so re-runs are idempotent.
migrate_sessions() {
    if [ ! -x "$MOCH_CMD" ] && [ ! -d "$BACKEND_DIR" ]; then
        log_warn "  Chat history: Moch backend not found at $BACKEND_DIR — skipped"
        return 0
    fi
    if [ ! -f "$SRC/state.db" ]; then
        log_warn "  Chat history: no state.db in $SRC — skipped"
        return 0
    fi
    local py
    # The pm-managed environment venv carries the backend's dependencies
    # (ruamel etc.); the bare store python does not.
    py="$(find "$MOCH_HOME/installs" -maxdepth 6 -path '*/environments/*/venv/bin/python' 2>/dev/null | head -1)"
    if [ -z "$py" ]; then
        py="$(store_python || command -v python3 || true)"
        [ -n "$py" ] && log_info "  Chat history: pm environment venv not found — trying $py"
    fi
    if [ -z "$py" ]; then
        log_warn "  Chat history: no python available — skipped"
        return 0
    fi
    local payload
    payload="$(mktemp /tmp/moch-sessions-export.XXXXXX.json)"
    local n
    if ! n="$(HERMES_HOME="$SRC" "$py" -I -c '
import sys, os, json
sys.path.insert(0, sys.argv[1])
os.environ.pop("PYTHONHOME", None)
os.environ.pop("PYTHONPATH", None)
import hermes_bootstrap
from hermes_state import SessionDB
db = SessionDB(read_only=True)
payload = db.export_all(include_compacted=True)
json.dump(payload, open(sys.argv[2], "w"))
print(len(payload))
' "$BACKEND_DIR" "$payload" 2>&1)"; then
        log_warn "  Chat history: export from $SRC failed — skipped"
        [ -n "$payload" ] && rm -f "$payload"
        return 0
    fi
    if [ "$n" -eq 0 ] 2>/dev/null; then
        log_info "  Chat history: nothing to export from Hermes"
        rm -f "$payload"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log_info "  Chat history: [dry] would import $n session(s) into the Moch database"
        rm -f "$payload"
        return 0
    fi
    local res
    if ! res="$(HERMES_HOME="$MOCH_HOME" "$py" -I -c '
import sys, os, json
sys.path.insert(0, sys.argv[1])
os.environ.pop("PYTHONHOME", None)
os.environ.pop("PYTHONPATH", None)
import hermes_bootstrap
from hermes_state import SessionDB
db = SessionDB()
data = json.load(open(sys.argv[2]))
r = db.import_sessions(data)
dropped = []
if not r.get("ok"):
    errs = r.get("errors", [])
    oversized = sorted({e.get("index") for e in errs
                        if isinstance(e, dict) and "size limit" in str(e.get("error", ""))}, reverse=True)
    if oversized and len(oversized) == len(errs):
        # Validation is all-or-nothing: drop the oversized sessions and
        # import the rest (they are individually unimportable by design).
        for i in oversized:
            dropped.append(str(data[i].get("id", i)))
            del data[i]
        r = db.import_sessions(data)
    if not r.get("ok"):
        print("ERROR:" + json.dumps(r.get("errors", [])[:3]))
        sys.exit(1)
if dropped:
    print("imported=%s skipped=%s detached=%s dropped=%s (too large: %s)" % (
        r.get("imported"), r.get("skipped"), r.get("detached"), len(dropped), ", ".join(dropped[:5])))
else:
    print("imported=%s skipped=%s detached=%s" % (r.get("imported"), r.get("skipped"), r.get("detached")))
' "$BACKEND_DIR" "$payload" 2>&1)"; then
        log_warn "  Chat history: import failed: $res"
        rm -f "$payload"
        return 0
    fi
    log_success "  Chat history: $res (of $n exported)"
    case "$res" in
        *"imported=0"*) ;;
        *) SESSIONS_IMPORTED=1 ;;
    esac
    rm -f "$payload"
}

echo -e "${BOLD}Importing from $SRC → $MOCH_HOME${NC}$([ "$DRY_RUN" = true ] && echo ' (dry run — nothing written)')"
echo
merge_secrets
copy_tree "skills"                       "Skills"
copy_tree "memories"                     "Memories"
copy_tree "cron"                         "Scheduled jobs"
migrate_sessions
copy_tree "sessions"                     "Session request dumps (raw)"
copy_tree "hooks"                        "Hooks"
echo
if [ "$DRY_RUN" = true ]; then
    log_info "Dry run complete — re-run without --dry-run to import."
elif [ "$COPIED_FILES" -gt 0 ] || [ "$SECRETS_MERGED" = true ] || [ "$SESSIONS_IMPORTED" -gt 0 ]; then
    log_success "Imported $COPIED_FILES file(s), secrets merged: $SECRETS_MERGED, history migrated: $SESSIONS_IMPORTED; $SKIPPED_FILES already in place. Source untouched."
    log_info "Restart the backend to pick everything up:  moch restart"
    log_warn "config.yaml was NOT migrated on purpose — platform bindings (WhatsApp,"
    log_warn "gateway ports) are what Moch replaces. Cherry-pick model/tool settings"
    log_warn "from $SRC/config.yaml into $MOCH_HOME/config.yaml if you tuned any."
else
    log_info "Nothing to import — Moch already has everything from $SRC."
fi
