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

# Scenario 1: REVIEW.md-absent → note appears in aggregator output.
echo "  scenario 1: REVIEW.md-absent — note appears in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    REVIEW_NOTES+=("⚙️ No REVIEW.md (review using org defaults)")
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/absent-out.md"
)
grep -qF "⚙️ No REVIEW.md (review using org defaults)" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 1: absent-note not found in output"; cat "$TMPDIR/absent-out.md"; exit 1; }
grep -qF "🎬 Replay of" "$TMPDIR/absent-out.md" \
    || { echo "FAIL scenario 1: replay scope note not found in output"; exit 1; }

# Scenario 2: REVIEW.md-present → absent note must NOT appear.
echo "  scenario 2: REVIEW.md-present — absent note not in aggregator output..."
(
    set +u
    . "$REPO_ROOT/lib/run-dir.sh"
    MARKER='<!-- knightwatch-reviewer:auto-post -->'
    SYNTHETIC_BODY="$(printf '%s\nSome review content.\n' "$MARKER")"
    REVIEW_NOTES=()
    REVIEW_NOTES+=("🎬 Replay of \`abc1234\` (\`gh pr view --repo owner/repo 7\`)")
    # resolve_review_md rc=0 (per-repo REVIEW.md) → no absent note added
    STITCHED=$(prepend_review_header "$SYNTHETIC_BODY" "${REVIEW_NOTES[@]}")
    printf '%s\n' "$STITCHED" > "$TMPDIR/present-out.md"
)
if grep -qF "⚙️ No REVIEW.md" "$TMPDIR/present-out.md"; then
    echo "FAIL scenario 2: absent-note should not appear when REVIEW.md is present"
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

# Scenario 4: replay.sh's author/base derivation and its fail-loud guard.
#
# From #206 until #213 line 120 read PR_AUTHOR="$REPLAY_PR_AUTHOR" — a
# self-assignment of a never-set name — so `set -u` aborted every replay at
# clone time and the whole harness was dead. Nothing in `just test` touched
# that path, which is why it went unnoticed for weeks.
#
# Anchored EREs, each requiring the snapshot variable, the jq path, AND the
# `// empty` fallback. All three parts are load-bearing: the anchor rejects a
# REPLAY_-prefixed rename of the assigned name (the #206 shape, where the
# consumed name is never set); requiring REPLAY_PR_META + jq rejects a
# self-assignment; and `// empty` is what stops `jq -r` printing the literal
# string "null" for absent metadata, which would pass [ -n "$VAR" ] and let
# the pipeline run with PR_AUTHOR=null or fetch `origin null`.
echo "  scenario 4: replay.sh derives + guards BASE_REF and PR_AUTHOR..."
REPLAY_SH="$REPO_ROOT/lib/replay.sh"
grep -qE '^BASE_REF=.*REPLAY_PR_META.*baseRefName.*// empty' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh no longer derives BASE_REF from REPLAY_PR_META with the // empty fallback"; exit 1; }
grep -qE '^PR_AUTHOR=.*REPLAY_PR_META.*author\.login.*// empty' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh no longer derives PR_AUTHOR from REPLAY_PR_META with the // empty fallback"; exit 1; }
grep -qE '^PR_TITLE=.*REPLAY_PR_META.*\.title.*// empty' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh no longer derives PR_TITLE from REPLAY_PR_META with the // empty fallback"; exit 1; }
grep -qF '[ -n "$BASE_REF" ] && [ -n "$PR_AUTHOR" ]' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay.sh lost the fail-loud guard on BASE_REF / PR_AUTHOR"; exit 1; }
grep -qE '\{actual: \$actual, bot: \$bot, sha: \$sha, author: \$author\}' "$REPLAY_SH" \
    || { echo "FAIL scenario 4: replay complexity metadata no longer carries PR_AUTHOR into the pipeline"; exit 1; }

echo "OK: replay-smoke (absent-note appears; present-note suppressed; replay-batch index.md emitted; replay.sh derivation + guard fenced)"
