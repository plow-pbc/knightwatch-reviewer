#!/bin/bash
# Shared logger + per-tick "seen comment IDs" key-value file helpers, used
# across the orchestrator (review.sh), the per-PR worker (review-one-pr.sh),
# and the sister tools (learn-from-replies.sh, approve-from-replies.sh).
#
# Historical note: this file once defined state_get / state_set against
# ~/.pr-reviewer/state.json — the legacy "what did we last review?" cache.
# That cache was retired in PR #38; every runtime-decision seam now reads
# runs/<id>/meta.json + agents/aggregator/output.md via lib/run-dir.sh's
# latest_author_visible_review_* projection family. state.json is no longer
# read or written by any production code path. The filename "state-io.sh"
# is preserved because the seen_* + log helpers below are still sourced
# from many callers; renaming it would churn every entrypoint for no win.
#
# Callers must have already set:
#   LOG_FILE=<orchestrator.log for review.sh, runs/<id>/run.log for the worker>

# Shared structured logger. Prepends timestamp; tee's to LOG_FILE and stdout so
# the systemd journal and a tail -f of LOG_FILE both reflect every event.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Generic "seen comment IDs" key-value JSON file with flock + atomic-rename
# safety. Used by both learn-from-replies.sh (memorize requests) and
# approve-from-replies.sh (approve requests) so the same comment isn't
# reprocessed across ticks. Args: $1=file path, $2=key. Without flock, two
# concurrent ticks read-modify-writing the same file lose one update;
# without atomic rename, a crash mid-write leaves a torn file.
seen_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    jq -r --arg k "$key" '.[$k] // empty' "$file"
}

seen_set() {
    local file="$1" key="$2"
    [ -f "$file" ] || echo '{}' > "$file"
    local lockfile="${file}.lock"
    if ! (
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg k "$key" --argjson v true '.[$k] = $v' "$file") || exit 1
        printf '%s' "$tmp" > "${file}.tmp" || exit 1
        mv -f "${file}.tmp" "$file" || exit 1
    ); then
        # Fail loud so callers and operators see the failure. Returning
        # non-zero lets critical call sites (e.g. post-successful-approve)
        # add their own warning about the consequence.
        log "seen_set FAILED for $file key=$key — next tick may reprocess this entry"
        return 1
    fi
}
