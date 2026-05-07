#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../bakeoff-parsers.sh"
FIX="$HERE/fixtures/specialist-bakeoff"

echo "=== bakeoff-parsers unit tests ==="

echo "  extract_roster_marker: comma-separated list parses to one specialist per line..."
OUT=$(extract_roster_marker < "$FIX/review-with-roster-marker.md" | sort | paste -sd, -)
[ "$OUT" = "aggregator,security,shape,tests" ] || { echo "FAIL: roster: $OUT"; exit 1; }

echo "  extract_roster_marker: missing marker emits nothing..."
NO_MARKER=$(printf '<!-- knightwatch-reviewer:auto-post -->\n\nno roster here\n' | extract_roster_marker)
[ -z "$NO_MARKER" ] || { echo "FAIL: expected empty, got: $NO_MARKER"; exit 1; }

echo "  extract_kw_props_attributions: '/kw-props [from: tests]' → tests..."
OUT=$(printf '/kw-props [from: tests] solid catch on the missing assertion\n' | extract_kw_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: kw-props: $OUT"; exit 1; }

echo "  extract_kw_props_attributions: ignores body without /kw-props line..."
OUT=$(printf 'just a comment with [from: tests] mention but no command\n' | extract_kw_props_attributions)
[ -z "$OUT" ] || { echo "FAIL: kw-props leaked: $OUT"; exit 1; }

echo "  extract_kw_critique_attributions: '/kw-critique [from: shape]' → shape..."
OUT=$(printf '/kw-critique [from: shape] this finding misread the contract\n' | extract_kw_critique_attributions)
[ "$OUT" = "shape" ] || { echo "FAIL: kw-critique: $OUT"; exit 1; }

echo "  extract_kw_critique_attributions: requires the command on the same line as the tag..."
OUT=$(printf '/kw-critique\nseparately: [from: shape] is wrong\n' | extract_kw_critique_attributions)
[ -z "$OUT" ] || { echo "FAIL: cross-line attribution leaked: $OUT"; exit 1; }

echo "PASS"
