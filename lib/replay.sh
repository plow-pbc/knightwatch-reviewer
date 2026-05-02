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

# Fetch diff at the historical SHA
gh pr diff "$PR" --repo "$REPO" --patch > "$OUT/diff.patch"

# Manifest captures replay provenance — deterministic spot-check input
cat > "$OUT/manifest.json" <<EOF
{
    "repo": "$REPO",
    "pr": $PR,
    "sha": "$SHA",
    "replayed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "dry_run": $([ "$DRY_RUN" -eq 1 ] && echo true || echo false)
}
EOF

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: scratch prepared at $OUT"
    exit 0
fi

# Real replay: stage the same .codex-scratch inputs run_specialist_pipeline reads,
# then invoke run_specialist_pipeline against a fresh checkout at $SHA. The post-
# pipeline gh-posting step is deliberately skipped — we only want the rendered review.
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$LIB_DIR/orchestrate.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/agent-fallback.sh"
. "$LIB_DIR/llm-pipeline.sh"
. "$LIB_DIR/critic-splitter.sh"
. "$LIB_DIR/go-deep-rank.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --depth 50 "https://github.com/$REPO.git" "$WORK/repo"
( cd "$WORK/repo" && git fetch origin "pull/$PR/head" && git checkout "$SHA" )

REPO_DIR="$WORK/repo"
RUN_DIR="$WORK/run"
mkdir -p "$RUN_DIR/agents" "$REPO_DIR/.codex-scratch"
cp "$OUT/diff.patch" "$REPO_DIR/.codex-scratch/diff.patch"

PR_ID="$REPO#$PR"
PR_TITLE="$(gh pr view "$PR" --repo "$REPO" --json title --jq .title)"
PR_URL="https://github.com/$REPO/pull/$PR"
PR_AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login)"
_LIB_DIR="$LIB_DIR"
LOG_FILE="$OUT/run.log"

run_specialist_pipeline

cp "$RUN_DIR/agents/aggregator/output.md" "$OUT/aggregator-output.md"
cp -r "$RUN_DIR/agents" "$OUT/agents"
echo "replay complete: $OUT"
