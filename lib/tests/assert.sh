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

assert_match() {
    # Bash =~ regex match. $2 is interpreted as ERE; do not quote inside [[ ]].
    [[ "$1" =~ $2 ]] && return 0
    _assert_fail "${3:-}" "$1" "match: $2"
}

assert_contains() {
    case "$1" in
        (*"$2"*) return 0 ;;
    esac
    _assert_fail "${3:-}" "$1" "contains: $2"
}

assert_empty() {
    [ -z "$1" ] && return 0
    _assert_fail "${2:-}" "$1" "(empty)"
}

assert_neq() {
    [ "$1" != "$2" ] && return 0
    _assert_fail "${3:-}" "$1" "not: $2"
}

assert_not_empty() {
    [ -n "$1" ] && return 0
    _assert_fail "${2:-}" "(empty)" "(non-empty)"
}

assert_exists() {
    [ -e "$1" ] && return 0
    _assert_fail "${2:-}" "$1" "(path should exist)"
}

assert_not_exists() {
    # Treat symlinks as existing too — a dangling symlink counts as "exists"
    # for sibling-walk safety (the symlink itself is the artifact).
    if [ -e "$1" ] || [ -L "$1" ]; then
        _assert_fail "${2:-}" "$1" "(path should not exist)"
    fi
}
