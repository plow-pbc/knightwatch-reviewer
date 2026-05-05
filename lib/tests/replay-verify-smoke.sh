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

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

# expect_pass NAME AGG_FILE
# Verifier should exit 0 against the supplied aggregator-output.
expect_pass() {
    local name="$1" agg="$2"
    echo "  test: $name (expect pass)..."
    if ! ./lib/replay-verify.sh \
            --fixture "$FIXTURE_DIR/sample-fixture.md" \
            --no-replay "$agg" \
            > "$LOG_DIR/$name.log" 2>&1; then
        cat "$LOG_DIR/$name.log"
        echo "FAIL: $name expected pass, got non-zero exit"
        exit 1
    fi
}

# expect_fail NAME AGG_FILE GREP_PATTERN
# Verifier should exit non-zero AND its output should contain GREP_PATTERN.
expect_fail() {
    local name="$1" agg="$2" pattern="$3"
    echo "  test: $name (expect fail w/ '$pattern')..."
    if ./lib/replay-verify.sh \
            --fixture "$FIXTURE_DIR/sample-fixture.md" \
            --no-replay "$agg" \
            > "$LOG_DIR/$name.log" 2>&1; then
        cat "$LOG_DIR/$name.log"
        echo "FAIL: $name expected non-zero exit, got pass"
        exit 1
    fi
    grep -q "$pattern" "$LOG_DIR/$name.log" || {
        cat "$LOG_DIR/$name.log"
        echo "FAIL: $name expected '$pattern' diagnostic"
        exit 1
    }
}

# Test 1: passing fixture
expect_pass "passing" "$FIXTURE_DIR/sample-aggregator-output.md"

# Test 2: expected_contains violation — strip required `simplification` substring
TMP_AGG="$LOG_DIR/keyword-missing.agg.md"
sed 's/simplification/something-else/g' "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG"
expect_fail "expected_contains_missing" "$TMP_AGG" "expected_contains 'simplification' not found"

# Test 3: expected_absent triggered — append a security blocking probe
TMP_AGG2="$LOG_DIR/expected-not.agg.md"
cat "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG2"
cat >> "$TMP_AGG2" <<'PROBE'

2. [blocking] [from: security] [bug] credential leak in CI. Files: x:1. Edit: rotate the credential.
PROBE
expect_fail "expected_absent_triggered" "$TMP_AGG2" "expected_absent 'credential' found"

# Test 4: verdict mismatch — flip COMMENT to APPROVE
TMP_AGG3="$LOG_DIR/verdict-mismatch.agg.md"
sed 's/^VERDICT: COMMENT/VERDICT: APPROVE/' "$FIXTURE_DIR/sample-aggregator-output.md" > "$TMP_AGG3"
expect_fail "verdict_mismatch" "$TMP_AGG3" "verdict mismatch"

echo "  test: privacy-default tripwire..."
# Privacy fence: the replay entrypoints must default to ~/.pr-reviewer/
# (not repo-local replays/...). lib/replay.sh and lib/replay-batch.sh own
# this default; the verifier wrapper inherits it. A regression here would
# silently leak private-fixture artifacts into the repo working tree.
grep -qF '${OUT:-$HOME/.pr-reviewer/replays/' lib/replay.sh || \
    { echo "FAIL: lib/replay.sh OUT default no longer points to ~/.pr-reviewer/"; exit 1; }
grep -qF '${OUT:-$HOME/.pr-reviewer/replays/' lib/replay-batch.sh || \
    { echo "FAIL: lib/replay-batch.sh OUT default no longer points to ~/.pr-reviewer/"; exit 1; }

echo "  PASS"
