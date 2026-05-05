#!/usr/bin/env bash
# Smoke: lib/replay-verify.sh fixture-parser + matcher.
#
# Runs the verifier in --no-replay mode against synthetic aggregator-output
# fixtures so the parser/matcher logic is exercised without burning codex
# calls. Behavioral end-to-end (does verifier correctly drive a real
# replay?) is covered by manual operator runs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR" "${TMP_AGG:-}" "${TMP_AGG2:-}" "${TMP_AGG3:-}"' EXIT

FIXTURE_DIR="lib/tests/fixtures/replay-verify"
[ -f "$FIXTURE_DIR/sample-fixture.md" ] || { echo "FAIL: missing sample-fixture.md"; exit 1; }
[ -f "$FIXTURE_DIR/sample-aggregator-output.md" ] || { echo "FAIL: missing sample-aggregator-output.md"; exit 1; }

# Test 1: passing — synthetic aggregator-output meets all expectations
echo "  test 1: passing fixture..."
if ! ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$FIXTURE_DIR/sample-aggregator-output.md" \
        > "$LOG_DIR/pass.log" 2>&1; then
    cat "$LOG_DIR/pass.log"
    echo "FAIL: expected pass, got non-zero exit"
    exit 1
fi

# Test 2: failing keyword_all — temp aggregator-output missing a required keyword
echo "  test 2: failing keyword_all..."
TMP_AGG=$(mktemp)
sed 's/simplification/something-else/g' "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG"
if ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$TMP_AGG" \
        > "$LOG_DIR/fail.log" 2>&1; then
    cat "$LOG_DIR/fail.log"
    echo "FAIL: expected non-zero exit, got pass"
    exit 1
fi
grep -q "FAIL:" "$LOG_DIR/fail.log" || { echo "FAIL: expected FAIL: line in stderr"; exit 1; }

# Test 3: expected_NOT triggered — synthetic output spuriously cites a credential
echo "  test 3: expected_NOT triggers FAIL..."
TMP_AGG2=$(mktemp)
cat "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG2"
cat >> "$TMP_AGG2" <<'PROBE'

2. [blocking] [from: security] [bug] credential leak in CI. Files: x:1. Edit: rotate the credential.
PROBE
if ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$TMP_AGG2" \
        > "$LOG_DIR/not.log" 2>&1; then
    cat "$LOG_DIR/not.log"
    echo "FAIL: expected non-zero (expected_NOT triggered), got pass"
    exit 1
fi
grep -q "expected_NOT triggered" "$LOG_DIR/not.log" || \
    { echo "FAIL: expected 'expected_NOT triggered' diagnostic"; exit 1; }

# Test 4: verdict mismatch — synthetic VERDICT changed to APPROVE; fixture expects COMMENT
echo "  test 4: verdict mismatch..."
TMP_AGG3=$(mktemp)
sed 's/^VERDICT: COMMENT/VERDICT: APPROVE/' "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG3"
if ./lib/replay-verify.sh \
        --fixture "$FIXTURE_DIR/sample-fixture.md" \
        --no-replay "$TMP_AGG3" \
        > "$LOG_DIR/verdict.log" 2>&1; then
    cat "$LOG_DIR/verdict.log"
    echo "FAIL: expected non-zero (verdict mismatch), got pass"
    exit 1
fi
grep -q "verdict mismatch" "$LOG_DIR/verdict.log" || \
    { cat "$LOG_DIR/verdict.log"; echo "FAIL: expected 'verdict mismatch' diagnostic"; exit 1; }

echo "  PASS"
