#!/bin/bash
# Replay a PR review at a historical SHA. Writes outputs to <output-dir>.
# Usage:
#   ./lib/replay.sh --repo OWNER/REPO --pr N --sha SHA [--output-dir PATH] [--dry-run]
#
# Modes:
#   default: runs the full LLM pipeline (codex) against the historical SHA
#   --dry-run: prepares the input scratch dir + manifest, skips codex
set -euo pipefail

DRY_RUN=0
REPO=""; PR=""; SHA=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --sha) SHA="$2"; shift 2 ;;
        --output-dir) OUT="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || {
    echo "usage: $0 --repo OWNER/REPO --pr N --sha SHA [--output-dir PATH] [--dry-run]" >&2
    exit 2
}
OUT="${OUT:-replays/${REPO//\//-}-${PR}-${SHA:0:7}}"
mkdir -p "$OUT"

# Manifest captures replay provenance — deterministic spot-check input
jq -n \
  --arg repo "$REPO" \
  --argjson pr "$PR" \
  --arg sha "$SHA" \
  --argjson dry_run "$DRY_RUN" \
  '{repo: $repo, pr: $pr, sha: $sha, replayed_at: (now | todate), dry_run: ($dry_run == 1)}' \
  > "$OUT/manifest.json"

if [ "$DRY_RUN" -eq 1 ]; then
    # Dry-run: prep scratch and fallback to gh pr diff (not historical)
    gh pr diff "$PR" --repo "$REPO" --patch > "$OUT/diff.patch"
    echo "dry-run: scratch prepared at $OUT"
    exit 0
fi

# Real replay: stage the same .codex-scratch inputs run_specialist_pipeline reads,
# then invoke run_specialist_pipeline against a fresh checkout at $SHA. The post-
# pipeline gh-posting step is deliberately skipped — we only want the rendered review.
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$LIB_DIR/state-io.sh"
. "$LIB_DIR/prompt-build.sh"
. "$LIB_DIR/agent-fallback.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/critic-splitter.sh"
. "$LIB_DIR/go-deep-rank.sh"
. "$LIB_DIR/orchestrate.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone "https://github.com/$REPO.git" "$WORK/repo"
( cd "$WORK/repo" && git fetch origin "pull/$PR/head" && git checkout "$SHA" )

# Build diff at the historical SHA using local git diff, not gh pr diff
BASE_REF="$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq .baseRefName)"
( cd "$WORK/repo" && git fetch origin "$BASE_REF" )
git -C "$WORK/repo" diff "origin/$BASE_REF...$SHA" > "$OUT/diff.patch"

REPO_DIR="$WORK/repo"
RUN_DIR="$WORK/run"
mkdir -p "$RUN_DIR/agents" "$REPO_DIR/.codex-scratch"
cp "$OUT/diff.patch" "$REPO_DIR/.codex-scratch/diff.patch"

# Minimal scratch staging — most prompts fail-soft on empty inputs.
# Real replay fidelity (full staging matching review-one-pr.sh) is deferred to
# the first invocation in Task 1.5; this is the floor that lets the pipeline boot.
for f in standards.md review-priority.md decline-history.md loc-trend.md \
         prior-art.md dead-code-static.md prior-reviews.md previous-review.md \
         file-history.md commits.md author-intent.md search-roots.md; do
    : > "$REPO_DIR/.codex-scratch/$f"
done
# standards.md needs real content — copy from current repo
cp "$LIB_DIR/../prompts/probe-schema.md" "$REPO_DIR/.codex-scratch/standards.md" 2>/dev/null \
    || cp "$LIB_DIR/../prompts/standards.md" "$REPO_DIR/.codex-scratch/standards.md" 2>/dev/null \
    || true

PR_ID="$REPO#$PR"
PR_TITLE="$(gh pr view "$PR" --repo "$REPO" --json title --jq .title)"
PR_URL="https://github.com/$REPO/pull/$PR"
PR_AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login)"
_LIB_DIR="$LIB_DIR"
LOG_FILE="$OUT/run.log"

run_specialist_pipeline

# Detect .knightwatch/ presence at the replayed SHA. ls-tree exits 0
# regardless of presence/absence; empty stdout → absent.
if git -C "$REPO_DIR" ls-tree "$SHA" .knightwatch/ 2>/dev/null | grep -q .; then
    KNIGHTWATCH_PRESENT=1
else
    KNIGHTWATCH_PRESENT=0
fi

REVIEW_NOTES=()
REVIEW_NOTES+=("🎬 Replay of \`$SHA\` (\`gh pr view --repo $REPO $PR\`)")
if [ "$KNIGHTWATCH_PRESENT" = "0" ]; then
    REVIEW_NOTES+=("⚙️ No .knightwatch/ config (review using defaults)")
fi

AGG_BODY=$(cat "$RUN_DIR/agents/aggregator/output.md")
STITCHED=$(prepend_review_header "$AGG_BODY" "${REVIEW_NOTES[@]}")
printf '%s\n' "$STITCHED" > "$OUT/aggregator-output.md"
cp -r "$RUN_DIR/agents" "$OUT/agents"
echo "replay complete: $OUT"
