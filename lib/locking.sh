#!/usr/bin/env bash
# Per-PR advisory lock acquisition. Used by lib/review-one-pr.sh to
# prevent two concurrent invocations from stepping on each other for
# the same PR. Extracted into its own file so the smoke test can call
# the same function the production code uses — a regression that
# moves the lock dir back to /tmp (the pre-fix bug) would only need
# updating in one place, and the smoke would catch it directly.
#
# Why $STATE_DIR/locks and not /tmp: pr-reviewer.service runs with
# PrivateTmp=yes. With detached workers (KillMode=process), each
# oneshot invocation gets its own private /tmp namespace; a worker
# from tick N keeps its private-tmp lock file while tick N+1's new
# orchestrator + workers see a fresh /tmp — same path, different
# actual file across ticks, lock fails to gate the race. $STATE_DIR
# is real fs (declared in the unit's ReadWritePaths) and shared
# across every tick.

# acquire_pr_lock STATE_DIR PR_LOCK_SLUG — exits 0 if the caller now
# holds an exclusive flock on $STATE_DIR/locks/<PR_LOCK_SLUG>, or 1 if
# another process already holds it. Exports PR_LOCK_DIR / PR_LOCK_FILE
# / PR_LOCK_FD so the caller can include them in its "skipping" log
# line and so the FD survives the function return (held until process
# exit).
acquire_pr_lock() {
    local state_dir="$1" pr_lock_slug="$2"
    PR_LOCK_DIR="$state_dir/locks"
    mkdir -p "$PR_LOCK_DIR"
    PR_LOCK_FILE="$PR_LOCK_DIR/$pr_lock_slug"
    exec {PR_LOCK_FD}> "$PR_LOCK_FILE"
    # Close the FD on contention (mirror of acquire_just_test_lock) so callers
    # that probe in a loop don't leak one FD per held lock: review.sh's
    # consume_queue probes each queued PR and `continue`s past held ones. The
    # original single call site (the worker) exited on failure so never noticed.
    flock -n "$PR_LOCK_FD" || { exec {PR_LOCK_FD}>&-; unset PR_LOCK_FD; return 1; }
}

# release_pr_lock — drop the per-PR flock acquired by acquire_pr_lock so a
# later acquirer can take it within the same process. Mirror of
# release_just_test_lock. Used by review.sh's consumer to PROBE whether a PR
# is in-flight on another container (acquire → release) before forking the
# worker, which re-acquires the lock for the review's lifetime.
release_pr_lock() {
    [ -n "${PR_LOCK_FD:-}" ] || return 0
    exec {PR_LOCK_FD}>&-
    unset PR_LOCK_FD PR_LOCK_FILE PR_LOCK_DIR
}

# acquire_just_test_lock STATE_DIR — blocks until the caller holds one of
# $MAX_CONCURRENT_TESTS (default 3) global `just test` concurrency slots,
# then returns with that slot's flock held (FD in JUST_TEST_LOCK_FD, which
# survives the function return and is released by release_just_test_lock
# or process exit).
#
# This is a MEMORY bound, not a correctness lock. Each `just test` brings
# up a docker compose stack; the unit's MemoryHigh caps the whole cgroup,
# so we ration how many stacks run at once rather than let every in-flight
# review fire one. Slots are GLOBAL — one pool across all repos — because
# memory is a host-wide budget; a per-repo cap would let N repos each run
# MAX_SLOTS stacks and overrun it. Wave A/B and the aggregator run
# slot-free so cross-PR review parallelism stays intact.
#
# Why this replaced the old per-repo exclusive mutex: that mutex existed
# only because cncorp/plow's chat stack used a hardcoded, non-namespaced
# `chat-postgres-1` container that collided across concurrent same-repo
# worktrees. plow removed the chat stage from `just test` (2026-05-15;
# #638 deletes it outright), and the surviving test-scenarios stack
# namespaces its compose project name + host ports per checkout dir — so
# concurrent runs (same-repo and cross-repo) no longer race shared host
# state. Correctness is handled at the source; here we only ration memory.
acquire_just_test_lock() {
    local state_dir="$1" max_slots="${MAX_CONCURRENT_TESTS:-3}"
    JUST_TEST_LOCK_DIR="$state_dir/locks"
    mkdir -p "$JUST_TEST_LOCK_DIR"
    local slot
    while :; do
        for (( slot = 1; slot <= max_slots; slot++ )); do
            JUST_TEST_LOCK_FILE="$JUST_TEST_LOCK_DIR/just-test-slot__$slot"
            exec {JUST_TEST_LOCK_FD}> "$JUST_TEST_LOCK_FILE"
            flock -n "$JUST_TEST_LOCK_FD" && return 0
            exec {JUST_TEST_LOCK_FD}>&-
        done
        sleep 0.5
    done
}

release_just_test_lock() {
    [ -n "${JUST_TEST_LOCK_FD:-}" ] || return 0
    exec {JUST_TEST_LOCK_FD}>&-
    unset JUST_TEST_LOCK_FD JUST_TEST_LOCK_FILE JUST_TEST_LOCK_DIR
}
