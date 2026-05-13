#!/bin/bash
# org-sync.sh — discover GitHub repos in $ORGS, clone any missing ones
# into $HOME/Hacking/<name>, and regenerate the AUTO-SYNC marker block
# in repos.conf. Runs hourly via pr-reviewer-org-sync.timer.
#
# Contract:
#   - Reads ORGS array from repos.conf (per-operator, gitignored).
#   - Per org, lists non-archived, non-fork repos via
#     `gh repo list <org> --source --no-archived`.
#   - Auto-set = discovered − manual section's REPOS. The marker block
#     is fully regenerated each tick from that derivation; there is no
#     hidden "previously auto-added" state outside repos.conf itself.
#   - Clones missing repos into $HOME/Hacking/<name>. If a checkout
#     already exists with a different origin remote, FAILS LOUD —
#     never silently overwrites.
#   - Atomic rewrite of repos.conf (tmp + mv). New repos start being
#     reviewed on the next pr-reviewer.timer tick (review.sh re-sources
#     repos.conf each run).
#
# Sandbox note: this does NOT run install.sh. Per-repo `.keepitdry`
# write paths in pr-reviewer.service / pr-reviewer-kid-refresh.service's
# ReadWritePaths= are NOT widened until the operator manually re-runs
# ./install.sh. lib/review-one-pr.sh silently skips kid prior-art when
# the index doesn't exist, so reviews still happen on newly-added
# repos — just without kid context until the next manual reinstall.

set -euo pipefail
# PATH inherited from systemd unit (system dirs first; writable user
# dirs trailing). See review.sh for the writable-PATH security context.
#
# -e + -o pipefail are load-bearing: the manual-fragment sub-shell
# below sources a user-edited repos.conf; without -e a syntax error
# midway through the source leaves REPOS partially populated, the
# sub-shell prints whatever made it in, MANUAL collapses below the
# real set, and the next rewrite would erase legitimate manual entries
# by misclassifying them as "discovered, not manual." Fail-loud before
# any mv.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/org-sync.log}"
LOCK="${LOCK:-/tmp/pr-reviewer-org-sync.lock}"
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$STATE_DIR/lib}"
SOURCE_BASE="${SOURCE_BASE:-$HOME/Hacking}"
CONF="${CONF:-$STATE_DIR/repos.conf}"

# Shared loader — same seam every other manifest consumer uses. Pulls
# in REPOS, KID_PATHS, SOURCE_PATHS, and ORGS from repos.conf.
. "$REVIEWER_LIB_DIR/tracked-repos.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -e "$LOCK" ]; then
    log "sync already running (lock $LOCK present) — skipping"
    exit 0
fi
touch "$LOCK"
# trap reassignment below extends this cleanup as more tmpfiles appear.
trap 'rm -f "$LOCK"' EXIT

# Resolve the conf file's REAL path: $CONF is usually a symlink in
# $STATE_DIR pointing at the source-tree repos.conf (delivered by
# install.sh). Mutate the actual file so the source-tree copy stays
# in sync and `git diff` surfaces what changed.
CONF_REAL=$(readlink -f "$CONF" 2>/dev/null || echo "$CONF")
[ -f "$CONF_REAL" ] || { log "FATAL: $CONF (resolved $CONF_REAL) does not exist"; exit 1; }

# Empty ORGS = feature disabled. Don't touch the file; don't poll gh.
if [ "${#ORGS[@]}" -eq 0 ]; then
    log "no ORGS configured in $CONF_REAL — nothing to sync"
    exit 0
fi

# Legacy override seam: lib/tracked-repos.sh sources $STATE_DIR/config.env
# AFTER repos.conf, and config.env's REPOS=(...) wins. Letting org-sync
# rewrite repos.conf while a config.env override is in force would
# calcify a split source of truth — consumers would resolve to the
# override while operators read the rewritten manifest. Fail loud here;
# the operator picks one (retire config.env or unset ORGS).
if [ -f "$STATE_DIR/config.env" ] && grep -qE '^[[:space:]]*REPOS[+]?=' "$STATE_DIR/config.env"; then
    log "FATAL: $STATE_DIR/config.env defines REPOS — refusing to rewrite $CONF_REAL while a legacy override is active. Either retire the config.env REPOS line or unset ORGS in repos.conf."
    exit 1
fi

command -v gh >/dev/null 2>&1 || { log "FATAL: gh not on PATH"; exit 1; }

# Manual fragment = repos.conf with the AUTO-SYNC marker block stripped.
# Sourcing it in a sub-shell gives us the operator-curated REPOS set
# WITHOUT the previously auto-added entries — the seam that lets the
# auto block be a pure function of (gh state, manual REPOS).
MANUAL_FRAGMENT=$(mktemp)
TMP_NEW=$(mktemp)
trap 'rm -f "$LOCK" "$MANUAL_FRAGMENT" "$TMP_NEW"' EXIT

awk '
    /^# === BEGIN AUTO-SYNC ===/ { in_block=1; next }
    /^# === END AUTO-SYNC ===/   { in_block=0; next }
    !in_block { print }
' "$CONF_REAL" > "$MANUAL_FRAGMENT"

# Sub-shell sourcing keeps the parent's REPOS / KID_PATHS / ORGS state
# (the live, auto-block-inclusive view) untouched while we extract the
# manual-only view. `set -e` inside the sub-shell propagates a malformed
# repos.conf (bash syntax error during source) as a non-zero exit code;
# parent's `if !` then aborts the script BEFORE any rewrite — without
# this, a partial source leaves REPOS clipped, the auto-set
# misclassifies legitimate manual entries as "newly discovered," and
# the rewrite erases them.
if ! MANUAL_LIST=$(
    set -e
    declare -a REPOS=()
    declare -A KID_PATHS=()
    declare -A SOURCE_PATHS=()
    declare -a ORGS=()
    # shellcheck disable=SC1090
    . "$MANUAL_FRAGMENT"
    printf '%s\n' "${REPOS[@]}"
); then
    log "FATAL: failed to source manual fragment of $CONF_REAL — repos.conf may be malformed; aborting before rewrite"
    exit 1
fi
declare -A MANUAL=()
while IFS= read -r r; do [ -n "$r" ] && MANUAL[$r]=1; done <<< "$MANUAL_LIST"

# Discover via gh, one org at a time. A failure for any org is FATAL —
# silently treating a failed listing as "org has no repos" would erase
# that org's entire auto-block on rewrite.
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
        # a token-bearing https URL would silently leak credentials
        # through the next log line (probe 2/3, PR #75 round 1).
        case "$url" in
            "git@github.com:${full}.git"|"git@github.com:${full}"|"https://github.com/${full}.git"|"https://github.com/${full}") ;;
            *)
                # Do NOT echo $url — it can contain inline credentials
                # (e.g., https://user:ghp_xxx@github.com/...). Log only
                # the expected canonical form and the dest path.
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
            log "FATAL: gh repo clone $full failed"
            exit 1
        fi
        NEW_CLONES=$((NEW_CLONES + 1))
    fi
done

# Manual section (trailing blanks trimmed for clean concatenation).
sed -e :a -e '/^$/{$d;N;ba' -e '}' "$MANUAL_FRAGMENT" > "$TMP_NEW"

# Append the regenerated AUTO-SYNC block (always present, even when
# empty, so the next tick has anchor markers to find).
{
    echo ""
    echo "# === BEGIN AUTO-SYNC ==="
    echo "# Managed by org-sync.sh — regenerated each sync tick from"
    echo "# \`gh repo list <ORGS> --source --no-archived\` minus the"
    echo "# manual section above. Do NOT edit by hand; manual entries"
    echo "# belong above this block."
    if [ "${#AUTO[@]}" -gt 0 ]; then
        echo "REPOS+=("
        for full in "${AUTO[@]}"; do echo "    \"$full\""; done
        echo ")"
        for full in "${AUTO[@]}"; do
            name="${full#*/}"
            echo "KID_PATHS[\"$full\"]=\"\$HOME/Hacking/$name\""
            echo "SOURCE_PATHS[\"$full\"]=\"\$HOME/Hacking/$name\""
        done
    fi
    echo "# === END AUTO-SYNC ==="
} >> "$TMP_NEW"

# Atomic replace only if content changed (idempotent — no churn on
# clean ticks; no spurious file mtime updates that would defeat
# downstream cmp-based gates).
if cmp -s "$TMP_NEW" "$CONF_REAL"; then
    log "no changes (${#AUTO[@]} auto-tracked, ${#MANUAL[@]} manual)"
else
    mv "$TMP_NEW" "$CONF_REAL"
    log "rewrote $CONF_REAL: ${#AUTO[@]} auto-tracked, $NEW_CLONES newly cloned"
fi
