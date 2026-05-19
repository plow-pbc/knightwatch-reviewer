#!/usr/bin/env bash
# Self-tests for lib/tests/assert.sh.
#
# Pass-path tests are inline — if a helper wrongly fails on equal input
# this script exits non-zero with assert.sh's own FAIL output. Fail-path
# tests fork a subshell, run the helper with mismatched input, and assert
# the subshell exited 1 + emitted "FAIL:" on stderr.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_ROOT/lib/tests/assert.sh"

# Capture stdout, stderr, and exit code separately. Sets globals:
#   SUB_OUT (stdout text), SUB_ERR (stderr text), SUB_RC (exit code).
# Separate capture lets us assert FAIL diagnostics land on stderr, not stdout.
run_subshell() {
    local stdout_file stderr_file
    stdout_file=$(mktemp)
    stderr_file=$(mktemp)
    bash -c "
        . '$REPO_ROOT/lib/tests/assert.sh'
        $1
    " >"$stdout_file" 2>"$stderr_file" && SUB_RC=0 || SUB_RC=$?
    SUB_OUT=$(cat "$stdout_file")
    SUB_ERR=$(cat "$stderr_file")
    rm -f "$stdout_file" "$stderr_file"
}

echo "  assert_eq: equal strings → pass..."
assert_eq "abc" "abc" "should pass"

echo "  assert_eq: differing strings → exit 1 + FAIL on stderr + file:line on stderr..."
run_subshell 'assert_eq "abc" "xyz" "mismatch msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: mismatch msg"*) ;;
    *) echo "FAIL: stderr missing FAIL line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"got:  abc"*) ;;
    *) echo "FAIL: stderr missing got line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"want: xyz"*) ;;
    *) echo "FAIL: stderr missing want line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"at:"*) ;;
    *) echo "FAIL: stderr missing at: line: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_eq: empty msg arg → default 'assertion failed'..."
run_subshell 'assert_eq "a" "b"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: expected exit 1"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: assertion failed"*) ;;
    *) echo "FAIL: default msg missing: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_match: regex hit → pass..."
assert_match "knightwatch-reviewer-build-42" '^knightwatch-' "should match prefix"

echo "  assert_match: regex miss → exit 1 + FAIL on stderr..."
run_subshell 'assert_match "abc" "^xyz$" "regex msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_match miss expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: regex msg"*) ;;
    *) echo "FAIL: assert_match stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"got:  abc"*) ;;
    *) echo "FAIL: assert_match stderr missing got: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"want: match: ^xyz\$"*) ;;
    *) echo "FAIL: assert_match stderr missing want: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"at:"*) ;;
    *) echo "FAIL: assert_match stderr missing at: line: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_match: regex with ERE metachars → pass (unquoted \$2 contract)..."
assert_match "version-12-build" '^version-[0-9]+-build$' "ERE metachar should match"

echo "  assert_contains: substring present → pass..."
assert_contains "the quick brown fox" "quick" "should contain"

echo "  assert_contains: substring absent → exit 1 + FAIL on stderr..."
run_subshell 'assert_contains "abc" "xyz" "substr msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_contains miss expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: substr msg"*) ;;
    *) echo "FAIL: assert_contains stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"got:  abc"*) ;;
    *) echo "FAIL: assert_contains stderr missing got: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"want: contains: xyz"*) ;;
    *) echo "FAIL: assert_contains stderr missing want: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"at:"*) ;;
    *) echo "FAIL: assert_contains stderr missing at: line: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_empty: empty string → pass..."
assert_empty "" "should be empty"

echo "  assert_empty: non-empty → exit 1 + FAIL on stderr..."
run_subshell 'assert_empty "leaked" "leak msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_empty miss expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: leak msg"*) ;;
    *) echo "FAIL: assert_empty stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"got:  leaked"*) ;;
    *) echo "FAIL: assert_empty stderr missing got: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"want: (empty)"*) ;;
    *) echo "FAIL: assert_empty stderr missing want: line: $SUB_ERR"; exit 1 ;;
esac
case "$SUB_ERR" in
    *"at:"*) ;;
    *) echo "FAIL: assert_empty stderr missing at: line: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_neq: differing strings → pass..."
assert_neq "abc" "xyz" "should differ"

echo "  assert_neq: equal strings → exit 1 + FAIL on stderr..."
run_subshell 'assert_neq "abc" "abc" "neq msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_neq pass-when-equal expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: neq msg"*) ;;
    *) echo "FAIL: assert_neq stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_not_empty: non-empty string → pass..."
assert_not_empty "x" "should be non-empty"

echo "  assert_not_empty: empty string → exit 1 + FAIL on stderr..."
run_subshell 'assert_not_empty "" "ne msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_not_empty fail-on-empty expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: ne msg"*) ;;
    *) echo "FAIL: assert_not_empty stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_exists: existing file → pass..."
tmp=$(mktemp)
assert_exists "$tmp" "tmp file should exist"
rm -f "$tmp"

echo "  assert_exists: missing path → exit 1 + FAIL on stderr..."
run_subshell 'assert_exists "/nonexistent/path/xyz123" "exists msg"'
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_exists fail-on-missing expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: exists msg"*) ;;
    *) echo "FAIL: assert_exists stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac

echo "  assert_not_exists: missing path → pass..."
assert_not_exists "/nonexistent/path/xyz123" "should not exist"

echo "  assert_not_exists: existing file → exit 1 + FAIL on stderr..."
tmp=$(mktemp)
run_subshell "assert_not_exists '$tmp' 'notexists msg'"
[ "$SUB_RC" = "1" ] || { echo "FAIL: assert_not_exists fail-on-exists expected exit 1, got $SUB_RC"; exit 1; }
[ -z "$SUB_OUT" ] || { echo "FAIL: diagnostic leaked to stdout: $SUB_OUT"; exit 1; }
case "$SUB_ERR" in
    *"FAIL: notexists msg"*) ;;
    *) echo "FAIL: assert_not_exists stderr missing FAIL: $SUB_ERR"; exit 1 ;;
esac
rm -f "$tmp"

echo "PASS (assert_eq/match/contains/empty/neq/not_empty/exists/not_exists: 18 scenarios)"
