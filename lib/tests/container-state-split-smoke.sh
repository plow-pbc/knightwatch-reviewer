#!/bin/bash
# Verifies the container state split: the per-PR lock is SHARED (two
# containers can't review the same PR), while the just-test lock is
# LOCAL (two containers CAN run `just test` concurrently). Sourcing
# lib/locking.sh directly — same functions review-one-pr.sh uses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/locking.sh"

SHARED=$(mktemp -d); LOCAL_A=$(mktemp -d); LOCAL_B=$(mktemp -d); MARK=$(mktemp -d)
trap 'rm -rf "$SHARED" "$LOCAL_A" "$LOCAL_B" "$MARK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# Wait for a holder to signal it actually holds the lock, so the competing
# acquire races a held lock — not a fixed sleep that scheduler load could flip
# (the shape the flock smoke already moved to).
await() { local m="$1" i; for i in $(seq 1 200); do if [ -e "$m" ]; then return 0; fi; sleep 0.05; done; fail "timed out waiting for $m"; }

# Per-PR lock on the SHARED dir: second acquirer must lose.
( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" && touch "$MARK/pr" && sleep 5 ) &
held=$!
await "$MARK/pr"
if ( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" ); then
    fail "second container acquired the shared per-PR lock (dedup broken)"
fi
wait "$held"

# just-test lock on DISTINCT local dirs: both must win (no serialization).
( . "$HERE/locking.sh"; acquire_just_test_lock "$LOCAL_A" "cncorp_plow" && touch "$MARK/jt" && sleep 3 ) &
a=$!
await "$MARK/jt"
if ! timeout 2 bash -c ". '$HERE/locking.sh'; acquire_just_test_lock '$LOCAL_B' cncorp_plow"; then
    fail "just-test lock on a distinct local dir blocked (parallelism broken)"
fi
wait "$a"

grep -q 'acquire_just_test_lock "\$LOCAL_STATE_DIR"' "$HERE/review-one-pr.sh" \
  || fail "just-test lock not pointed at LOCAL_STATE_DIR"
grep -q 'CANONICAL_LOCK_DIR="\$LOCAL_STATE_DIR/canonical-locks"' "$HERE/review-one-pr.sh" \
  || fail "canonical lock not pointed at LOCAL_STATE_DIR"

echo "PASS: container-state-split-smoke"
