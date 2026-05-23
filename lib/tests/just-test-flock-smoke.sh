#!/usr/bin/env bash
# Smoke test for acquire_just_test_lock / release_just_test_lock
# (lib/locking.sh). Asserts the per-repo serialization contract used
# in lib/review-one-pr.sh's `just test` block:
#
#   1. Same-repo concurrent calls serialize (second blocks until first
#      releases) — the load-bearing property.
#   2. Different-repo calls run in parallel (different lock file).
#   3. release_just_test_lock() actually releases (subsequent acquire
#      from another process succeeds without waiting).
#
# Regression target: the cncorp/plow chat-postgres-1 cascade where
# concurrent PR worktrees of the same repo deadlocked pytest on a
# single shared docker container, hanging `just test` for the full
# 30-min timeout and cascading into 22G memory peaks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPDIR=$(mktemp -d -t just-test-flock-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
mkdir -p "$STATE_DIR" "$TMPDIR/bin"

# macOS dev hosts: brew's flock formula excludes the binary. Install
# the worker-smoke flock stub on PATH before sourcing locking.sh so
# the helper's blocking `flock FD` resolves to the python3+fcntl shim
# instead of failing with command-not-found.
# shellcheck source=lib/tests/worker-smoke-helpers.sh
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"
export PATH="$TMPDIR/bin:$PATH"
write_worker_flock_stub_if_missing "$TMPDIR/bin"

# shellcheck source=lib/locking.sh
. "$SCRIPT_DIR/locking.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  PASS: $*"; }

# Block until <file> appears or timeout. State-timed ordering replaces
# `sleep 0.2` scheduler-timed ordering — on a loaded host the 200ms
# head start can be insufficient, racing B/B2 ahead of A/A2's acquire
# and flipping the scenario's outcome.
wait_for_file() {
    local f="$1" deadline=$((SECONDS + 5))
    while [ ! -f "$f" ]; do
        [ "$SECONDS" -ge "$deadline" ] && fail "timed out waiting for $f"
        sleep 0.01
    done
}

# ---- scenario 1: same-repo serializes ----
# Worker A holds the lock for 1.5s; once the parent observes A's
# acquired-marker it launches worker B, which must observe ~1.5s of
# wait before its own acquire returns.
echo "  scenario 1: same-repo concurrent acquire serializes..."

worker_a_script=$(cat <<EOF
. "$SCRIPT_DIR/locking.sh"
acquire_just_test_lock "$STATE_DIR" "owner_repo"
echo "a-acquired \$(date +%s%N)" > "$TMPDIR/a.log"
sleep 1.5
release_just_test_lock
echo "a-released \$(date +%s%N)" >> "$TMPDIR/a.log"
EOF
)

worker_b_script=$(cat <<EOF
. "$SCRIPT_DIR/locking.sh"
START=\$(date +%s%N)
acquire_just_test_lock "$STATE_DIR" "owner_repo"
END=\$(date +%s%N)
echo "b-wait-ns \$((END - START))" > "$TMPDIR/b.log"
release_just_test_lock
EOF
)

bash -c "$worker_a_script" &
A_PID=$!
wait_for_file "$TMPDIR/a.log"
bash -c "$worker_b_script" &
B_PID=$!
wait "$A_PID" "$B_PID"

B_WAIT_NS=$(awk '/b-wait-ns/{print $2}' "$TMPDIR/b.log")
# A holds for 1.5s after the marker; B starts immediately after the
# marker. Assert >= 1.0s to confirm serialization without flaking on
# slow CI.
if [ "$B_WAIT_NS" -lt 1000000000 ]; then
    fail "scenario 1: worker B's wait was ${B_WAIT_NS}ns (<1s) — same-repo lock did not serialize"
fi
pass "scenario 1: B waited $(( B_WAIT_NS / 1000000 ))ms for A"

# ---- scenario 2: different repos don't block each other ----
echo "  scenario 2: different-repo concurrent acquire is parallel..."

rm -f "$TMPDIR/a2.log" "$TMPDIR/b2.log"

worker_a2_script=$(cat <<EOF
. "$SCRIPT_DIR/locking.sh"
acquire_just_test_lock "$STATE_DIR" "owner_repoA"
echo "a2-acquired \$(date +%s%N)" > "$TMPDIR/a2.log"
sleep 1.0
release_just_test_lock
EOF
)

worker_b2_script=$(cat <<EOF
. "$SCRIPT_DIR/locking.sh"
START=\$(date +%s%N)
acquire_just_test_lock "$STATE_DIR" "owner_repoB"
END=\$(date +%s%N)
echo "b2-wait-ns \$((END - START))" > "$TMPDIR/b2.log"
release_just_test_lock
EOF
)

bash -c "$worker_a2_script" &
A2_PID=$!
wait_for_file "$TMPDIR/a2.log"
bash -c "$worker_b2_script" &
B2_PID=$!
wait "$A2_PID" "$B2_PID"

B2_WAIT_NS=$(awk '/b2-wait-ns/{print $2}' "$TMPDIR/b2.log")
# Different repos = different lock file → B2 should NOT wait for A2.
# Assert <500ms wall clock for the flock acquire.
if [ "$B2_WAIT_NS" -gt 500000000 ]; then
    fail "scenario 2: worker B2 waited ${B2_WAIT_NS}ns for a different repo's lock — locks are not repo-scoped"
fi
pass "scenario 2: B2 acquired its own repo's lock in $(( B2_WAIT_NS / 1000000 ))ms"

# ---- scenario 3: release_just_test_lock actually releases ----
echo "  scenario 3: release_just_test_lock releases the FD..."

acquire_just_test_lock "$STATE_DIR" "release_test_repo"
[ -n "${JUST_TEST_LOCK_FD:-}" ] || fail "scenario 3: JUST_TEST_LOCK_FD not exported after acquire"
release_just_test_lock
[ -z "${JUST_TEST_LOCK_FD:-}" ] || fail "scenario 3: JUST_TEST_LOCK_FD still set after release"

# Now a separate process should be able to acquire the same lock
# without waiting — proves the FD was actually closed in our shell.
RELEASE_WAIT_SCRIPT=$(cat <<EOF
. "$SCRIPT_DIR/locking.sh"
START=\$(date +%s%N)
acquire_just_test_lock "$STATE_DIR" "release_test_repo"
END=\$(date +%s%N)
echo "release-wait-ns \$((END - START))" > "$TMPDIR/release.log"
release_just_test_lock
EOF
)
bash -c "$RELEASE_WAIT_SCRIPT"
RELEASE_WAIT_NS=$(awk '/release-wait-ns/{print $2}' "$TMPDIR/release.log")
if [ "$RELEASE_WAIT_NS" -gt 500000000 ]; then
    fail "scenario 3: re-acquire waited ${RELEASE_WAIT_NS}ns — release_just_test_lock didn't close the FD"
fi
pass "scenario 3: re-acquire took $(( RELEASE_WAIT_NS / 1000000 ))ms"

echo "  PASS (3 scenarios: same-repo serializes, cross-repo parallel, release frees the lock)"
