#!/bin/bash
# Smoke test for lib/state-io.sh.
#
# Verifies two invariants that the flock-serialized state_set depends on:
#   1. Round-trip: state_set then state_get returns the same sha.
#   2. No lost writes under concurrency: 20 parallel writers all land in
#      the final state.json (this would fail if writes raced the atomic
#      rename or if jq errors silently overwrote state.json with empty).
#
# Runs in a private tmpdir — does not touch ~/.pr-reviewer.

set -euo pipefail

TMPDIR=$(mktemp -d -t state-io-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR"
export STATE_FILE="$TMPDIR/state.json"
export LOG_FILE="$TMPDIR/smoke.log"
echo '{}' > "$STATE_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../state-io.sh
. "$SCRIPT_DIR/state-io.sh"

echo "  round-trip..."
state_set "testorg/testrepo#1" "abc123" true "body"
got=$(state_get "testorg/testrepo#1" "sha")
if [ "$got" != "abc123" ]; then
    echo "FAIL: round-trip got '$got', expected 'abc123'"
    exit 1
fi

echo "  20 concurrent writers..."
for i in $(seq 1 20); do
    state_set "testorg/testrepo#$i" "sha$i" true "body $i" &
done
wait

count=$(jq 'keys | length' "$STATE_FILE")
if [ "$count" -ne 20 ]; then
    echo "FAIL: expected 20 keys after concurrent writes, got $count"
    cat "$STATE_FILE"
    exit 1
fi

got10=$(state_get "testorg/testrepo#10" "sha")
if [ "$got10" != "sha10" ]; then
    echo "FAIL: writer 10 got '$got10', expected 'sha10'"
    exit 1
fi

echo "  PASS ($count keys, round-trip ok, concurrent ok)"
