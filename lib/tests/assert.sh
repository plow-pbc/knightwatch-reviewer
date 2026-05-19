#!/usr/bin/env bash
# Shared assertion helpers for lib/tests/*.sh smokes.
#
# Sourced — do not exec. Each helper:
#   - emits a uniform "FAIL: <msg>\n  at: <file>:<line>\n  got: ...\n  want: ..."
#     diagnostic to stderr on mismatch
#   - exits 1 on mismatch
#   - is no-op on match
#
# Always call helpers as a top-level statement, never inside `... || ...`
# or `if assert_eq ...`. `set -e` does NOT propagate from a function used
# in conditional context, so the exit 1 inside the helper would be
# swallowed and the test would silently continue past a failed assertion.

_assert_fail() {
    # Caller's caller — index 2 because _assert_fail is called from
    # an assert_* function. BASH_LINENO[1] is the line in BASH_SOURCE[2]
    # (offset-by-one is documented bash behavior).
    local msg="$1" got="$2" want="$3"
    local src="${BASH_SOURCE[2]:-<unknown>}"
    local lno="${BASH_LINENO[1]:-<unknown>}"
    {
        echo "FAIL: ${msg:-assertion failed}"
        echo "  at:   $src:$lno"
        echo "  got:  $got"
        echo "  want: $want"
    } >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] && return 0
    _assert_fail "${3:-}" "$1" "$2"
}
