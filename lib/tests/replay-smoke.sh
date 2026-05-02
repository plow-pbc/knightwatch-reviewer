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

# Scenario 2: .knightwatch/-absent note appears in aggregator output.
# Tests the stitching logic in isolation — sources run-dir.sh to get
# prepend_review_header and drives it with synthetic aggregator output,
# mirroring what replay.sh does post-pipeline. Observable: the note
# text appears in the final output file.
echo "  scenario 2: .knightwatch/-absent — note appears in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    REVIEW_NOTES+=("⚙️ No .knightwatch/ config (review using defaults)")
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/absent-out.md"
)
grep -qF "⚙️ No .knightwatch/ config (review using defaults)" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 2: absent-note not found in output"; cat "$TMPDIR/absent-out.md"; exit 1; }
grep -qF "🎬 Replay of" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 2: replay scope note not found in output"; exit 1; }

# Scenario 3: .knightwatch/-present — absent note must NOT appear.
echo "  scenario 3: .knightwatch/-present — absent note not in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    # KNIGHTWATCH_PRESENT=1 → no absent note added
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/present-out.md"
)
if grep -qF "⚙️ No .knightwatch/ config" "$TMPDIR/present-out.md"; then
    echo "FAIL scenario 3: absent-note should not appear when .knightwatch/ is present"
    cat "$TMPDIR/present-out.md"
    exit 1
fi
grep -qF "🎬 Replay of" "$TMPDIR/present-out.md" \
    || { echo "FAIL scenario 3: replay scope note not found in output"; exit 1; }

echo "OK: replay-smoke (absent-note appears; present-note suppressed)"
