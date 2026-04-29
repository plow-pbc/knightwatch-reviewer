#!/bin/bash
# Shared state-file helpers used by both the orchestrator (review.sh) and
# the per-PR worker (review-one-pr.sh). state_set holds an exclusive flock
# on ${STATE_FILE}.lock while reading-modifying-writing, so concurrent
# workers produce a consistent final state.json.

# Callers must have already set:
#   STATE_FILE=~/.pr-reviewer/state.json
#   LOG_FILE=<orchestrator.log for review.sh, runs/<id>/run.log for the worker>

state_get() {
    # Read is safe without a lock; last-written wins but jq reads atomically enough.
    jq -r --arg id "$1" --arg k "$2" '.[$id][$k] // empty' "$STATE_FILE"
}

state_set() {
    # $5 (reviewed_at timestamp) is optional. Callers that want to pin the
    # "since" window for the next tick's comment filter to an earlier moment
    # (e.g. the worker's start time, so a /review posted during this review
    # isn't swallowed) pass it explicitly; everyone else gets "now".
    local pr_id="$1" sha="$2" approved="$3" body="$4" ts="${5:-$(date +%s)}"
    local lockfile="${STATE_FILE}.lock"
    (
        # subshell holds the lock for its lifetime
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg id "$pr_id" --arg sha "$sha" --arg body "$body" \
            --argjson ts "$ts" --argjson appr "$approved" \
            '.[$id] = {sha: $sha, reviewed_at: $ts, approved: $appr, body: $body}' \
            "$STATE_FILE") || exit 1
        # Atomic rename pattern — fail loud on either step so callers know
        # the write didn't land rather than silently continuing.
        printf '%s' "$tmp" > "${STATE_FILE}.tmp" || exit 1
        mv -f "${STATE_FILE}.tmp" "$STATE_FILE" || exit 1
    )
}

# Shared structured logger. Prepends timestamp; tee's to LOG_FILE and stdout so
# the systemd journal and a tail -f of LOG_FILE both reflect every event.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Generic "seen comment IDs" key-value JSON file with the same flock +
# atomic-rename safety as state_set. Used by both learn-from-replies.sh
# (memorize requests) and approve-from-replies.sh (approve requests) so
# the same comment isn't reprocessed across ticks. Args: $1=file path,
# $2=key. Without flock, two concurrent ticks read-modify-writing the
# same file lose one update; without atomic rename, a crash mid-write
# leaves a torn file.
seen_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    jq -r --arg k "$key" '.[$k] // empty' "$file"
}

seen_set() {
    local file="$1" key="$2"
    [ -f "$file" ] || echo '{}' > "$file"
    local lockfile="${file}.lock"
    (
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg k "$key" --argjson v true '.[$k] = $v' "$file") || exit 1
        printf '%s' "$tmp" > "${file}.tmp" || exit 1
        mv -f "${file}.tmp" "$file" || exit 1
    )
}
