#!/usr/bin/env bash
# Shared logger + per-tick "seen comment IDs" key-value file helpers, used
# across the orchestrator (review.sh), the per-PR worker (review-one-pr.sh),
# and the sister tools (learn-from-replies.sh, poll-pr-actions.sh).
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
# poll-pr-actions.sh (approve requests) so the same comment isn't
# reprocessed across ticks. Args: $1=file path, $2=key. Without flock, two
# concurrent ticks read-modify-writing the same file lose one update;
# without atomic rename, a crash mid-write leaves a torn file.
seen_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    jq -r --arg k "$key" '.[$k] // empty' "$file"
}

# Atomically set one key in a JSON store under flock + temp-write + atomic
# rename, so a kill mid-write can't truncate it. $3 is the jq value expression:
# `true` for a presence marker (seen_set) or `$v` to store the string in $4
# (seen_set_value). The two public writers are thin wrappers over this.
_seen_write() {
    local file="$1" key="$2" value_expr="$3" value="${4:-}"
    [ -f "$file" ] || echo '{}' > "$file"
    local lockfile="${file}.lock"
    if ! (
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg k "$key" --arg v "$value" ".[\$k] = $value_expr" "$file") || exit 1
        printf '%s' "$tmp" > "${file}.tmp" || exit 1
        mv -f "${file}.tmp" "$file" || exit 1
    ); then
        # Fail loud so callers and operators see the failure. Returning non-zero
        # lets critical call sites (e.g. post-successful-approve) add their own
        # warning about the consequence.
        log "seen write FAILED for $file key=$key — next tick may reprocess this entry"
        return 1
    fi
}

# Presence marker: key → true. Callers test seen_get non-emptiness.
seen_set() { _seen_write "$1" "$2" 'true'; }

# Value store: key → string (e.g. a timestamp watermark, poll-pr-actions.sh's
# re-request last-handled event time). seen_get returns the stored string.
seen_set_value() { _seen_write "$1" "$2" '$v' "$3"; }

# Codex quota-pause protocol. When an account hits its codex usage limit the
# worker (review-one-pr.sh) writes the reset epoch to its pool file; the
# orchestrator (review.sh) and its loop (review-loop.sh) read it to stop
# claiming PRs until the window passes, so a capped account backs off while the
# other containers carry the queue.
#
# Stop-state lives on the SHARED volume, namespaced per account
# ($STATE_DIR/pool/<WORKER_ID>/), NOT in per-container LOCAL_STATE_DIR: each
# account still honors only its OWN files (a capped account never pauses a
# sibling), but any account can render the whole pool's status for the
# operator-facing paused message (pool_status below). WORKER_ID is part of
# the deployed contract (compose sets it per account); harnesses that model
# one account name it explicitly.
pool_state_dir() { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/pool/${WORKER_ID}"; }

quota_pause_file() { printf '%s' "$(pool_state_dir)/quota-paused-until"; }

# True while the pause window is still in the future. A missing file reads as
# epoch 0, i.e. not paused (the sole writer always writes a numeric epoch, so an
# empty file never occurs in practice).
quota_active() { [ "$(date +%s)" -lt "$(head -n1 "$(quota_pause_file)" 2>/dev/null || echo 0)" ]; }

# Fatal-auth offline marker: when codex's token is invalidated (reused/rotated
# refresh token, revoked session — NOT a usage cap), review-one-pr.sh records
# the live auth.json mtime here and the worker goes OFFLINE. Unlike a quota
# pause there's no reset time, so it stays offline until an operator re-login —
# detected as a NEWER auth.json mtime — which auto-clears it. A cheap stat per
# tick, so a broken account stops claiming/commenting instead of spin-aborting.
auth_offline_file() { printf '%s' "$(pool_state_dir)/auth-offline"; }
codex_auth_json()   { printf '%s' "${CODEX_HOME:-$HOME/.codex}/auth.json"; }

# True while the marker exists AND auth.json has NOT been refreshed since it was
# recorded (operator hasn't re-logged). A newer mtime ⇒ re-login ⇒ not offline.
auth_offline_active() {
    [ -f "$(auth_offline_file)" ] || return 1
    [ "$(stat -c %Y "$(codex_auth_json)" 2>/dev/null || echo 0)" \
      -le "$(head -n1 "$(auth_offline_file)" 2>/dev/null || echo 0)" ]
}

# Producer side: on a fatal-auth abort review-one-pr.sh calls this to take the
# worker offline — records the live auth.json mtime so auth_offline_active stays
# true until an operator re-login bumps it. (A missing auth.json records 0, so
# any real re-login clears it.)
mark_auth_offline() {
    stat -c %Y "$(codex_auth_json)" 2>/dev/null > "$(auth_offline_file)" \
        || echo 0 > "$(auth_offline_file)"
}

# One status clause per account registered under $STATE_DIR/pool/, for the
# operator/author-facing paused messages. Reads only the stop-state files each
# account already maintains — no extra bookkeeping, no cross-container probing.
# A sibling's auth-offline marker can't be mtime-verified against ITS auth.json
# from here, but the owning loop clears the marker within one tick of an
# operator re-login, so presence is accurate enough for a status line.
pool_status() {
    local now dir id until mtime state out=""
    now=$(date +%s)
    for dir in "${STATE_DIR:-$HOME/.pr-reviewer}"/pool/*/; do
        [ -d "$dir" ] || continue
        id=$(basename "$dir")
        until=$(head -n1 "$dir/quota-paused-until" 2>/dev/null || echo 0)
        mtime=$(stat -c %Y "${dir%/}" 2>/dev/null || echo 0)
        # review-loop touches its dir every tick, but a tick blocks on an
        # in-flight review (90m worker ceiling) — so only >2h of silence
        # means the account is actually gone, not just mid-review.
        if [ $(( now - mtime )) -gt 7200 ]; then
            state="💤 not running (no tick in $(( (now - mtime) / 3600 ))h)"
        elif [ -f "$dir/auth-offline" ]; then
            state="🔒 offline (codex auth invalid; awaiting operator re-login)"
        elif [ "$now" -lt "${until:-0}" ]; then
            state="⏸ quota-paused until $(date -d "@$until" '+%a %b %-d %H:%M %Z' 2>/dev/null || echo "epoch $until")"
        else
            state="✅ active"
        fi
        out="${out:+$out · }account $id: $state"
    done
    printf '%s' "$out"
}
