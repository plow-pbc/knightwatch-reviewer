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
# SCOPE: fleet-total, and that INCLUDES the host↔container boundary. The file
# sits in a `throttle/` subdir for exactly one reason — it is the only state the
# two halves share, so it has to be bind-mountable on its own.
# lib/render-compose.sh mounts the host's ~/.pr-reviewer/throttle at
# /shared/throttle in every reviewer (nested under the claims volume, the same
# shape as the manifest mount), so the host systemd timers
# (STATE_DIR=$HOME/.pr-reviewer) and the containers (STATE_DIR=/shared) write
# the SAME file. Both spend the same PAT, so anything less is not a backoff:
# with a file per group, whichever half tripped paused only itself while the
# other kept calling, so the throttle never cleared and each side re-tripped the
# moment its window expired — 93 trips in 24h, in clusters of 3-7 about 112s
# apart, each one costing an in-flight review its post. Sharing only this
# subdir keeps runs/, locks/ and queue.json per-group, which is what they must
# stay.
gh_pause_file() { printf '%s' "${STATE_DIR:-$HOME/.pr-reviewer}/throttle/gh-rate-limited-until"; }

# True while the pause window is still in the future. Missing file reads as
# epoch 0 (not paused) — mirrors quota_active. Unlike quota_active this coerces
# an EMPTY read to 0 as well: quota_active's file has one owner, but this one is
# written by any of six containers, so a reader can land mid-write. `head` on a
# truncated file succeeds with empty output (the `||` fallback never fires), and
# `[ N -lt "" ]` would abort with "integer expression expected" — read as NOT
# paused, the worst possible default here.
# gh_pause_path_sane PATH → 0 iff PATH is absent or a plain regular file.
#
# throttle/ is bind-mounted into every reviewer container; those run as root and
# are the untrusted-input boundary (they check out PR branches and execute
# repo-supplied scripts), so they can replace either shared path with any file
# type and no directory mode stops them (CAP_FOWNER). Both paths need the same
# answer in both roles, so the question has one owner rather than a guard per
# call site — the per-site version is what let the lock get four rounds of
# attention while the pause file next to it stayed open.
gh_pause_path_sane() {
    [ -L "$1" ] && return 1
    [ -e "$1" ] || return 0
    [ -f "$1" ]
}

gh_pause_active() {
    local until
    # Before `head`, because head on a planted FIFO blocks forever — and this is
    # the hot path, consulted by every gh call and every tick.
    gh_pause_path_sane "$(gh_pause_file)" || return 1
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
    (
        # umask 000 for the LOCK and the dir, 0666 for the pause file below. The two writers
        # are different UIDs — the reviewer containers run as root, the host
        # systemd timers as the operator — so default modes silently restore the
        # very split this file was moved into a shared mount to remove, in the
        # direction that matters most (root bypasses DAC, so container→host is
        # the broken one, and the containers make the bulk of the calls and trip
        # first). A root-created 0644 lock makes the host's `exec {fd}>` fail
        # EACCES, which exits before the log — no pause AND no diagnostic.
        umask 000
        # Inside the subshell, so the umask applies: a 0755 root-created dir
        # would deny the operator mktemp/mv and defeat the modes below it.
        mkdir -p "$(dirname "$lockfile")"
        # Same self-heal as the lock, and for the same reason: mkdir -p is a
        # no-op on an existing dir, and this dir exists on every host by now
        # (install.sh, a docker bind auto-create, or a prior publish). A
        # root-owned 0755 one is the docker-auto-create case that render-compose's
        # -d guard and install.sh's mkdir PREVENT but cannot HEAL — and healing
        # only the lock makes it worse: the operator then gets past exec/flock,
        # logs "pausing the FLEET", and fails creating the temp.
        #
        # 0777 and NOT sticky. rename(2) into a sticky dir requires the caller to
        # own the file, own the dir, or be root — so on the very hosts this heals
        # (dir auto-created root-owned, then flipped and published by a container)
        # the operator would own neither, and `mv` would fail EPERM forever: the
        # pause file is never unlinked, so that state is permanent. The sticky bit
        # cannot be replaced by tightening the mode here. What a world-writable
        # dir exposes is a symlink swap on the lock. Against a THIRD LOCAL USER
        # that is closed by reachability — install.sh keeps $INSTALL_DIR at 0700,
        # so they cannot traverse in. Against container root it is not closed by
        # any mode (CAP_FOWNER); the -L refusal at the open below is what handles
        # that actor. Uniformly world-writable is what makes both UIDs equal
        # writers.
        chmod 0777 "$(dirname "$lockfile")" 2>/dev/null || true
        # The lock open is the ONE call in this section that follows a symlink,
        # and sharing throttle/ across the host↔container boundary is what put two
        # actors on it. The containers bind-mount this dir, run as ROOT, and are
        # the untrusted-input boundary (they check out PR branches and execute
        # repo-supplied scripts). Container root can unlink this path inside the
        # mount — CAP_FOWNER bypasses the dir mode and a sticky bit alike, so
        # neither 0777 nor 1777 changes that — and leave a symlink to any
        # operator-owned host path. The next HOST publish would then O_CREAT|O_TRUNC
        # and chmod 0666 straight through it: ~/.bashrc, config.env or
        # authorized_keys truncated and made world-writable, i.e. container→host
        # execution as the bot user. Refuse instead. mktemp and mv -f need no such
        # guard against a SYMLINK — rename(2) replaces one rather than following
        # it. A directory is a different matter, handled at the publish below.
        # "not a regular file", not "is a symlink": the same actor can plant a
        # FIFO, whose open(O_WRONLY) blocks until a reader that never comes —
        # hanging the tick until systemd SIGKILLs the unit at TimeoutStartSec,
        # every tick, a cheaper and more durable denial than the truncate — or a
        # directory, whose EISDIR would fall into the bare `|| exit 1` below and
        # exit mute, restoring the no-pause-no-diagnostic failure this series
        # exists to remove. One condition covers symlink, FIFO, directory and
        # device, and gives all of them the diagnostic.
        # Residual: a swap between this test and the open still wins (bash has no
        # O_NOFOLLOW), so this narrows the window rather than closing it; the
        # durable fix is an unprivileged container runtime.
        # Refusing the lock must NOT cost the pause. The lock only serializes the
        # merge below; mktemp + mv -f are already safe on their own (rename
        # replaces, and the temp name is unpredictable). Exiting here would let one
        # unprivileged mkfifo at this path disable the fleet's backoff permanently
        # — the fleet hammering GitHub through every 403 IS the original incident,
        # so losing one trip's later-window merge is by far the smaller loss.
        # Clear a plant rather than refusing forever. Refusing is fail-open in the
        # throttle-DISABLING direction — gh_pause_active reads not-paused and every
        # publish declines — so one no-capability mkdir would leave the fleet
        # calling through every 403, the original incident, with nothing to clear
        # it. It is also hotter than the silent version: gh_note_rate_limit's cheap
        # "already paused" exit can never fire, so every failing call adds its own
        # rate_limit probe during the window GitHub is telling the fleet to back
        # off. Removal is possible at all because the dir is deliberately 0777 and
        # non-sticky, so unlink depends on the directory bits, not on who owns the
        # plant. Non-recursive on purpose: rmdir REFUSES a non-empty directory, so
        # a surprise fails loudly instead of being eaten.
        if ! gh_pause_path_sane "$lockfile"; then
            rm -f "$lockfile" 2>/dev/null || true
            rmdir "$lockfile" 2>/dev/null || true
        fi
        if ! gh_pause_path_sane "$lockfile"; then
            log "gh rate limit — $lockfile is not a regular file and could not be cleared; publishing UNSERIALIZED (only the later-window merge is lost)"
        else
            exec {fd}>"$lockfile" || exit 1
            # SELF-HEALING, not creation-only. umask governs only files this call
            # creates, and the lock is never unlinked — so on any host where a
            # container has already tripped a limit, the lock exists root-owned 0644
            # and the operator's `exec` above keeps failing EACCES forever: the fix
            # would be inert on exactly the deployment it targets. Only root's chmod
            # succeeds here, which is the direction that needs healing. Never `rm` the
            # stale lock instead — unlinking it while a container holds flock hands the
            # next writer a fresh inode and gives two concurrent writers.
            chmod 0666 "$lockfile" 2>/dev/null || true
            flock "$fd"
        fi
        # Before ANY use of the pause path — the merge read below is a `head`,
        # which blocks forever on a planted FIFO. And `mv -f tmp dir` is not a
        # rename-over: it moves the temp INSIDE and succeeds, so a planted
        # directory would make every trip log "pausing the FLEET" while the read
        # side sees no pause — the silent split-brain this protocol exists to
        # close, restored by one no-capability mkdir. rename(2) handles a symlink
        # safely; a directory it never sees.
        # Same clear-then-refuse as the lock above — see that comment.
        if ! gh_pause_path_sane "$(gh_pause_file)"; then
            rm -f "$(gh_pause_file)" 2>/dev/null || true
            rmdir "$(gh_pause_file)" 2>/dev/null || true
        fi
        if ! gh_pause_path_sane "$(gh_pause_file)"; then
            log "gh rate limit — $(gh_pause_file) is not a regular file and could not be cleared: pause NOT published despite the line above"
            exit 1
        fi
        existing=$(head -n1 "$(gh_pause_file)" 2>/dev/null)
        if [ "${existing:-0}" -gt "$until" ] 2>/dev/null; then
            log "gh rate limit ($kind) — a sibling already published a longer pause (until epoch $existing); keeping it"
            exit 0
        fi
        log "gh rate limit ($kind) — core=${core_rem:-?}/5000 graphql=${gql_rem:-?}/5000 remaining; pausing the FLEET $(( until - now ))s (until epoch $until)"
        # tmp + atomic rename so a reader never sees a half-written file. The temp
        # must be unique per writer (mktemp, not $$ — the writers are separate
        # containers, so PIDs collide).
        # ONE failure path for the whole publish, not one per step. The
        # "pausing the FLEET" line above has ALREADY been written, so a mute
        # failure anywhere in here leaves the operator's evidence asserting a
        # pause while gh_pause_active reads not-paused and the fleet keeps
        # calling — the split-brain restored silently, which is the failure this
        # protocol exists to close. The caller discards our exit code, so the log
        # is the only channel. Collapsed into a single branch so it is reachable
        # from one test rather than being three separately-untestable ones.
        # The chmod is inside the chain: mktemp is 0600 and mv carries that mode
        # onto the published file, so without it the other UID's `head` gets
        # EACCES → empty → reads as NOT paused. Silently, the worst default here.
        tmp=$(mktemp "$(gh_pause_file).XXXXXX") \
            && chmod 0666 "$tmp" \
            && printf '%s\n' "$until" > "$tmp" \
            && mv -f "$tmp" "$(gh_pause_file)" || {
            log "gh rate limit — publish to $(gh_pause_file) FAILED (throttle dir mode $(stat -c '%a' "$(dirname "$lockfile")" 2>/dev/null || echo '?')): pause NOT published despite the line above"
            [ -n "${tmp:-}" ] && rm -f "$tmp"
            exit 1
        }
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
