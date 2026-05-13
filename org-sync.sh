#!/bin/bash
# org-sync.sh — discover GitHub repos in $ORGS, clone any missing ones
# into $HOME/Hacking/<name>, and rewrite $STATE_DIR/repos.conf.auto with
# the resulting auto-tracked set. Runs hourly via the
# pr-reviewer-org-sync.timer systemd unit.
#
# Manifest split:
#   repos.conf        — operator-owned. Manual entries + ORGS knob. We
#                       only ever READ this file.
#   repos.conf.auto   — tool-owned. Regenerated from scratch each tick
#                       as (gh discovered − manual REPOS). We only ever
#                       WRITE this file. Sourced by lib/tracked-repos.sh
#                       AFTER repos.conf so manual entries win when an
#                       org-sync also discovers them.
#
# This split eliminates the failure modes the rewriting-in-place
# variant carried: no TOCTOU race (separate files; we don't share state
# with the operator), no malformed-conf-erases-data risk (we never
# write repos.conf), no marker block, no manual-fragment extraction.
#
# Sandbox note: per-repo `.keepitdry` write paths in
# pr-reviewer.service / pr-reviewer-kid-refresh.service's
# ReadWritePaths= are rendered at install time from KID_PATHS in
# repos.conf + repos.conf.auto. Auto entries added between installs
# work for reviews (lib/review-one-pr.sh skips kid prior-art when the
# index isn't there) but kid bootstrap-indexing waits for the next
# manual `./install.sh`.

set -euo pipefail
# PATH inherited from systemd unit (system dirs first; writable user
# dirs trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/org-sync.log}"
# Lock must live under $STATE_DIR, NOT /tmp. The systemd unit runs
# with PrivateTmp=yes, so a timer run's /tmp is a private namespace
# the operator's shell-launched run never sees — both runs would
# acquire the same-named lock in different namespaces, race on the
# same missing checkout, and the loser's `rm -rf "$dest"` could
# delete the winner's clone. $STATE_DIR is shared across both.
LOCK="${LOCK:-$STATE_DIR/org-sync.lock}"
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$STATE_DIR/lib}"
SOURCE_BASE="${SOURCE_BASE:-$HOME/Hacking}"
CONF="${CONF:-$STATE_DIR/repos.conf}"
AUTO_CONF="${AUTO_CONF:-$STATE_DIR/repos.conf.auto}"

# Source the shared loader for TMPDIR setup and the ORGS / REPOS view
# every other consumer sees. The loader sources repos.conf and (if
# present) repos.conf.auto into REPOS, KID_PATHS, SOURCE_PATHS, ORGS.
# We only USE ORGS from this load; the MANUAL set is derived below
# from a sub-shell source of repos.conf alone (without the auto file).
. "$REVIEWER_LIB_DIR/tracked-repos.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

command -v flock >/dev/null 2>&1 || { log "FATAL: flock not on PATH (util-linux)"; exit 1; }
# Open the lock file on FD 9 and acquire non-blocking. flock releases
# on FD close (process exit), so no trap-based cleanup needed — the
# kernel handles release even on SIGKILL. The file itself persists
# across runs (it's a lock anchor, not a presence flag) which is fine.
mkdir -p "$STATE_DIR"
exec 9>"$LOCK"
if ! flock -n 9; then
    log "sync already running (lock $LOCK held) — skipping"
    exit 0
fi

# Empty ORGS = feature disabled. Truncate any prior auto file so
# disabling the feature actually drops auto-tracked coverage on the
# next tick — leaving stale entries around would silently keep
# reviewing repos the operator removed from the ORGS list.
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

# Manual set: source repos.conf ALONE in a sub-shell (without the auto
# file). Auto entries from a prior tick must NOT count as "manual" or
# they'd never get pruned when their repo disappears from gh.
# `set -e` inside the sub-shell propagates a syntax error in repos.conf
# as a non-zero exit; parent's `if !` aborts before any write.
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

# Discover via gh, one org at a time. A failure for any org is FATAL —
# silently treating a failed listing as "org has no repos" would erase
# that org's auto coverage on the next write.
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

# Auto-set = discovered minus manual. Sorted for stable rewrites so
# cmp-based idempotency doesn't trigger on hash-order reshuffles.
declare -a AUTO=()
for full in "${!DISCOVERED[@]}"; do
    [ -z "${MANUAL[$full]:-}" ] && AUTO+=("$full")
done
if [ "${#AUTO[@]}" -gt 0 ]; then
    mapfile -t AUTO < <(printf '%s\n' "${AUTO[@]}" | sort)
fi

# Clone any missing checkouts. Existing dirs with a matching origin
# are reused as-is; mismatched remotes (or non-git paths) FAIL LOUD.
NEW_CLONES=0
for full in "${AUTO[@]}"; do
    name="${full#*/}"
    dest="$SOURCE_BASE/$name"
    if [ -d "$dest/.git" ]; then
        if ! url=$(git -C "$dest" remote get-url origin 2>/dev/null); then
            log "FATAL: $dest has no origin remote configured"
            exit 1
        fi
        # Exact canonical forms only — NO leading wildcard. A leading
        # `*` would let `git@evilgithub.com:$full.git` pass (substring
        # `github.com:$full.git` is contained in the spoof URL), and
        # token-bearing https URLs would leak credentials through any
        # log line that echoes $url.
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
            # gh repo clone can leave $dest with a partial .git +
            # origin behind on certain failure paths (e.g., network
            # interrupted mid-clone). Without cleanup, next tick's
            # `if [ -d $dest/.git ]` branch finds a matching-origin
            # partial and reuses it as if it were a complete clone —
            # silently publishing an empty checkout into the auto
            # manifest. Remove the partial so the next tick attempts
            # a fresh clone.
            rm -rf "$dest"
            log "FATAL: gh repo clone $full failed (cleaned up partial $dest)"
            exit 1
        fi
        NEW_CLONES=$((NEW_CLONES + 1))
    fi
done

# Render the auto file. Every tick produces a fresh, fully-derived
# file; no marker blocks, no in-place editing. Atomic via tmp + mv so
# a concurrent loader sees either the prior tick's contents or this
# tick's — never a half-written file.
TMP_NEW=$(mktemp)
trap 'rm -f "$TMP_NEW"' EXIT
{
    echo "# Managed by org-sync.sh — regenerated each sync tick from"
    echo "# \`gh repo list <ORGS> --source --no-archived\` minus the"
    echo "# manual REPOS in repos.conf. Sourced by lib/tracked-repos.sh"
    echo "# AFTER repos.conf. Do NOT edit by hand; manual entries"
    echo "# belong in repos.conf."
    echo "#"
    echo "# KID_PATHS assignment uses the conditional \${var:-default}"
    echo "# form so an operator promoting an auto-tracked repo to manual"
    echo "# (with a custom path) wins immediately without waiting for"
    echo "# the next sync tick to prune the auto entry."
    echo "#"
    echo "# SOURCE_PATHS is intentionally NOT auto-generated: the"
    echo "# cross-repo grep surface (search-roots, sibling materialization)"
    echo "# is a security-sensitive opt-in. Org-sync covers basic review"
    echo "# coverage; exposing an auto-discovered repo's source to other"
    echo "# repos' reviewers stays an explicit manual decision in"
    echo "# repos.conf."
    for full in "${AUTO[@]}"; do
        name="${full#*/}"
        echo "REPOS+=(\"$full\")"
        echo "KID_PATHS[\"$full\"]=\"\${KID_PATHS[\"$full\"]:-\$HOME/Hacking/$name}\""
    done
} > "$TMP_NEW"

if [ -f "$AUTO_CONF" ] && cmp -s "$TMP_NEW" "$AUTO_CONF"; then
    log "no changes (${#AUTO[@]} auto-tracked, ${#MANUAL[@]} manual)"
else
    mv "$TMP_NEW" "$AUTO_CONF"
    log "rewrote $AUTO_CONF: ${#AUTO[@]} auto-tracked, $NEW_CLONES newly cloned"
fi
