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
    # Provision the store's directory. Every prior caller happened to write into
    # a STATE_DIR that bootstrap had already made, so a missing parent surfaced
    # as three cryptic redirect errors and an "unbound variable" from the lock
    # subshell rather than as anything nameable. Owning it here fixes that for
    # every caller instead of pushing an mkdir into each one.
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
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

# Structured value store: key → caller-supplied JSON. Keeps small cross-tick
# records on the same flock + atomic-rename seam as the seen stores.
seen_set_json_value() { _seen_write "$1" "$2" '($v | fromjson)' "$3"; }

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
# SCOPE: fleet-total, host timers and reviewer containers alike. The path below
# is deliberately unchanged by that unification — the host writes
# ~/.pr-reviewer/gh-rate-limited-until and a container writes
# /shared/gh-rate-limited-until, and lib/render-compose.sh bind-mounts the
# former ONTO the latter, so both spellings are one inode. Both groups spend the
# same PAT, so anything less is not a backoff: with a file per group, whichever
# half tripped paused only itself while the other kept calling, the throttle
# never cleared, and each side re-tripped the moment its window expired (93
# trips in 24h, in clusters of 3-7 about 112s apart, each costing an in-flight
# review its post).
#
# A FILE bind, never the enclosing directory. The containers run as root and are
# the untrusted-input boundary (they check out PR branches and execute
# repo-supplied scripts); given a writable host DIRECTORY they could replace this
# path with a symlink, FIFO or directory and no mode would stop them
# (CAP_FOWNER). A bind-mount target cannot be unlinked — EBUSY — so the inode is
# pinned, there are no siblings to create, and the whole plant class is absent
# rather than guarded.
gh_pause_file() { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/gh-rate-limited-until"; }

# Author-trust verdict cache. PER-CONTAINER (LOCAL_STATE_DIR), and the reason is
# dispatch isolation, NOT an authorization boundary — this store no longer is
# one. It holds enumeration verdicts only ("is this PR worth looking at"); every
# acting gate re-checks live (lib/auth.sh), so a planted entry buys a wasted
# dispatch that the worker's live check then rejects, not the ability to run
# code. Keeping it off the shared volume still means one compromised `just test`
# run cannot steer the other containers' enumeration, which is worth the zero
# extra lines it costs — but it is not what stops a revoked collaborator, and
# describing it that way would leave a false boundary standing as reviewed
# policy. Falls back to STATE_DIR the same way lib/review-one-pr.sh does.
trust_cache_file() { printf '%s' "${LOCAL_STATE_DIR:-${STATE_DIR:-$HOME/.pr-reviewer}}/trust-cache.json"; }

# --- GitHub quota telemetry -------------------------------------------------
# The fleet kept hitting limits and each incident restarted the same forensic
# dig: correlate six containers' logs by timestamp to guess the top consumer.
# These make consumption legible BEFORE a limit trips, which is the whole point
# — a 403 tells you which call drew the short straw, not which call spent the
# budget.
gh_tally_file()       { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/gh-call-tally"; }
gh_quota_stamp_file() { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/gh-quota-last-report"; }

# Collapse a gh argv to a stable endpoint SHAPE. Without this the tally scatters
# one bucket per repo/PR/user and the top-consumer answer is unreadable. Skips
# flags to find the api path, which sits at $2 for `gh api <path> --jq` but at
# $3 for `gh api --paginate <path>`.
gh_endpoint_shape() {
    local verb="${1:-}" a
    [ "$verb" = api ] || { printf '%s %s' "$verb" "${2:-}"; return 0; }
    shift
    for a in "$@"; do
        case "$a" in -*) continue ;; esac
        # The hex rule runs BEFORE the numeric one, which would otherwise eat a
        # SHA's leading digit and leave the rest un-collapsed. It is not
        # cosmetic: specialist-bakeoff fetches
        # `repos/<o>/<r>/commits/<sha>` in a per-commit loop across ~17 repos,
        # so without it the single busiest known consumer scatters into hundreds
        # of one-count buckets, can never reach the top 3, and a low-volume
        # endpoint outranks the one actually spending the budget.
        printf '%s' "$a" | sed -e 's#^repos/[^/]*/[^/]*#repos/*/*#' \
                               -e 's#^orgs/[^/]*#orgs/*#' \
                               -e 's#/[0-9a-f]\{7,40\}\(/\|$\)#/*\1#g' \
                               -e 's#/[0-9][0-9]*#/*#g' \
                               -e 's#collaborators/[^/]*#collaborators/*#'
        return 0
    done
    printf 'api'
}

# One O_APPEND line per attempted call. Short appends are atomic, so this needs
# no lock, and a reader truncating concurrently can only drop a sample — this is
# telemetry, not state, so a lost line costs nothing while a lock on the hot
# path would cost real latency on every call the fleet makes.
#
# No writer-side cap, deliberately. Every producer drains: gh_retry reports at
# the seam before each call it makes, so the window is emptied every
# GH_QUOTA_REPORT_SECS by whichever half calls first, and there is no path that
# appends without also draining. A cap would be a second unlocked truncation
# owner, plus a byte-size contract on the fleet's hottest path, guarding a
# failure this shape cannot reach.
gh_tally_call() {
    printf '%s\n' "$(gh_endpoint_shape "$@")" >> "$(gh_tally_file)" 2>/dev/null || true
}

# Top N endpoint shapes SINCE THE LAST LOOK, comma-joined. Reading consumes the
# window: every consumer (the periodic report, and the trip diagnostic) resets
# it, so attribution always describes recent traffic and the file cannot grow
# without bound on a host unit that only ever trips. A truncate racing an append
# drops a sample, which is free — this is telemetry, not state.
gh_top_callers() {
    local n="${1:-3}" out
    [ -s "$(gh_tally_file)" ] || return 0
    out=$(sort "$(gh_tally_file)" 2>/dev/null | uniq -c | sort -rn | head -n "$n" \
        | awk '{c=$1; $1=""; sub(/^ +/,""); printf "%s%s=%d", sep, $0, c; sep=", "}')
    : > "$(gh_tally_file)" 2>/dev/null || true
    printf '%s' "$out"
}

# ONE parser for /rate_limit, with ONE schema gate. Two hand-rolled parsers is
# what grew the same field-shift bug twice, so there is one owner; and GitHub's
# documented response always carries complete numeric core and graphql tuples, so
# a reply that is not six whole numbers is a FAILED probe, not a partial one.
# All-or-nothing keeps sentinels out of the middle of the tuple without a
# per-field coercion for a response shape this deployment has never seen.
#
# Field order is deliberate: the four CLASSIFICATION fields first, the two
# display-only limits appended.
gh_probe_buckets() {
    local raw
    GH_BUCKET_CORE_REM=-1; GH_BUCKET_CORE_RESET=-1; GH_BUCKET_GQL_REM=-1
    GH_BUCKET_GQL_RESET=-1; GH_BUCKET_CORE_LIM=-1; GH_BUCKET_GQL_LIM=-1
    raw=$(timeout "${GH_RATE_LIMIT_PROBE_SECS:-15}" gh api rate_limit \
        --jq '[.resources.core.remaining, .resources.core.reset,
               .resources.graphql.remaining, .resources.graphql.reset,
               .resources.core.limit, .resources.graphql.limit] | @tsv' \
        2>/dev/null | tr '\t' ' ')
    # @tsv renders a null as an EMPTY field and `tr` collapses it, so a malformed
    # reply presents as a short count — it fails this gate instead of shifting a
    # neighbour's value into a field that decides the pause window.
    case "$raw" in ''|*[!0-9\ ]*) return 1 ;; esac
    set -- $raw
    [ "$#" -eq 6 ] || return 1
    GH_BUCKET_CORE_REM=$1; GH_BUCKET_CORE_RESET=$2; GH_BUCKET_GQL_REM=$3
    GH_BUCKET_GQL_RESET=$4; GH_BUCKET_CORE_LIM=$5; GH_BUCKET_GQL_LIM=$6
    return 0
}

# Render a bucket figure for a human: an unmeasured value prints as `?`, never
# as -1, so an operator reading an incident log can tell "we could not measure
# the buckets" from a real reading. Distinguishing exactly those two is the whole
# point of the trip diagnostic, and a failed probe is its likely path.
gh_bucket_txt() { [ "${1:--1}" -ge 0 ] 2>/dev/null && printf '%s' "$1" || printf '?'; }

# Periodic headroom + attribution, and a WARNING while there is still budget to
# act on. /rate_limit does not consume quota, so the probe is free; `timeout … gh`
# execs the binary so this can neither recurse into the seam nor tally itself.
# Throttled by a stamp file. Per-HALF, not fleet-wide: the stamp lives under
# STATE_DIR, which is /shared for the containers and ~/.pr-reviewer for the host
# timers, while the tally underneath them is one bind-shared file. No sample is
# lost — whichever half drains gets everyone's — but the two cycles run
# independently, so a report landing shortly after the other half's drain shows a
# short window and an unrepresentative ranking. Closing that needs a third shared
# bind or an epoch folded into the tally; tracked separately rather than grown
# here. The check-then-write is deliberately unlocked: two workers racing emit one
# duplicate line, which is cheaper than a lock on a path every tick crosses.
gh_quota_report() {
    local now interval last top core_pct gql_pct
    now=$(date +%s); interval="${GH_QUOTA_REPORT_SECS:-300}"
    last=$(head -n1 "$(gh_quota_stamp_file)" 2>/dev/null || echo 0)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ "$(( now - last ))" -ge "$interval" ] || return 0
    mkdir -p "$(dirname "$(gh_quota_stamp_file)")" 2>/dev/null || true
    printf '%s\n' "$now" > "$(gh_quota_stamp_file)" 2>/dev/null || true
    # Drain FIRST, above the probe's early returns. The stamp has already moved,
    # so an interval that returns without draining suppresses the next attempt
    # while leaving the window unreaped — and with no writer-side cap that is
    # unbounded growth on a bind-mounted file the whole fleet appends to. The
    # reachable window is the one that matters: an expired token (every call
    # 401s, so gh_note_rate_limit's drain never fires either), a 5xx spell, a
    # partition. Costs only attribution on an interval whose report was going to
    # be silent anyway.
    top=$(gh_top_callers 3)
    # A failed probe earns no log line, but the stamp above already moved so a
    # flapping API cannot turn this into a per-tick storm of its own.
    gh_probe_buckets || return 0
    [ "$GH_BUCKET_CORE_LIM" -gt 0 ] && [ "$GH_BUCKET_GQL_LIM" -gt 0 ] || return 0
    core_pct=$(( GH_BUCKET_CORE_REM * 100 / GH_BUCKET_CORE_LIM ))
    gql_pct=$(( GH_BUCKET_GQL_REM * 100 / GH_BUCKET_GQL_LIM ))
    # Each bucket carries ITS OWN reset. A single countdown sourced from core was
    # printed after both, so a graphql-low warning handed the operator core's
    # recovery time — the wrong number for the bucket that is actually depleted.
    log "[gh-quota] core=${GH_BUCKET_CORE_REM}/${GH_BUCKET_CORE_LIM} (${core_pct}%, resets in $(( (GH_BUCKET_CORE_RESET - now + 59) / 60 ))m) graphql=${GH_BUCKET_GQL_REM}/${GH_BUCKET_GQL_LIM} (${gql_pct}%, resets in $(( (GH_BUCKET_GQL_RESET - now + 59) / 60 ))m)${top:+ — top callers: $top}"
    # Warn on EITHER bucket: GraphQL is the loaded one here (gh pr view per
    # worker, gh pr list per repo — lib/gh-retry.sh), so a core-only gate could
    # watch it drain in silence. Headroom cannot predict a SECONDARY limit —
    # /rate_limit does not expose one, and the incident behind this had core at
    # 4997/5000 — so that is what the attribution above is for, not this gate.
    local w="${GH_QUOTA_WARN_PCT:-20}"
    if [ "$core_pct" -lt "$w" ] || [ "$gql_pct" -lt "$w" ]; then
        log "[gh-quota] WARNING — $([ "$core_pct" -le "$gql_pct" ] && echo core || echo graphql) headroom under ${w}% (core ${core_pct}%, graphql ${gql_pct}%); the fleet will start 403ing${top:+ — top callers: $top}"
    fi
    return 0
}

# True while the pause window is still in the future. Missing file reads as
# epoch 0 (not paused) — mirrors quota_active. Unlike quota_active this coerces
# an EMPTY read to 0 as well: quota_active's file has one owner, but this one is
# written by every container AND the host timers, so a reader can land mid-write.
# `head` on a truncated file succeeds with empty output (the `||` fallback never
# fires), and `[ N -lt "" ]` would abort with "integer expression expected" —
# read as NOT paused, the worst possible default here.
#
# The shared flock is load-bearing rather than belt-and-braces: the publish
# writes IN PLACE (see gh_note_rate_limit — a bind-mounted file is inode-pinned,
# so the old temp+rename would strand every container on the pre-write inode),
# which makes the truncate window genuinely reachable where an atomic rename made
# it impossible. `flock -s` on the same inode both writers hold closes it.
#
# BOUNDED, and reads anyway on timeout. This runs on the hot path — every gh call
# and every tick — so an unbounded wait would let one stuck exclusive holder wedge
# the entire fleet, which is strictly worse than the split-brain this replaces.
# Falling through to an unlocked read restores exactly the pre-existing behaviour:
# a torn read yields empty, which coerces to NOT paused, same as a missing file.
gh_pause_active() {
    local until
    # `9<` and NOT flock's `flock <file> <cmd>` form: that form opens O_CREAT, so
    # merely ASKING whether the fleet is paused would create the pause file — and
    # every "did a non-rate-limit failure stamp a pause?" check would see one.
    # A read-only fd cannot create it, and a missing file fails the redirect,
    # leaving $until empty → not paused, which is the intended answer.
    until=$( { flock -s -w "${GH_PAUSE_READ_WAIT_SECS:-2}" 9 || true; head -n1 <&9; } \
                2>/dev/null 9<"$(gh_pause_file)" )
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

    local now kind until top
    now=$(date +%s)
    # Read the tally BEFORE the probe and the lock — it is pure filesystem work,
    # and a trip is exactly when "what were we spending it on?" is worth naming.
    top=$(gh_top_callers 3)
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
    gh_probe_buckets || true   # sentinels are set either way; unknown => secondary
    # An unknown bucket falls through to the secondary window deliberately: it is
    # the shorter, safer pause to be wrong with.
    if [ "$GH_BUCKET_CORE_REM" = 0 ]; then
        kind="primary/core"; until="$GH_BUCKET_CORE_RESET"
    elif [ "$GH_BUCKET_GQL_REM" = 0 ]; then
        kind="primary/graphql"; until="$GH_BUCKET_GQL_RESET"
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
    # Locked on the pause file ITSELF, not a sidecar .lock. The bind carries one
    # file, so a sidecar would live in the container's own volume and serialize
    # nothing across the boundary — the two halves would interleave writes on the
    # very inode the mount exists to share. `>>` because it must not truncate:
    # this fd is the lock handle, and the merge below still has to read the
    # current value through it.
    local existing rc=0
    (
        # Both exits log. gh_retry discards this function's status (it returns
        # gh's rc), so a silent failure here means the fleet does not back off AND
        # nothing says why — the exact class this protocol exists to remove.
        # The timeout is genuinely reachable, not defensive: gh_pause_active now
        # takes `flock -s` on this same inode on EVERY gh call across every
        # container and the host timers, and flock is not FIFO-fair, so a stream
        # of shared holders can starve the exclusive waiter — during precisely the
        # 403 cascade when every actor is retrying at once.
        exec {fd}>>"$(gh_pause_file)" \
            || { log "gh rate limit ($kind) — could not open $(gh_pause_file): pause NOT published"; exit 1; }
        flock -w "${GH_PAUSE_LOCK_WAIT_SECS:-5}" "$fd" \
            || { log "gh rate limit ($kind) — could not lock $(gh_pause_file) within ${GH_PAUSE_LOCK_WAIT_SECS:-5}s (shared readers starving the writer?): pause NOT published"; exit 1; }
        existing=$(head -n1 "$(gh_pause_file)" 2>/dev/null)
        if [ "${existing:-0}" -gt "$until" ] 2>/dev/null; then
            log "gh rate limit ($kind) — a sibling already published a longer pause (until epoch $existing); keeping it"
            exit 0
        fi
        log "gh rate limit ($kind) — core=$(gh_bucket_txt "$GH_BUCKET_CORE_REM")/$(gh_bucket_txt "$GH_BUCKET_CORE_LIM") graphql=$(gh_bucket_txt "$GH_BUCKET_GQL_REM")/$(gh_bucket_txt "$GH_BUCKET_GQL_LIM") remaining; pausing the FLEET $(( until - now ))s (until epoch $until)${top:+ — top callers: $top}"
        # IN PLACE, never temp+rename. A rename gives the path a new inode, and
        # docker pins a file bind-mount to the source inode — so every container
        # would keep reading the pre-write one, silently, forever. (Same property
        # that sent repos.conf the other way, from a file mount to a directory
        # mount; here the pin is the feature.) Readers take a shared flock on this
        # same inode, so the truncate window is covered.
        printf '%s\n' "$until" > "$(gh_pause_file)"
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
