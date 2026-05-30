#!/usr/bin/env bash
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

# Shared structured logger. Prepends timestamp and, in container mode, a
# [w<WORKER_ID>] tag so `docker compose logs` lines are attributable to the
# account that emitted them (otherwise two reviewers' output interleaves with
# no way to tell which one paused/killed/failed). Tee's to LOG_FILE and stdout
# so a tail -f of LOG_FILE and the container/journal stream both see every
# event. LOG_FILE may be unset (e.g. review-loop.sh before review.sh sets it) —
# fall back to stdout-only rather than erroring. Format contract is mirrored in
# pipeline.py's log() for the Python pipeline.
log() {
    local prefix="[$(date '+%Y-%m-%d %H:%M:%S')]"
    [ -n "${WORKER_ID:-}" ] && prefix="$prefix [w${WORKER_ID}]"
    if [ -n "${LOG_FILE:-}" ]; then
        echo "$prefix $*" | tee -a "$LOG_FILE"
    else
        echo "$prefix $*"
    fi
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

# Codex quota-pause protocol. When an account hits its codex usage limit the
# worker (review-one-pr.sh) writes the reset epoch to this per-container file;
# the orchestrator (review.sh) and its loop (review-loop.sh) read it to stop
# claiming PRs until the window passes, so a capped account backs off while the
# other containers carry the queue. LOCAL_STATE_DIR is per-container; it falls
# back to STATE_DIR for non-container single-account runs.
quota_pause_file() { printf '%s' "${LOCAL_STATE_DIR:-$STATE_DIR}/quota-paused-until"; }

# True while the pause window is still in the future. A missing/empty file reads
# as epoch 0, i.e. not paused.
quota_active() { [ "$(date +%s)" -lt "$(head -n1 "$(quota_pause_file)" 2>/dev/null || echo 0)" ]; }

# Fatal-auth offline marker: when codex's token is invalidated (reused/rotated
# refresh token, revoked session — NOT a usage cap), review-one-pr.sh records
# the live auth.json mtime here and the worker goes OFFLINE. Unlike a quota
# pause there's no reset time, so it stays offline until an operator re-login —
# detected as a NEWER auth.json mtime — which auto-clears it. A cheap stat per
# tick, so a broken account stops claiming/commenting instead of spin-aborting.
auth_offline_file() { printf '%s' "${LOCAL_STATE_DIR:-$STATE_DIR}/auth-offline"; }
codex_auth_json()   { printf '%s' "${CODEX_HOME:-$HOME/.codex}/auth.json"; }

# True while the marker exists AND auth.json has NOT been refreshed since it was
# recorded (operator hasn't re-logged). A newer mtime ⇒ re-login ⇒ not offline.
auth_offline_active() {
    [ -f "$(auth_offline_file)" ] || return 1
    [ "$(stat -c %Y "$(codex_auth_json)" 2>/dev/null || echo 0)" \
      -le "$(head -n1 "$(auth_offline_file)" 2>/dev/null || echo 0)" ]
}
