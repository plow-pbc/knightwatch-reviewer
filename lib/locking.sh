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
    flock -n "$PR_LOCK_FD"
}
