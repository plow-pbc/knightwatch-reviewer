#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Dry-run mode: pass --dry-run to skip codex; assert the prep steps work.
"$REPO_ROOT/lib/replay.sh" --dry-run \
  --repo srosro/knightwatch-reviewer \
  --pr 43 \
  --sha HEAD \
  --output-dir "$TMPDIR/replay-out"

# Assertions
test -d "$TMPDIR/replay-out" || { echo "FAIL: output dir not created"; exit 1; }
test -s "$TMPDIR/replay-out/diff.patch" || { echo "FAIL: diff.patch not written"; exit 1; }
test -s "$TMPDIR/replay-out/manifest.json" || { echo "FAIL: manifest.json not written"; exit 1; }

# Validate manifest.json content
jq -e '.repo == "srosro/knightwatch-reviewer" and .pr == 43 and .sha == "HEAD" and .dry_run == true' \
    "$TMPDIR/replay-out/manifest.json" >/dev/null \
    || { echo "FAIL: manifest.json content invalid"; exit 1; }

echo "OK: replay-smoke (dry-run)"
