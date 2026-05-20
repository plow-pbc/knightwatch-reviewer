#!/bin/bash
# Discover GitHub repos in $ORGS, clone any missing ones into
# $HOME/services/kwr-repos/<name>, and rewrite $STATE_DIR/repos.conf.auto
# with the resulting set. Hourly via pr-reviewer-org-sync.timer.
#
# Auto-managed clones live under $HOME/services/, NOT $HOME/Hacking/.
# $HOME/Hacking/ is the operator's dev workspace (parallel sibling
# checkouts per CLAUDE.md) — co-mingling auto-clones there caused
# silent collisions when a tracked repo transferred orgs and the
# operator's dev clone's origin URL no longer matched the canonical
# form for the new owner. Live production state stays under
# $HOME/services/ alongside the deployed reviewer prod clone.
#
# Split-file manifest:
#   repos.conf       — operator-owned. We only READ. (manual REPOS + ORGS)
#   repos.conf.auto  — tool-owned. We only WRITE. (auto REPOS / KID_PATHS)
#
# Sourced by lib/tracked-repos.sh AFTER repos.conf so manual entries
# win on collision. SOURCE_PATHS is intentionally NOT auto-generated —
# the cross-repo grep surface stays an explicit operator opt-in.

set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/org-sync.log}"
# Lock under $STATE_DIR, not /tmp: systemd's PrivateTmp=yes would
# otherwise split the timer run's lock from an operator shell run's.
LOCK="${LOCK:-$STATE_DIR/org-sync.lock}"
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$STATE_DIR/lib}"
CONF="${CONF:-$STATE_DIR/repos.conf}"
AUTO_CONF="${AUTO_CONF:-$STATE_DIR/repos.conf.auto}"

. "$REVIEWER_LIB_DIR/tracked-repos.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

command -v flock >/dev/null 2>&1 || { log "FATAL: flock not on PATH (util-linux)"; exit 1; }
mkdir -p "$STATE_DIR"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "sync already running (lock $LOCK held) — skipping"
    exit 0
fi

# ORGS empty: truncate any prior auto file so disabling the feature
# actually drops auto coverage on the next tick.
if [ "${#ORGS[@]}" -eq 0 ]; then
    if [ -f "$AUTO_CONF" ]; then
        log "ORGS empty — removing stale $AUTO_CONF"
        rm -f "$AUTO_CONF"
    else
        log "ORGS empty + no auto file — nothing to do"
    fi
    exit 0
fi

command -v gh >/dev/null 2>&1 || { log "FATAL: gh not on PATH"; exit 1; }

# Manual set: source repos.conf alone (without the auto file). Auto
# entries from a prior tick must not count as manual or they'd never
# prune. `set -e` in the sub-shell propagates a syntax error in
# repos.conf as a non-zero exit; parent's `if !` aborts before any write.
if ! MANUAL_LIST=$(
    set -e
    declare -a REPOS=()
    declare -A KID_PATHS=()
    declare -A SOURCE_PATHS=()
    declare -a ORGS=()
    # shellcheck disable=SC1090
    [ -f "$CONF" ] && . "$CONF"
    printf '%s\n' "${REPOS[@]}"
); then
    log "FATAL: failed to source $CONF — repos.conf may be malformed; aborting before rewrite"
    exit 1
fi
declare -A MANUAL=()
while IFS= read -r r; do [ -n "$r" ] && MANUAL[$r]=1; done <<< "$MANUAL_LIST"

# Per-org listing failures are FATAL — silently treating a failed
# list as "no repos" would erase that org's auto coverage on rewrite.
declare -A DISCOVERED=()
for org in "${ORGS[@]}"; do
    log "discovering org=$org"
    if ! out=$(gh repo list "$org" --source --no-archived --limit 1000 --json name --jq '.[].name' 2>>"$LOG"); then
        log "FATAL: gh repo list $org failed"
        exit 1
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        DISCOVERED["$org/$name"]=1
    done <<< "$out"
done

# Sorted for stable rewrites (cmp-based idempotency).
declare -a AUTO=()
for full in "${!DISCOVERED[@]}"; do
    [ -z "${MANUAL[$full]:-}" ] && AUTO+=("$full")
done
if [ "${#AUTO[@]}" -gt 0 ]; then
    mapfile -t AUTO < <(printf '%s\n' "${AUTO[@]}" | sort)
fi

mkdir -p "$HOME/services/kwr-repos"

NEW_CLONES=0
for full in "${AUTO[@]}"; do
    name="${full#*/}"
    dest="$HOME/services/kwr-repos/$name"
    if [ -d "$dest/.git" ]; then
        if ! url=$(git -C "$dest" remote get-url origin 2>/dev/null); then
            log "FATAL: $dest has no origin remote configured"
            exit 1
        fi
        # Exact canonical forms only. A leading `*` would let
        # `git@evilgithub.com:$full.git` pass (substring spoof); and
        # token-bearing https URLs would leak credentials via any log
        # line that echoes $url.
        case "$url" in
            "git@github.com:${full}.git"|"git@github.com:${full}"|"https://github.com/${full}.git"|"https://github.com/${full}") ;;
            *)
                log "FATAL: $dest origin does not match github.com/$full — refusing to overwrite"
                exit 1
                ;;
        esac
    elif [ -e "$dest" ]; then
        log "FATAL: $dest exists but is not a git checkout — refusing to clobber"
        exit 1
    else
        log "cloning $full → $dest"
        if ! gh repo clone "$full" "$dest" >>"$LOG" 2>&1; then
            # gh can leave $dest with partial .git + origin on failure;
            # next tick's matching-origin branch would treat it as a
            # complete clone and publish an empty checkout. Clean up.
            rm -rf "$dest"
            log "FATAL: gh repo clone $full failed (cleaned up partial $dest)"
            exit 1
        fi
        NEW_CLONES=$((NEW_CLONES + 1))
    fi
done

TMP_NEW=$(mktemp)
trap 'rm -f "$TMP_NEW"' EXIT
{
    echo "# Managed by org-sync.sh — regenerated each sync tick. Do NOT"
    echo "# edit; manual entries belong in repos.conf. SOURCE_PATHS is"
    echo "# intentionally not emitted (cross-repo grep stays opt-in)."
    echo "# KID_PATHS uses the conditional \${var:-default} form so"
    echo "# manual promotions win immediately without waiting for prune."
    for full in "${AUTO[@]}"; do
        name="${full#*/}"
        echo "REPOS+=(\"$full\")"
        echo "KID_PATHS[\"$full\"]=\"\${KID_PATHS[\"$full\"]:-\$HOME/services/kwr-repos/$name}\""
    done
} > "$TMP_NEW"

if [ -f "$AUTO_CONF" ] && cmp -s "$TMP_NEW" "$AUTO_CONF"; then
    log "no changes (${#AUTO[@]} auto-tracked, ${#MANUAL[@]} manual)"
else
    mv "$TMP_NEW" "$AUTO_CONF"
    log "rewrote $AUTO_CONF: ${#AUTO[@]} auto-tracked, $NEW_CLONES newly cloned"
fi
