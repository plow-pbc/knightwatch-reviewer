#!/usr/bin/env bash
# Smoke fence for the BOT_CMD_PREFIX env var. Proves that overriding the
# prefix actually changes which commands the bake-off walker recognizes.
# If a future refactor accidentally hardcodes a literal /srosro- or /kw-
# pattern, this test catches it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../bakeoff-parsers.sh"

echo "=== cmd-prefix override smoke ==="

echo "  default prefix (srosro): /srosro-props matches..."
BOT_CMD_PREFIX="srosro"
OUT=$(printf '/srosro-props [from: tests] solid catch\n' | extract_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: default prefix: $OUT"; exit 1; }

echo "  default prefix (srosro): /custom-props does NOT match..."
OUT=$(printf '/custom-props [from: tests] solid\n' | extract_props_attributions)
[ -z "$OUT" ] || { echo "FAIL: leaked: $OUT"; exit 1; }

echo "  custom prefix: /custom-props matches when BOT_CMD_PREFIX=custom..."
BOT_CMD_PREFIX="custom"
OUT=$(printf '/custom-props [from: tests] solid\n' | extract_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: custom prefix: $OUT"; exit 1; }

echo "  custom prefix: /srosro-props does NOT match when BOT_CMD_PREFIX=custom..."
OUT=$(printf '/srosro-props [from: tests] solid\n' | extract_props_attributions)
[ -z "$OUT" ] || { echo "FAIL: srosro leaked under custom prefix: $OUT"; exit 1; }

echo "  same for extract_critique_attributions..."
BOT_CMD_PREFIX="kw"
OUT=$(printf '/kw-critique [from: shape] misread\n' | extract_critique_attributions)
[ "$OUT" = "shape" ] || { echo "FAIL: critique under kw prefix: $OUT"; exit 1; }

echo "PASS"
