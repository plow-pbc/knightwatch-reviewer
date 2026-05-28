#!/bin/bash
# Verifies the container state split: the per-PR lock is SHARED (two
# containers can't review the same PR), while the just-test lock is
# LOCAL (two containers CAN run `just test` concurrently). Sourcing
# lib/locking.sh directly — same functions review-one-pr.sh uses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/locking.sh"

SHARED=$(mktemp -d); LOCAL_A=$(mktemp -d); LOCAL_B=$(mktemp -d)
trap 'rm -rf "$SHARED" "$LOCAL_A" "$LOCAL_B"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

# Per-PR lock on the SHARED dir: second acquirer must lose.
( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" \
    && sleep 5 ) &
held=$!
sleep 1
if ( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" ); then
    fail "second container acquired the shared per-PR lock (dedup broken)"
fi
wait "$held"

# just-test lock on DISTINCT local dirs: both must win (no serialization).
( . "$HERE/locking.sh"; acquire_just_test_lock "$LOCAL_A" "cncorp_plow"; sleep 3 ) &
a=$!
sleep 1
if ! timeout 2 bash -c ". '$HERE/locking.sh'; acquire_just_test_lock '$LOCAL_B' cncorp_plow"; then
    fail "just-test lock on a distinct local dir blocked (parallelism broken)"
fi
wait "$a"

grep -q 'acquire_just_test_lock "\$LOCAL_STATE_DIR"' "$HERE/review-one-pr.sh" \
  || fail "just-test lock not pointed at LOCAL_STATE_DIR"
grep -q 'CANONICAL_LOCK_DIR="\$LOCAL_STATE_DIR/canonical-locks"' "$HERE/review-one-pr.sh" \
  || fail "canonical lock not pointed at LOCAL_STATE_DIR"

echo "PASS: container-state-split-smoke"
