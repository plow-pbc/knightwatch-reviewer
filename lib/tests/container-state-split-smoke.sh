#!/bin/bash
# Verifies the container state split: the per-PR lock + the just-test semaphore
# stay SHARED (STATE_DIR) so cross-container dedup and #100's global
# MAX_CONCURRENT_TESTS cap both hold across reviewer containers, while only the
# canonical clone/fetch lock is per-container (LOCAL_STATE_DIR). Sources
# lib/locking.sh directly — the same functions review-one-pr.sh uses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/locking.sh"

SHARED=$(mktemp -d); MARK=$(mktemp -d)
trap 'rm -rf "$SHARED" "$MARK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# Wait for the holder to signal it actually holds the lock, so the competing
# acquire races a held lock — not a fixed sleep that scheduler load could flip.
await() { local m="$1" i; for i in $(seq 1 200); do if [ -e "$m" ]; then return 0; fi; sleep 0.05; done; fail "timed out waiting for $m"; }

# Per-PR lock on the SHARED dir: a second container must lose (cross-container dedup).
( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" && touch "$MARK/pr" && sleep 5 ) &
held=$!
await "$MARK/pr"
if ( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" ); then
    fail "second container acquired the shared per-PR lock (dedup broken)"
fi
wait "$held"

# Source contract: the just-test semaphore (#100's global N-slot cap) stays on the
# SHARED STATE_DIR so MAX_CONCURRENT_TESTS holds across containers; only the
# canonical clone/fetch lock is per-container (LOCAL_STATE_DIR).
grep -q 'acquire_just_test_lock "\$STATE_DIR"' "$HERE/review-one-pr.sh" \
  || fail "just-test semaphore not on the shared STATE_DIR (global cap would break across containers)"
grep -q 'CANONICAL_LOCK_DIR="\$LOCAL_STATE_DIR/canonical-locks"' "$HERE/review-one-pr.sh" \
  || fail "canonical lock not pointed at LOCAL_STATE_DIR (per-container)"

echo "PASS: container-state-split-smoke"
