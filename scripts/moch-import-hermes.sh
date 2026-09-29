#!/bin/bash
# ============================================================================
# moch import-hermes — bring an existing Hermes install into Moch
# ============================================================================
# Copies everything that makes your agent YOURS from a hermes home into the
# Moch home: provider logins/keys, env secrets, skills, memories, scheduled
# jobs, chat sessions and hooks. Read-only on the source; never overwrites
# anything already in the target (re-runs are incremental no-clobber merges).
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
            echo "  Copies providers (auth.json, .env), skills, memories, cron jobs,"
            echo "  sessions and hooks from a hermes home (default ~/.hermes) into"
            echo "  the Moch home ($MOCH_HOME). No-clobber: existing files stay."
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

copy_file() {  # copy_file SRC DST LABEL PERMS
    local s="$1" d="$2" label="$3" perms="${4:-}"
    if [ ! -f "$s" ]; then
        log_warn "  $label: not present in $SRC — skipped"
        return 0
    fi
    if [ -f "$d" ]; then
        SKIPPED_FILES=$((SKIPPED_FILES + 1))
        log_info "  $label: already exists in Moch — kept yours ($(du -h "$d" | cut -f1))"
        return 0
    fi
    $DRY mkdir -p "$(dirname "$d")"
    $DRY cp "$s" "$d"
    [ -n "$perms" ] && $DRY chmod "$perms" "$d"
    COPIED_FILES=$((COPIED_FILES + 1))
    log_success "  $label: imported ($(du -h "$s" | cut -f1))"
}

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

echo -e "${BOLD}Importing from $SRC → $MOCH_HOME${NC}$([ "$DRY_RUN" = true ] && echo ' (dry run — nothing written)')"
echo
copy_file "$SRC/auth.json"               "$MOCH_HOME/auth.json"               "Providers (auth)"      600
copy_file "$SRC/.env"                    "$MOCH_HOME/.env"                    "Env secrets (.env)"    600
copy_tree "skills"                       "Skills"
copy_tree "memories"                     "Memories"
copy_tree "cron"                         "Scheduled jobs"
copy_tree "sessions"                     "Chat sessions"
copy_tree "hooks"                        "Hooks"
echo
if [ "$DRY_RUN" = true ]; then
    log_info "Dry run complete — re-run without --dry-run to import."
elif [ "$COPIED_FILES" -gt 0 ]; then
    log_success "Imported $COPIED_FILES file(s); $SKIPPED_FILES already in place. Source untouched."
    log_info "Restart the backend to pick everything up:  moch restart"
    log_warn "config.yaml was NOT migrated on purpose — platform bindings (WhatsApp,"
    log_warn "gateway ports) are what Moch replaces. Cherry-pick model/tool settings"
    log_warn "from $SRC/config.yaml into $MOCH_HOME/config.yaml if you tuned any."
else
    log_info "Nothing to import — Moch already has everything from $SRC."
fi
