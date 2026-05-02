#!/usr/bin/env bash
# Smoke for critic_fallback (lib/agent-fallback.sh).
#
# The critic step is the only agent the review pipeline tolerates a failure
# from. Without this fallback, a non-zero codex exit that left a truncated
# output behind would slip past the empty-file check and ship corrupted
# counterarguments into the aggregator's first input. Lock down the
# observable branches:
#   1. non-zero exit + non-empty output → placeholder substituted
#   2. exit 3 (run-specialist's empty-output signal) → placeholder substituted
#   3. zero exit + non-empty output → file preserved untouched
#
# Run-specialist's contract is "exit 0 ⇒ output.md non-empty" (verified by
# run-specialist-smoke.sh), so an empty file with a zero exit is
# unreachable in production and not part of critic_fallback's surface.
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
if ! grep -q "## Resolved probes" "$OUT"; then
    echo "FAIL: probe-format placeholder not written on non-zero exit"
    cat "$OUT"
    exit 1
fi
if ! grep -q "exit=7" "$OUT"; then
    echo "FAIL: exit code not embedded in fallback placeholder"
    cat "$OUT"
    exit 1
fi
if ! grep -q "## Generated probes" "$OUT"; then
    echo "FAIL: Generated probes section not written in fallback placeholder"
    cat "$OUT"
    exit 1
fi

echo "  scenario 2: empty output reaches the function via run-specialist exit 3 → placeholder..."
: > "$OUT"
critic_fallback 3 "$OUT"
if ! grep -q "## Resolved probes" "$OUT"; then
    echo "FAIL: probe-format placeholder not written on run-specialist's empty-output exit (3)"
    cat "$OUT"
    exit 1
fi
if ! grep -q "exit=3" "$OUT"; then
    echo "FAIL: exit code 3 not embedded in fallback placeholder"
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

echo "  PASS (3 scenarios: non-zero overrides partial, exit-3-on-empty gets placeholder, success preserved)"
