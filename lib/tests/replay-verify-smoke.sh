#!/usr/bin/env bash
# Smoke: lib/replay-verify.sh fixture-parser + matcher.
#
# Runs the verifier in --no-replay mode against synthetic aggregator-output
# fixtures so the parser/matcher logic is exercised without burning codex
# calls. Behavioral end-to-end (does verifier correctly drive a real
# replay?) is covered by manual operator runs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

FIXTURE_DIR="lib/tests/fixtures/replay-verify"
[ -f "$FIXTURE_DIR/sample-fixture.md" ] || { echo "FAIL: missing sample-fixture.md"; exit 1; }
[ -f "$FIXTURE_DIR/sample-aggregator-output.md" ] || { echo "FAIL: missing sample-aggregator-output.md"; exit 1; }

# Test 1: passing — synthetic aggregator-output meets all expectations
echo "  test 1: passing fixture..."
if ! ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$FIXTURE_DIR/sample-aggregator-output.md" \
        > /tmp/replay-verify-pass.log 2>&1; then
    cat /tmp/replay-verify-pass.log
    echo "FAIL: expected pass, got non-zero exit"
    exit 1
fi

# Test 2: failing keyword_all — temp aggregator-output missing a required keyword
echo "  test 2: failing keyword_all..."
TMP_AGG=$(mktemp)
trap 'rm -f "$TMP_AGG"' EXIT
sed 's/simplification/something-else/g' "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG"
if ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$TMP_AGG" \
        > /tmp/replay-verify-fail.log 2>&1; then
    cat /tmp/replay-verify-fail.log
    echo "FAIL: expected non-zero exit, got pass"
    exit 1
fi
grep -q "FAIL:" /tmp/replay-verify-fail.log || { echo "FAIL: expected FAIL: line in stderr"; exit 1; }

# Test 3: expected_NOT triggered — synthetic output spuriously cites a credential
echo "  test 3: expected_NOT triggers FAIL..."
TMP_AGG2=$(mktemp)
trap 'rm -f "$TMP_AGG" "$TMP_AGG2"' EXIT
cat "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG2"
cat >> "$TMP_AGG2" <<'PROBE'

- [from: security] **Q:** credential leak in CI? `Severity: blocking` `Class: bug`
PROBE
if ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$TMP_AGG2" \
        > /tmp/replay-verify-not.log 2>&1; then
    cat /tmp/replay-verify-not.log
    echo "FAIL: expected non-zero (expected_NOT triggered), got pass"
    exit 1
fi
grep -q "expected_NOT triggered" /tmp/replay-verify-not.log || \
    { echo "FAIL: expected 'expected_NOT triggered' diagnostic"; exit 1; }

echo "  PASS"
