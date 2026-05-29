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

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$LIB_DIR/replay-paths.sh"

REPO=""; PR=""; SHA=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --pr) PR="$2"; shift 2 ;;
        --sha) SHA="$2"; shift 2 ;;
        --output-dir) OUT="$2"; shift 2 ;;
        --prompts)
            # Pass through as the PROMPTS_DIR env var consumed by
            # lib/pipeline.py (intent + specialists + critic + aggregator).
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
PROMPT_SLUG="$(replay_prompt_slug "${PROMPTS_DIR:-}")"
# Default replay artifacts to the operator-local replay tree (same boundary
# PULL_REQUEST_TEMPLATE.md uses for ~/.pr-reviewer/replays/). Operators who
# want repo-local artifacts (e.g. capturing a public-canary's last-known-good
# snapshot for review) opt in with --output-dir replays/...
OUT="${OUT:-$HOME/.pr-reviewer/replays/$(replay_run_dir "$REPO" "$PR" "$SHA" "$PROMPT_SLUG")}"
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

# Stage the same .codex-scratch inputs pipeline.py reads,
# then invoke pipeline.py against a fresh checkout at $SHA. The post-
# pipeline gh-posting step is deliberately skipped — we only want the rendered review.
. "$LIB_DIR/state-io.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/scratch.sh"
. "$LIB_DIR/knightwatch-config.sh"
# Pipeline shape (Wave A: intent ∥ dead-code-search → Wave B: the SPECIALISTS
# ∥ momentum-on-re-review → aggregator) is implemented in lib/pipeline.py.
# Replay invokes it as a subprocess below after staging scratch inputs.

WORK="$(mktemp -d)"
# On exit, preserve per-agent log.txt + err.txt files for post-mortem
# before wiping $WORK. `python3 lib/pipeline.py` exits non-zero on codex
# failure (auth, usage limit, network); err.txt carries Codex's CLI
# stderr (where those errors land), log.txt carries the model-reasoning
# stdout. The trap captures both into $OUT/agents-on-exit/ regardless
# of how the script exited.
cleanup_replay() {
    local rc=$?
    if [ -d "$WORK/run/agents" ]; then
        mkdir -p "$OUT/agents-on-exit"
        for agent_dir in "$WORK"/run/agents/*/; do
            [ -d "$agent_dir" ] || continue
            local name
            name=$(basename "$agent_dir")
            mkdir -p "$OUT/agents-on-exit/$name"
            for f in log.txt log.attempt1.txt err.txt err.attempt1.txt prompt.txt output.md; do
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
         test-results.md; do
    write_scratch "$REPO_DIR" "$f" "(replay: not staged — upstream pipeline stage skipped)"
done

# product-context.md mirrors production staging via the SAME shared seam
# (resolve_product_context, lib/knightwatch-config.sh): per-repo file from the
# base ref if committed, else the org default. Using the one resolver — not a
# replay-local copy of the present/absent/error tri-state — is what keeps
# replay from drifting from production (it did, twice). architecture-refined
# and the other specialists rely on this input always carrying the operating
# point. rc=2 (bad base ref / git error) aborts rather than silently scoring
# as "absent context".
PRODUCT_CONTEXT=$(resolve_product_context "$REPO_DIR" "origin/$BASE_REF") \
    || { echo "replay: error reading product-context.md from origin/$BASE_REF — aborting" >&2; exit 1; }
write_scratch "$REPO_DIR" "product-context.md" "$PRODUCT_CONTEXT"
# TODO: prior-reviews.md is stubbed above, so multi-round Path 2 (strict-decrease
# trigger in aggregator.md) cannot be exercised via replay. Re-staging from the
# source run dir's inputs/ would enable it. The deterministic smoke
# (lib/tests/prompt-contracts-smoke.sh, Section 4) is the contract test for Path 2.
# standards.md content lives in operator-private ~/.claude/CODING_STANDARDS.md
# in production (review-one-pr.sh:677). Replay can't rely on that — try the
# operator's home tree if available, otherwise mark as unstaged like the
# other deferred inputs above. The PROBE-SCHEMA fallback was incorrect
# (probe-schema is shape, not standards content).
STANDARDS_CONTENT="(replay: not staged — set ~/.claude/CODING_STANDARDS.md to ground specialists)"
if [ -f "$HOME/.claude/CODING_STANDARDS.md" ]; then
    STANDARDS_CONTENT="$(cat "$HOME/.claude/CODING_STANDARDS.md")"
fi
write_scratch "$REPO_DIR" "standards.md" "$STANDARDS_CONTENT"

# probe-schema.md is the canonical Class-options + render contract; specialists
# + critic + aggregator all reference .codex-scratch/probe-schema.md by name.
# Stage from prompts/ so replay sees the same shape production does.
PROBE_SCHEMA_SRC="${PROMPTS_DIR:-$LIB_DIR/../prompts}/probe-schema.md"
if [ -f "$PROBE_SCHEMA_SRC" ]; then
    write_scratch "$REPO_DIR" "probe-schema.md" "$(cat "$PROBE_SCHEMA_SRC")"
fi

PR_ID="$REPO#$PR"
PR_TITLE="$(gh pr view "$PR" --repo "$REPO" --json title --jq .title | tr '\000-\037\177' ' ')"
PR_URL="https://github.com/$REPO/pull/$PR"
PR_AUTHOR="$(gh pr view "$PR" --repo "$REPO" --json author --jq .author.login)"
LOG_FILE="$OUT/run.log"

# `python3 lib/pipeline.py` returns a non-zero exit on any-stage failure
# (intent fail, specialist fail, dead-code fail, critic fail, aggregator
# fail). Under replay.sh's `set -euo pipefail` a non-zero exit would
# abort the script before we could capture PIPELINE_RC; drop set -e for
# the call, then re-enable. Per-agent log.txt + err.txt files are
# captured by the EXIT trap regardless of how the script exits.
set +e
PR_ID="$PR_ID" \
PR_TITLE="$PR_TITLE" \
PR_URL="$PR_URL" \
PR_AUTHOR="$PR_AUTHOR" \
PROMPTS_DIR="${PROMPTS_DIR:-$LIB_DIR/../prompts}" \
LOG_FILE="$LOG_FILE" \
OPERATOR_NAME="${OPERATOR_NAME:-Sam}" \
    python3 "$LIB_DIR/pipeline.py" "$REPO_DIR" "$RUN_DIR"
PIPELINE_RC=$?
set -e
if [ "$PIPELINE_RC" -ne 0 ]; then
    echo "replay: pipeline failed (rc=$PIPELINE_RC); see $OUT/run.log + $OUT/agents-on-exit/<agent>/err.txt (codex CLI stderr — quota/auth/network errors land here) and log.txt (codex stdout — model reasoning)" >&2
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
