#!/usr/bin/env bash
# Replay a PR review at a historical SHA. Writes outputs to <output-dir>.
#
# Usage:
#   ./lib/replay.sh --repo OWNER/REPO --pr N --sha SHA \
#                   [--prompts DIR] [--output-dir PATH]
#
# Trust boundary — read before running:
#   This tool runs OUTSIDE the production systemd lockbox. It clones the
#   target repo as the operator user and invokes codex against arbitrary
#   PR-controlled content with --dangerously-bypass-approvals-and-sandbox.
#   The replay process therefore inherits the operator shell's filesystem
#   reach (incl. any readable credentials in $HOME).
#
#   Treat replay as a CONSCIOUS-INVESTIGATION tool: only run it against PRs
#   you would otherwise be willing to inspect locally. The production
#   pr-reviewer.service (systemd, ProtectHome=read-only, narrow
#   ReadWritePaths) is the autonomous-review surface; replay is for the
#   operator's bench, not the auto-pipe.

set -euo pipefail

REPO=""; PR=""; SHA=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --sha) SHA="$2"; shift 2 ;;
        --output-dir) OUT="$2"; shift 2 ;;
        --prompts)
            # Pass through as the PROMPTS_DIR env var consumed by
            # lib/prompt-build.sh + lib/orchestrate.sh::dispatch_agent.
            # Lets the operator A/B-test prompt variants against the same
            # historical PR by pointing replay at an alternate prompts/.
            export PROMPTS_DIR="$2"
            shift 2
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || {
    echo "usage: $0 --repo OWNER/REPO --pr N --sha SHA [--prompts DIR] [--output-dir PATH]" >&2
    exit 2
}
# Default OUT includes a prompt-set slug so back-to-back A/B runs against
# the same repo/PR/SHA don't clobber each other's manifest.json /
# aggregator-output.md / agents/. Operator-supplied --output-dir is
# respected verbatim.
PROMPT_SLUG="$(basename "${PROMPTS_DIR:-default}" | tr -c 'A-Za-z0-9' '_')"
OUT="${OUT:-replays/${REPO//\//-}-${PR}-${SHA:0:7}-${PROMPT_SLUG}}"
mkdir -p "$OUT"

# Manifest captures replay provenance — deterministic spot-check input.
# Includes the prompts dir actually used so prompt-bisect comparisons
# are auditable across runs.
jq -n \
  --arg repo "$REPO" \
  --argjson pr "$PR" \
  --arg sha "$SHA" \
  --arg prompts_dir "${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}" \
  '{repo: $repo, pr: $pr, sha: $sha, prompts_dir: $prompts_dir, replayed_at: (now | todate)}' \
  > "$OUT/manifest.json"

# Stage the same .codex-scratch inputs run_specialist_pipeline reads,
# then invoke run_specialist_pipeline against a fresh checkout at $SHA. The post-
# pipeline gh-posting step is deliberately skipped — we only want the rendered review.
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$LIB_DIR/state-io.sh"
. "$LIB_DIR/prompt-build.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/critic-splitter.sh"
. "$LIB_DIR/go-deep-rank.sh"
. "$LIB_DIR/orchestrate.sh"
. "$LIB_DIR/scratch.sh"

WORK="$(mktemp -d)"
# On exit, preserve per-agent log.txt files for post-mortem before
# wiping $WORK. `run_specialist_pipeline` calls `exit 1` directly on
# codex failure (auth, usage limit, network), which means replay.sh's
# control flow can't capture stderr from the failing agent inline.
# The trap captures log tails into $OUT/agents-on-exit/ regardless of
# how the script exited.
cleanup_replay() {
    local rc=$?
    if [ -d "$WORK/run/agents" ]; then
        mkdir -p "$OUT/agents-on-exit"
        for agent_dir in "$WORK"/run/agents/*/; do
            [ -d "$agent_dir" ] || continue
            local name
            name=$(basename "$agent_dir")
            mkdir -p "$OUT/agents-on-exit/$name"
            for f in log.txt prompt.txt output.md; do
                [ -f "$agent_dir/$f" ] && cp "$agent_dir/$f" "$OUT/agents-on-exit/$name/$f"
            done
        done
    fi
    rm -rf "$WORK"
    return $rc
}
trap cleanup_replay EXIT
git clone "https://github.com/$REPO.git" "$WORK/repo"
( cd "$WORK/repo" && git fetch origin "pull/$PR/head" && git checkout "$SHA" )

# Build diff at the historical SHA using local git diff, not gh pr diff
BASE_REF="$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq .baseRefName)"
( cd "$WORK/repo" && git fetch origin "$BASE_REF" )
git -C "$WORK/repo" diff "origin/$BASE_REF...$SHA" > "$OUT/diff.patch"

REPO_DIR="$WORK/repo"
RUN_DIR="$WORK/run"
mkdir -p "$RUN_DIR/agents"
# Redirect-safe staging: a PR checkout could commit .codex-scratch as a
# symlink to a writable path; mkdir -p would follow it and subsequent
# writes would escape the checkout. Wipe-and-recreate matches production
# (lib/review-one-pr.sh:446-453).
rm -rf "$REPO_DIR/.codex-scratch"
mkdir -p "$REPO_DIR/.codex-scratch"

# Stage scratch via the same write_scratch primitive production uses
# (lib/scratch.sh) so paths and symlink shape match. Prompts cite paths
# like .codex-scratch/standards.md; using the same writer is the only
# way prompt A/B replays produce production-comparable output.
#
# Replay can't reproduce inputs that depend on running upstream pipeline
# stages (KID prior-art, decline-history from state, sibling-repo
# context). Stage those with explicit "(replay: not staged …)" markers
# so downstream prompts can fail-soft and the operator sees the gap.
write_scratch "$REPO_DIR" "diff.patch" "$(cat "$OUT/diff.patch")"
for f in review-priority.md decline-history.md loc-trend.md \
         prior-art.md dead-code-static.md prior-reviews.md previous-review.md \
         file-history.md commits.md author-intent.md search-roots.md \
         product-context.md test-results.md; do
    write_scratch "$REPO_DIR" "$f" "(replay: not staged — upstream pipeline stage skipped)"
done
# standards.md gets real content from this repo's prompts/ so the
# specialists have something to grade against.
STANDARDS_CONTENT=""
if [ -f "$LIB_DIR/../prompts/standards.md" ]; then
    STANDARDS_CONTENT="$(cat "$LIB_DIR/../prompts/standards.md")"
elif [ -f "$LIB_DIR/../prompts/probe-schema.md" ]; then
    STANDARDS_CONTENT="$(cat "$LIB_DIR/../prompts/probe-schema.md")"
fi
write_scratch "$REPO_DIR" "standards.md" "$STANDARDS_CONTENT"

PR_ID="$REPO#$PR"
PR_TITLE="$(gh pr view "$PR" --repo "$REPO" --json title --jq .title)"
PR_URL="https://github.com/$REPO/pull/$PR"
PR_AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login)"
_LIB_DIR="$LIB_DIR"
LOG_FILE="$OUT/run.log"

# `run_specialist_pipeline` calls `exit 1` from inside the function on
# codex failure (intent failure, specialist failure, etc.), which under
# replay.sh's `set -euo pipefail` would have aborted BEFORE the
# function's own "intent inference failed" log line ran — silent abort,
# operator saw only "inferring developer intent..." then nothing. Drop
# set -e for the pipeline call so the function's own diagnostics surface
# in $OUT/run.log; re-enable set -e after. Per-agent log.txt files are
# captured by the EXIT trap regardless of how the script exits.
set +e
run_specialist_pipeline
PIPELINE_RC=$?
set -e
if [ "$PIPELINE_RC" -ne 0 ]; then
    echo "replay: pipeline failed (rc=$PIPELINE_RC); see $OUT/run.log + $OUT/agents-on-exit/<agent>/log.txt for codex stderr" >&2
    exit "$PIPELINE_RC"
fi

# Aggregator output gates — same fail-loud contract production enforces in
# review-one-pr.sh's REVIEW_NOTES assembly block. An empty or VERDICT-less
# aggregator output is a malformed review; replay should crash, not record
# it as "complete".
AGG_OUT_FILE="$RUN_DIR/agents/aggregator/output.md"
if [ ! -s "$AGG_OUT_FILE" ]; then
    echo "replay: aggregator output empty at $AGG_OUT_FILE — pipeline produced no review" >&2
    exit 1
fi
if ! grep -q '^VERDICT:' "$AGG_OUT_FILE"; then
    echo "replay: aggregator output missing VERDICT: line — malformed review (see $AGG_OUT_FILE)" >&2
    exit 1
fi

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

AGG_BODY=$(cat "$AGG_OUT_FILE")
STITCHED=$(prepend_review_header "$AGG_BODY" "${REVIEW_NOTES[@]}")
printf '%s\n' "$STITCHED" > "$OUT/aggregator-output.md"
cp -r "$RUN_DIR/agents" "$OUT/agents"
echo "replay complete: $OUT"
