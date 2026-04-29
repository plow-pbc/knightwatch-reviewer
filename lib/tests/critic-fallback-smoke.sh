#!/bin/bash
# Smoke for critic_fallback (lib/agent-fallback.sh).
#
# The critic step is the only agent the review pipeline tolerates a failure
# from. Without this fallback, a non-zero codex exit that left a truncated
# output behind would slip past the empty-file check and ship corrupted
# counterarguments into the aggregator's first input. Lock down the three
# branches:
#   1. non-zero exit + non-empty output → placeholder substituted
#   2. zero exit + empty output → placeholder substituted
#   3. zero exit + non-empty output → file preserved untouched
#
# Sources lib/agent-fallback.sh directly so this test exercises the same
# function review-one-pr.sh calls.

set -uo pipefail

TMPDIR=$(mktemp -d -t critic-fallback-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../agent-fallback.sh
. "$PROJECT_ROOT/lib/agent-fallback.sh"

OUT="$TMPDIR/critic-output.md"

echo "  scenario 1: non-zero exit with partial output → placeholder..."
echo "partial truncated counterargument from a killed codex" > "$OUT"
critic_fallback 7 "$OUT"
if grep -q "partial truncated" "$OUT"; then
    echo "FAIL: partial output not replaced on non-zero exit"
    cat "$OUT"
    exit 1
fi
if ! grep -q "(critic failed with exit=7 — fall back)" "$OUT"; then
    echo "FAIL: placeholder not written on non-zero exit"
    cat "$OUT"
    exit 1
fi

echo "  scenario 2: zero exit with empty output → placeholder..."
: > "$OUT"
critic_fallback 0 "$OUT"
if ! grep -q "(critic output empty — fall back)" "$OUT"; then
    echo "FAIL: placeholder not written on empty output"
    cat "$OUT"
    exit 1
fi

echo "  scenario 3: zero exit with real output → leave alone..."
echo "real critic counterargument" > "$OUT"
critic_fallback 0 "$OUT"
if ! grep -q "real critic counterargument" "$OUT"; then
    echo "FAIL: clean success output was modified"
    cat "$OUT"
    exit 1
fi

echo "  PASS (3 scenarios: non-zero overrides partial, empty gets placeholder, success preserved)"
