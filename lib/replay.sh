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
. "$LIB_DIR/gh-retry.sh"   # gh_retry — replay spends the same PAT as the fleet
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/scratch.sh"
. "$LIB_DIR/knightwatch-config.sh"
. "$LIB_DIR/conventions.sh"
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

# ONE metadata snapshot for the whole replay. Reading the same PR through
# several `gh pr view` calls let a title edit between them make the prompt
# header disagree with author-intent.md — i.e. benchmark one intent while
# labelling it another — and a fetch nested in a command substitution had
# its failure masked by the enclosing builder's exit status. Bare assignment
# so a failed fetch aborts under `set -e`.
REPLAY_PR_META="$(gh pr view "$PR" --repo "$REPO" --json "baseRefName,author,$AUTHOR_INTENT_FIELDS")"
BASE_REF="$(printf '%s' "$REPLAY_PR_META" | jq -r '.baseRefName // empty')"
PR_AUTHOR="$(printf '%s' "$REPLAY_PR_META" | jq -r '.author.login // empty')"
# Fail loud on a metadata blank, mirroring production's guard: an empty
# BASE_REF otherwise surfaces as an obscure `git fetch origin ""`.
[ -n "$BASE_REF" ] && [ -n "$PR_AUTHOR" ] || {
    echo "replay: gh pr view $PR returned no baseRefName / author — aborting" >&2
    exit 1
}
( cd "$WORK/repo" && git fetch origin "$BASE_REF" )
git -C "$WORK/repo" diff "origin/$BASE_REF...$SHA" > "$OUT/diff.patch"

REPO_DIR="$WORK/repo"
RUN_DIR="$WORK/run"
mkdir -p "$RUN_DIR/agents"
# Redirect-safe staging: a PR checkout could commit .codex-scratch as a
# symlink to a writable path; mkdir -p would follow it and subsequent
# writes would escape the checkout. Wipe-and-recreate matches production
# (grep "Redirect-safe staging" in lib/review-one-pr.sh).
rm -rf "$REPO_DIR/.codex-scratch"
mkdir -p "$REPO_DIR/.codex-scratch"

# Stage scratch via the same write_scratch primitive production uses
# (lib/scratch.sh) so paths and file shape match. Prompts cite paths
# like .codex-scratch/standards.md; using the same writer is the only
# way prompt A/B replays produce production-comparable output.
#
# Replay can't reproduce inputs that depend on running upstream pipeline
# stages (KID prior-art, pr-comments from state, sibling-repo
# context). Stage those with explicit "(replay: not staged …)" markers
# so downstream prompts can fail-soft and the operator sees the gap.
write_scratch "$REPO_DIR" "diff.patch" "$(cat "$OUT/diff.patch")"
for f in pr-comments.md loc-trend.md \
         prior-art.md dead-code-static.md \
         file-history.md commits.md search-roots.md \
         test-results.md; do
    write_scratch "$REPO_DIR" "$f" "(replay: not staged — upstream pipeline stage skipped)"
done
# author-intent.md is NOT an upstream-pipeline artifact — it is public PR
# metadata replay can fetch itself, and intent.md now requires it. Staging the
# sentinel here would silently strip the author's rationale from every replay,
# making replayed intent diverge from production for the one input the intent
# pre-pass anchors on.
# Built by the SAME helper production uses (lib/scratch.sh): a replay whose
# author-intent.md differs in layout, reference shape, or cap would silently
# invalidate the prompt A/B comparison this harness exists for.
write_scratch "$REPO_DIR" "author-intent.md" "$(build_author_intent "$REPLAY_PR_META")"
# Memory surfaces stage EMPTY, not sentinel prose: a non-empty
# previous-review.md flips pipeline.py's has_prev and the aggregator's
# carry-forward into re-review mode over placeholder text. Empty is the
# real first-review signal (matches review-task.md's stated contract).
write_scratch "$REPO_DIR" "previous-review.md" ""
write_scratch "$REPO_DIR" "prior-reviews.md" ""
# Replay diffs are always the full PR diff — stage an accurate scope
# statement, not the generic sentinel (review-task.md is authoritative
# for diff scope in common-header/aggregator).
write_scratch "$REPO_DIR" "review-task.md" \
    "Replay review. .codex-scratch/diff.patch contains the FULL PR diff. Prior-round memory surfaces may be absent — treat missing files as first-review context."
# reeval-status.md is a load-bearing prompt input (common-header / aggregator /
# momentum read it), so stage a well-shaped default rather than the generic
# sentinel — otherwise a prompt/lib canary passes without the surface this
# input gates. Default = quiescent: no trigger live, nothing fired yet.
write_scratch "$REPO_DIR" "reeval-status.md" "$(cat <<'REEVAL_EOF'
# Re-eval trigger status

(replay: synthesized default — no live trajectory in a single-SHA replay.)

## This round
REEVAL-LOC-TRIGGER: not-fired (replay default)
REEVAL-SIZE-TRIGGER: not-applicable (replay default)

## Already fired in a prior round (durable — do NOT re-fire these)
REEVAL-LOC-FIRED: no
REEVAL-STALL-FIRED: no
REEVAL_EOF
)"

# review.md mirrors production staging via the SAME shared seam
# (resolve_review_md, lib/knightwatch-config.sh): the repo's REVIEW.md from the
# base ref if committed, else the org default. Using the one resolver — not a
# replay-local copy of the present/absent/error tri-state — is what keeps
# replay from drifting from production (it did, twice). architecture-refined
# and the other specialists rely on this input always carrying the operating
# point. rc=2 (bad base ref / git error) aborts rather than silently scoring
# as "absent context".
REVIEW_MD=$(resolve_review_md "$REPO_DIR" "origin/$BASE_REF") && REVIEW_MD_RC=0 || REVIEW_MD_RC=$?
[ "$REVIEW_MD_RC" = 2 ] \
    && { echo "replay: error reading REVIEW.md from origin/$BASE_REF — aborting" >&2; exit 1; }
write_scratch "$REPO_DIR" "review.md" "$REVIEW_MD"


# Convention detection + staging mirrors production (review-one-pr.sh) via the
# SAME shared resolver (resolve_binding/stage_convention, lib/conventions.sh) — no
# open-coded copy, so replay can't drift from the live worker. Read from the
# trusted base ref (origin/$BASE_REF), never the replayed PR-head SHA. On a match,
# stage convention.md so the specialists review by that convention's grammar, and
# (when the convention declares a test-note) replace the generic test-results.md
# stub with it so the replay reproduces what production shows the tests specialist.
# stage_convention_run (lib/conventions.sh) is errexit-safe: replay runs under
# `set -euo pipefail`, where a bare `$(resolve_binding ...)` would abort on the
# COMMON rc-1 (no-convention) path. The `if` suppresses errexit for the condition;
# the inner test-note write is an explicit `if`, not `[ -n ] && cmd` (whose false
# branch returns 1 and would trip errexit). Covered by replay-staging-smoke.
if _conv_note=$(stage_convention_run "$REPO_DIR" "$REPO" "origin/$BASE_REF"); then
    if [ -n "$_conv_note" ]; then
        write_scratch "$REPO_DIR" "test-results.md" "**Result:** $_conv_note"
    fi
else
    _conv_rc=$?
    if [ "$_conv_rc" = 2 ]; then
        echo "replay: kwr-config binding matched $REPO but its doc is missing/unsafe — incomplete config — aborting" >&2
        exit 1
    fi
    # rc 1: no convention applies — review as a general repo
fi
# TODO: prior-reviews.md is stubbed above, so multi-round Path 2 (strict-decrease
# trigger in aggregator.md) cannot be exercised via replay. Re-staging from the
# source run dir's inputs/ would enable it. The deterministic smoke
# (lib/tests/prompt-contracts-smoke.sh, Section 4) is the contract test for Path 2.
# standards.md — use the SAME resolver production does (resolve_standards,
# lib/conventions.sh): the operator's kwr-config standards/ when an external
# config is active, else the full ~/.claude bundle. Sharing it keeps a replay's
# specialists grounded by the same standards bytes production used (the prior
# CODING_STANDARDS.md-only staging diverged from production's whole bundle).
# Keep a replay sentinel only if the resolver emits nothing (e.g. a CI box with
# neither source).
STANDARDS_CONTENT="$(resolve_standards)"
[ -n "$STANDARDS_CONTENT" ] || STANDARDS_CONTENT="(replay: not staged — set ~/.claude/*.md or wire kwr-config to ground specialists)"
write_scratch "$REPO_DIR" "standards.md" "$STANDARDS_CONTENT"

# probe-schema.md is the canonical Class-options + render contract; specialists
# + critic + aggregator all reference .codex-scratch/probe-schema.md by name.
# Stage from prompts/ so replay sees the same shape production does.
PROBE_SCHEMA_SRC="${PROMPTS_DIR:-$LIB_DIR/../prompts}/probe-schema.md"
if [ -f "$PROBE_SCHEMA_SRC" ]; then
    write_scratch "$REPO_DIR" "probe-schema.md" "$(cat "$PROBE_SCHEMA_SRC")"
fi

PR_ID="$REPO#$PR"
PR_TITLE="$(printf '%s' "$REPLAY_PR_META" | jq -r '.title // empty' | tr '\000-\037\177' ' ')"
PR_URL="https://github.com/$REPO/pull/$PR"
# Mirror the live worker's visibility lookup so replays render the same
# security/portability posture production does — without it, every replay
# falls back to pipeline.py's `private` default and a public-repo canary
# never exercises the public prompt path this PR adds.
REPO_VISIBILITY="$(gh repo view "$REPO" --json visibility --jq .visibility | tr '[:upper:]' '[:lower:]')"
[ -n "$REPO_VISIBILITY" ] || { echo "replay: gh repo view $REPO returned no visibility" >&2; exit 1; }
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
REPO_VISIBILITY="$REPO_VISIBILITY" \
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

REVIEW_NOTES=()
REVIEW_NOTES+=("🎬 Replay of \`$SHA\` (\`gh pr view --repo $REPO $PR\`)")
# rc=1 from resolve_review_md above means the org default was substituted.
if [ "$REVIEW_MD_RC" = 1 ]; then
    REVIEW_NOTES+=("⚙️ No REVIEW.md (review using org defaults)")
fi
# Same partial-review disclosure as the live worker (shared helper), so a
# replayed run whose specialists timed out doesn't read as full coverage.
TIMEOUT_NOTE=$(timeout_note_for_run "$RUN_DIR")
[ -n "$TIMEOUT_NOTE" ] && REVIEW_NOTES+=("$TIMEOUT_NOTE")

AGG_BODY=$(cat "$AGG_OUT_FILE")
STITCHED=$(prepend_review_header "$AGG_BODY" "${REVIEW_NOTES[@]}")
printf '%s\n' "$STITCHED" > "$OUT/aggregator-output.md"
cp -r "$RUN_DIR/agents" "$OUT/agents"
echo "replay complete: $OUT"
