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

echo "  test_compute_applied:"

# Probes: shape (a.sh, b.md), tests (t.sh), simplification (no paths).
# Touched: a.sh, t.sh.
# Expected: shape=1 (a.sh matches), tests=1 (t.sh matches), simplification absent.
probes=$(printf 'shape\ta.sh,b.md\ntests\tt.sh\nsimplification\t')
touched=$(printf 'a.sh\nt.sh')
got=$(compute_applied <(echo "$touched") <<<"$probes" | sort)
want=$'shape\t1\ntests\t1'
[ "$got" = "$want" ] || fail "basic apply" "got=<<$got>>, want=<<$want>>"
pass "applied set = specialists with any cited path in touched set"

# Same specialist appears in 3 probes, 2 apply: count is 2.
probes2=$(printf 'shape\ta.sh\nshape\tb.sh\nshape\tc.sh')
touched2=$(printf 'a.sh\nb.sh')
got=$(compute_applied <(echo "$touched2") <<<"$probes2")
want2=$'shape\t2'
[ "$got" = "$want2" ] || fail "per-probe count" "got=<<$got>>"
pass "per-probe (not per-specialist) counting — 2 of 3 shape probes applied"

# Empty touched set → no output.
got=$(compute_applied <(echo "") <<<"$probes")
[ -z "$got" ] || fail "empty touched" "got=<<$got>>"
pass "empty touched-paths set → empty output"

echo "all compute_applied tests passed"

echo "  test_render_applied_footer:"

input=$(printf 'shape\t1\ntests\t2')
got=$(printf '%s' "$input" | render_applied_footer)
case "$got" in
    *'<!-- knightwatch-applied: {"applied":'*'"shape":1'*'"tests":2'*'} -->'*) ;;
    *) fail "marker shape" "got=<<$got>>" ;;
esac
case "$got" in
    *'**Applied since this review:**'*'shape×1'*'tests×2'*) ;;
    *) fail "footer prose" "got=<<$got>>" ;;
esac
pass "footer = marker line + human prose"

# Empty input → empty output (no probes applied, nothing to emit).
got=$(printf '' | render_applied_footer)
[ -z "$got" ] || fail "empty render" "got=<<$got>>"
pass "empty applied set → empty footer"

echo "all render_applied_footer tests passed"

echo "  test_strip_existing_marker:"

body='Review body line 1.

Some content.

<!-- knightwatch-applied: {"applied":{"shape":99}} -->
**Applied since this review:** stale.
'
stripped=$(printf '%s' "$body" | strip_applied_footer)
case "$stripped" in
    *knightwatch-applied*) fail "strip should remove marker" "got=<<$stripped>>" ;;
    *Applied\ since\ this\ review*) fail "strip should remove footer prose" "got=<<$stripped>>" ;;
    *) ;;
esac
case "$stripped" in
    *"Review body line 1."*"Some content."*) ;;
    *) fail "strip should preserve original body" "got=<<$stripped>>" ;;
esac
pass "strip removes marker + footer, preserves body"

# No-marker body → unchanged. Sentinel preserves trailing newlines that
# command substitution would otherwise strip on both inputs.
body2='Plain review.
No marker here.
'
got=$(printf '%s' "$body2" | strip_applied_footer; printf x); got=${got%x}
[ "$got" = "$body2" ] || fail "no-marker passthrough" "got=<<$got>>"
pass "body without marker passes through unchanged"

echo "all strip_applied_footer tests passed"
