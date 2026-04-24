#!/bin/bash
# Shared state-file helpers used by both the orchestrator (review.sh) and
# the per-PR worker (review-one-pr.sh). state_set holds an exclusive flock
# on ${STATE_FILE}.lock while reading-modifying-writing, so concurrent
# workers produce a consistent final state.json.

# Callers must have already set:
#   STATE_FILE=~/.pr-reviewer/state.json
#   LOG_FILE=~/.pr-reviewer/review.log

state_get() {
    # Read is safe without a lock; last-written wins but jq reads atomically enough.
    jq -r --arg id "$1" --arg k "$2" '.[$id][$k] // empty' "$STATE_FILE"
}

state_set() {
    local pr_id="$1" sha="$2" approved="$3" body="$4"
    local lockfile="${STATE_FILE}.lock"
    (
        # subshell holds the lock for its lifetime
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg id "$pr_id" --arg sha "$sha" --arg body "$body" \
            --argjson ts "$(date +%s)" --argjson appr "$approved" \
            '.[$id] = {sha: $sha, reviewed_at: $ts, approved: $appr, body: $body}' \
            "$STATE_FILE") || exit 1
        # Atomic rename pattern — fail loud on either step so callers know
        # the write didn't land rather than silently continuing.
        printf '%s' "$tmp" > "${STATE_FILE}.tmp" || exit 1
        mv -f "${STATE_FILE}.tmp" "$STATE_FILE" || exit 1
    )
}

# Shared structured logger. Prepends timestamp; tee's to LOG_FILE and stdout so
# both systemd journal and legacy tail -f of review.log keep working.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
