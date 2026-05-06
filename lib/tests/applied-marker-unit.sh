#!/usr/bin/env bash
# Unit tests for lib/applied-marker.sh — pure functions, hermetic.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/lib/applied-marker.sh"

pass() { echo "    PASS: $1"; }
fail() { echo "    FAIL: $1: $2" >&2; exit 1; }

echo "  test_extract_probes_from_review:"

input='**Probes**

1. [blocking] [from: shape] [shape] Foo. Files: a.sh:1, b.md. Edit: Address.

2. [low] [from: tests] [tests] Bar. Files: t.sh. Edit: Add a case.
'
got=$(printf '%s' "$input" | extract_probes_from_review | sort)
want=$'shape\ta.sh,b.md\ntests\tt.sh'
[ "$got" = "$want" ] || fail "two-probe extract" "got=<<$got>>, want=<<$want>>"
pass "two probes, comma-joined paths"

# Probe with no [from:] tag (legacy/malformed) → not emitted.
input2='1. [blocking] [shape] No specialist. Files: x.sh. Edit: y.'
got=$(printf '%s' "$input2" | extract_probes_from_review)
[ -z "$got" ] || fail "no-tag drop" "got=<<$got>>"
pass "probe without [from:] tag is silently dropped"

# Probe with no Files: clause → empty paths field, still emit.
input3='1. [blocking] [from: shape] [shape] Edit-only probe. Edit: do x.'
got=$(printf '%s' "$input3" | extract_probes_from_review)
want3=$'shape\t'
[ "$got" = "$want3" ] || fail "no-files extract" "got=<<$got>>"
pass "probe with no Files: clause yields specialist + empty paths"

# Edit: clause paths must NOT leak into Files:.
input4='1. [low] [from: tests] [tests] Foo. Files: real.sh. Edit: Update fake.sh:99.'
got=$(printf '%s' "$input4" | extract_probes_from_review)
want4=$'tests\treal.sh'
[ "$got" = "$want4" ] || fail "edit isolation" "got=<<$got>>"
pass "Edit: clause paths do not leak into Files:"

# Backtick wrapping + :LINE suffix on cited paths must be normalized.
input5='1. [blocking] [from: shape] [shape] Foo. Files: `lib/foo.sh:42`, bar.md.'
got=$(printf '%s' "$input5" | extract_probes_from_review)
want5=$'shape\tlib/foo.sh,bar.md'
[ "$got" = "$want5" ] || fail "backtick + :LINE normalization" "got=<<$got>>"
pass "backticks stripped, :LINE suffix dropped"

echo "all extract_probes_from_review tests passed"
