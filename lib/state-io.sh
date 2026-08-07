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

# GitHub rate-limit pause protocol. Same shape as the codex quota pause above,
# with one deliberate difference: it is shared across ACCOUNTS, not per-account.
#
# Codex quota is per-account — six containers, six independent budgets — so a
# capped account pauses only itself and its siblings carry the queue. The GitHub
# PAT is the opposite: every actor authenticates as the SAME user, so a throttle
# applies to all of them at once. Namespacing this under pool/<WORKER_ID>/ would
# pause the one container that noticed and leave the other five hammering the
# already-throttled token — the amplification this file exists to stop. Hence
# bare $STATE_DIR, no WORKER_ID.
#
# SCOPE, precisely: the file is shared by everyone who shares a $STATE_DIR. That
# is the six reviewer containers (STATE_DIR=/shared, the kwr_claims volume) as
# one group, and the host systemd timers (STATE_DIR=$HOME/.pr-reviewer) as
# another. Those are different filesystems, so a pause does NOT currently cross
# the host↔container boundary even though both groups spend the same PAT — the
# containers' bulk consumption can throttle the token without the host timers
# learning of it, and vice versa. Unifying the two needs a shared mount plus
# per-unit env, tracked separately; do not read the sharing here as fleet-total.
gh_pause_file() { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/gh-rate-limited-until"; }

# True while the pause window is still in the future. Missing file reads as
# epoch 0 (not paused) — mirrors quota_active. Unlike quota_active this coerces
# an EMPTY read to 0 as well: quota_active's file has one owner, but this one is
# written by any of six containers, so a reader can land mid-write. `head` on a
# truncated file succeeds with empty output (the `||` fallback never fires), and
# `[ N -lt "" ]` would abort with "integer expression expected" — read as NOT
# paused, the worst possible default here.
gh_pause_active() {
    local until
    until=$(head -n1 "$(gh_pause_file)" 2>/dev/null)
    [ "$(date +%s)" -lt "${until:-0}" ]
}

# Producer side: called by gh_api_retry when a `gh api` failure carries GitHub's
# rate-limit signature. Emits the diagnostic the fleet previously had none of,
# and stamps the fleet-wide pause.
#
# Why it re-queries instead of parsing the 403 body: GitHub words the PRIMARY
# (hourly bucket spent) and SECONDARY (burst/concurrency/abuse) limits
# identically — both are "API rate limit exceeded for user ID N". The only thing
# that tells them apart is live bucket state, so read it:
#     remaining == 0 → PRIMARY. Pause until that bucket's own reset.
#     remaining  > 0 → SECONDARY. /rate_limit CANNOT report secondary limits, so
#                      a rate-limit 403 with budget left IS the secondary signal.
#                      Pause a short fixed window (GitHub documents ~60s as the
#                      minimum backoff when no Retry-After is supplied).
# If /rate_limit can't be reached at all, fall back to the secondary window
# rather than skipping the pause — an unclassified rate-limit 403 still means
# "stop calling".
#
# Probes ONLY on the transition into a pause. /rate_limit is exempt from PRIMARY
# accounting, but that exemption does not extend to the secondary limits — which
# are about request rate and concurrency, and are the case this classifies most
# often. Without the short-circuit the in-flight tick keeps going after the first
# 403, so every subsequent failing call would fire its own probe: N failures
# become 2N requests, ×6 containers, during the exact window GitHub is telling
# the fleet to back off. Re-stamping would also push the window forward on every
# late straggler.
gh_note_rate_limit() {
    # Cheap exit: an already-paused fleet needs neither the probe nor the lock.
    # (gh_retry refuses before reaching here too, so this covers direct callers.)
    gh_pause_active && return 0

    local now core_rem core_reset gql_rem gql_reset kind until
    now=$(date +%s)
    # PROBE OUTSIDE THE LOCK. It is the only slow thing here — a network call,
    # made during a 403 cascade, when GitHub is most likely degraded and it can
    # stall. Holding a lock across it would block every sibling behind whoever
    # got there first, freezing workers that hold PR locks: a fleet-wide stall
    # caused by the code meant to back off gracefully. Probing unlocked costs
    # nothing extra — siblings already probe independently — and leaves the
    # critical section below as pure filesystem work.
    #
    # `timeout … gh`, not `command gh`: timeout EXECS the binary, so the seam
    # function is bypassed the same way, and it can't outlive its bound.
    read -r core_rem core_reset gql_rem gql_reset <<<"$(timeout "${GH_RATE_LIMIT_PROBE_SECS:-15}" gh api rate_limit \
        --jq '[.resources.core.remaining, .resources.core.reset,
               .resources.graphql.remaining, .resources.graphql.reset] | @tsv' \
        2>/dev/null | tr '\t' ' ')"
    if [ "${core_rem:-1}" = 0 ]; then
        kind="primary/core"; until="$core_reset"
    elif [ "${gql_rem:-1}" = 0 ]; then
        kind="primary/graphql"; until="$gql_reset"
    else
        kind="secondary"; until=$(( now + ${GH_SECONDARY_PAUSE_SECS:-60} ))
    fi
    # A stale/absent reset epoch would resume instantly and re-trip; floor it.
    [ "${until:-0}" -gt "$now" ] 2>/dev/null || until=$(( now + ${GH_SECONDARY_PAUSE_SECS:-60} ))

    # Now serialize only the read-compare-publish, which is milliseconds of
    # filesystem work — so no timeout and no proceed-anyway branch is needed, and
    # the merge is genuinely atomic rather than check-then-act.
    #
    # The merge keeps the LATER window. Serializing alone would make the FIRST
    # writer win, which is wrong: if A classified a PRIMARY limit (pause to the
    # bucket's real reset, up to an hour) and B's probe failed and fell back to
    # 60s, B arriving first would resume the whole fleet ~59 minutes early into an
    # exhausted bucket. For a back-off the more conservative answer is always
    # safe, and keeping the later one makes the outcome independent of who won.
    # `|| rc=$?`, not a bare `( … )`. A subshell in command position inherits the
    # CALLER's errexit, and on the first writer `head` on the not-yet-existing
    # pause file exits 1 — so under a `set -e` caller the section would abort
    # there, before the log and before the write: no pause, no diagnostic. Putting
    # it in a `||` list makes bash ignore -e for the whole extent, so publishing
    # is a property of this function rather than of whoever called it.
    local lockfile="$(gh_pause_file).lock" tmp existing rc=0
    mkdir -p "$(dirname "$lockfile")"
    (
        exec {fd}>"$lockfile" || exit 1
        flock "$fd"
        existing=$(head -n1 "$(gh_pause_file)" 2>/dev/null)
        if [ "${existing:-0}" -gt "$until" ] 2>/dev/null; then
            log "gh rate limit ($kind) — a sibling already published a longer pause (until epoch $existing); keeping it"
            exit 0
        fi
        log "gh rate limit ($kind) — core=${core_rem:-?}/5000 graphql=${gql_rem:-?}/5000 remaining; pausing the FLEET $(( until - now ))s (until epoch $until)"
        # tmp + atomic rename so a reader never sees a half-written file. The temp
        # must be unique per writer (mktemp, not $$ — the writers are separate
        # containers, so PIDs collide).
        tmp=$(mktemp "$(gh_pause_file).XXXXXX") || exit 1
        printf '%s\n' "$until" > "$tmp" && mv -f "$tmp" "$(gh_pause_file)"
    ) || rc=$?
    return "$rc"
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
