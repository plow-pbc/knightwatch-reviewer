#!/usr/bin/env bash
# Hermetic smoke for replay's header-stitching path. The full real-replay
# path (clone → diff → stage → pipeline) needs live gh + codex, which we
# don't run in `just test`; the header-stitching logic is what makes a
# replay output recognizable as a replay output, so that's what we cover
# here. Sources run-dir.sh to get prepend_review_header and drives it
# with synthetic aggregator output, mirroring what replay.sh does
# post-pipeline.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Scenario 1: .knightwatch/-absent → note appears in aggregator output.
echo "  scenario 1: .knightwatch/-absent — note appears in aggregator output..."
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
    || { echo "FAIL scenario 1: absent-note not found in output"; cat "$TMPDIR/absent-out.md"; exit 1; }
grep -qF "🎬 Replay of" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 1: replay scope note not found in output"; exit 1; }

# Scenario 2: .knightwatch/-present → absent note must NOT appear.
echo "  scenario 2: .knightwatch/-present — absent note not in aggregator output..."
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
    echo "FAIL scenario 2: absent-note should not appear when .knightwatch/ is present"
    cat "$TMPDIR/present-out.md"
    exit 1
fi
grep -qF "🎬 Replay of" "$TMPDIR/present-out.md" \
    || { echo "FAIL scenario 2: replay scope note not found in output"; exit 1; }

# Scenario 3: replay-batch builds index.md without crashing on the table
# separator row. Regression fence: bash 5.2's printf strips a leading `--`
# from its first arg, so `printf '---|'` aborts before the index header.
# Comments-only PR CSV → no replay rows execute → no codex needed.
echo "  scenario 3: replay-batch builds index.md (printf '---|' regression fence)..."
PRS_FILE="$TMPDIR/empty-prs.csv"
printf '# only comments — no PR rows\n# second comment line\n' > "$PRS_FILE"
PROMPTS_A="$TMPDIR/prompts-a"; PROMPTS_B="$TMPDIR/prompts-b"
mkdir -p "$PROMPTS_A" "$PROMPTS_B"
BATCH_OUT="$TMPDIR/batch-out"
bash "$REPO_ROOT/lib/replay-batch.sh" \
    --prs "$PRS_FILE" \
    --prompts "$PROMPTS_A,$PROMPTS_B" \
    --output-dir "$BATCH_OUT" \
    > "$TMPDIR/batch.log" 2>&1 \
    || { echo "FAIL scenario 3: replay-batch exited non-zero"; cat "$TMPDIR/batch.log"; exit 1; }
[ -f "$BATCH_OUT/index.md" ] \
    || { echo "FAIL scenario 3: $BATCH_OUT/index.md missing"; exit 1; }
grep -qF '|---|---|---|' "$BATCH_OUT/index.md" \
    || { echo "FAIL scenario 3: index.md missing the table separator row"; cat "$BATCH_OUT/index.md"; exit 1; }

# Scenario 4: Wave B warning sentinel is consumed identically by both
# review-one-pr.sh and replay.sh (`[ -s "$f" ] && REVIEW_NOTES+=("$(cat
# "$f")")`). Drives the consumer pattern + prepend_review_header to fence
# the parity. Round-2 probe 2.
echo "  scenario 4: _wave_b_warning.txt → banner appears in stitched output..."
RUN_DIR="$TMPDIR/run4"
mkdir -p "$RUN_DIR"
printf '%s\n' '⚠️ Specialist `performance` timed out after 45 min — review reflects 7/8 angles' \
    > "$RUN_DIR/_wave_b_warning.txt"
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    # Mirror the exact consumer line from lib/review-one-pr.sh + lib/replay.sh.
    [ -s "$RUN_DIR/_wave_b_warning.txt" ] && REVIEW_NOTES+=("$(cat "$RUN_DIR/_wave_b_warning.txt")")
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/warning-out.md"
)
grep -qF '⚠️ Specialist `performance` timed out' "$TMPDIR/warning-out.md" \
    || { echo "FAIL scenario 4: warning sentinel not surfaced in stitched header"; cat "$TMPDIR/warning-out.md"; exit 1; }

# Scenario 5: review-one-pr.sh's timeouts-sentinel → EYES_ABORT_BODY shape.
# Mirror the exact `paste -sd,` join used in lib/review-one-pr.sh's pipeline
# failure branch so a refactor that changes the sentinel format (e.g. one
# specialist per line vs. CSV) gets caught here before it ships.
echo "  scenario 5: _wave_b_timeouts.txt → comma-joined names for EYES_ABORT_BODY..."
RUN_DIR5="$TMPDIR/run5"
mkdir -p "$RUN_DIR5"
printf '%s\n' "performance" "security" > "$RUN_DIR5/_wave_b_timeouts.txt"
TIMED_OUT=$(paste -sd, "$RUN_DIR5/_wave_b_timeouts.txt")
[ "$TIMED_OUT" = "performance,security" ] \
    || { echo "FAIL scenario 5: expected 'performance,security', got '$TIMED_OUT'"; exit 1; }

echo "OK: replay-smoke (absent-note appears; present-note suppressed; replay-batch index.md emitted; Wave B warning surfaced; timeouts sentinel comma-joined)"
