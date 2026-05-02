#!/usr/bin/env bash
# Smoke: cross-file prompt + orchestrator-wire contract sync.
#
# Cheap (millisec) token-presence checks against tracked files.
# Catches "renamed token on one side, forgot the other" omission class.
# Behavior-side tests (does the pipeline actually USE these tokens
# correctly?) belong to the replay harness; this stays as the cheap
# pre-flight tier.
#
# Folded from anti-bloat-contract-smoke.sh + momentum-wire-smoke.sh —
# both used the same assert_grep shape against tracked files, no
# behavior loss in the merge. 2 justfile entries → 1.
#
# This file's ASSERTIONS ARE THE CONTRACT — when you remove an
# assertion, you remove a token fence. Don't drop assertions to
# "clean up"; the K-decay paired tokens, the negative fences, and the
# specialist-registration tokens are all load-bearing and were each
# written in response to a specific regression. See PR #25, PR #38,
# PR #42, PR #45 review history if uncertain about a specific fence.
#
# Deliberately NOT a content-pinning test. Rule 8 (Remedy-cost framing)
# itself forbids tests that calcify prompt prose; what we fence here is
# contract integrity (token presence, branch-negative alternative still
# allowed), not literal wording.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

# ====================================================================
# Section 1: prompt-contract sync (formerly anti-bloat-contract-smoke.sh)
# ====================================================================

echo "  asserting Rule 8 (Remedy-cost framing) in common-header.md..."
assert_grep "Rule 8 missing from prompts/common-header.md" \
    "Remedy-cost framing" prompts/common-header.md

echo "  asserting voice-posture pointer in common-header.md..."
assert_grep "common-header.md should reference Broken-Glass Test" \
    "Broken-Glass Test" prompts/common-header.md
assert_grep "common-header.md should mandate cost-naming" \
    "adds complexity and makes PMF iteration harder" prompts/common-header.md
assert_grep "common-header.md should reference review-priority.md scratch input" \
    "review-priority.md" prompts/common-header.md

echo "  asserting REMEDY-BLOAT bucket in critic.md..."
assert_grep "REMEDY-BLOAT bucket missing from prompts/critic.md" \
    "REMEDY-BLOAT" prompts/critic.md

echo "  asserting REFRAME-AS-QUESTION bucket in critic.md..."
assert_grep "REFRAME-AS-QUESTION bucket missing from prompts/critic.md" \
    "REFRAME-AS-QUESTION" prompts/critic.md

echo "  asserting voice-posture pointer in critic.md..."
assert_grep "critic.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/critic.md

echo "  asserting Pre-PMF lens reference in critic.md..."
assert_grep "critic.md should reference loc-trend.md (Pre-PMF lens)" \
    "loc-trend.md" prompts/critic.md

# ----- Phase 1: decline-history awareness + remedy-LOC + calibration ----
echo "  asserting decline-history input in critic.md..."
assert_grep "critic.md should reference decline-history.md" \
    "decline-history.md" prompts/critic.md

echo "  asserting remedy-LOC estimate contract in critic.md..."
assert_grep "critic.md should fence Estimated remedy LOC token" \
    "Estimated remedy LOC" prompts/critic.md

echo "  asserting calibration-question contract in critic.md..."
assert_grep "critic.md should fence Calibration questions for go-deep token" \
    "Calibration questions for go-deep" prompts/critic.md

# ----- Phase 2: go-deep tech-lead specialist + aggregator integration ----
echo "  asserting decline-history input in aggregator.md..."
assert_grep "aggregator.md should reference decline-history.md" \
    "decline-history.md" prompts/aggregator.md

echo "  asserting layered-file note in aggregator.md..."
assert_grep "aggregator.md should describe layered specialist files" \
    "layered specialist files" prompts/aggregator.md

echo "  asserting go-deep recommendation handlers in aggregator.md..."
assert_grep "aggregator.md should reference SIMPLIFY-WITH-PATTERN go-deep recommendation" \
    "SIMPLIFY-WITH-PATTERN" prompts/aggregator.md

echo "  asserting go-deep prompt exists with 20-LOC threshold reference..."
assert_grep "go-deep.md should fence the 20-LOC remedy threshold reference" \
    "20-LOC remedy threshold" prompts/go-deep.md
assert_grep "go-deep.md should fence the four recommendation tokens" \
    "KEEP | SIMPLIFY-WITH-PATTERN | DROP | REFRAME" prompts/go-deep.md

echo "  asserting REMEDY-BLOAT handler in aggregator.md..."
assert_grep "REMEDY-BLOAT handler missing from prompts/aggregator.md" \
    "REMEDY-BLOAT" prompts/aggregator.md

echo "  asserting aggregator handler accepts branch-negative alternatives..."
assert_grep "aggregator.md should mention branch-negative alternative" \
    "branch-negative" prompts/aggregator.md

# ----- new specialist + scratch wiring (PR#25) ----------------------
echo "  asserting performance specialist registered in critic.md..."
assert_grep "critic.md should reference performance specialist" \
    "specialists/performance.md" prompts/critic.md

echo "  asserting consumers specialist registered in critic.md..."
assert_grep "critic.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/critic.md

echo "  asserting performance specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference performance specialist" \
    "specialists/performance.md" prompts/aggregator.md

echo "  asserting consumers specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/aggregator.md

echo "  asserting common-header documents dead-code.md scratch..."
assert_grep "common-header.md should document dead-code.md" \
    "dead-code.md" prompts/common-header.md

echo "  asserting voice-posture pointer in aggregator.md..."
assert_grep "aggregator.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/aggregator.md
echo "  asserting Open Questions Q: format in aggregator.md..."
assert_grep "aggregator.md should describe Q: question template" \
    "**Q:" prompts/aggregator.md
echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference loc-trend.md trigger" \
    "loc-trend.md" prompts/aggregator.md
assert_grep "aggregator.md should reference momentum specialist output" \
    "momentum.md" prompts/aggregator.md

echo "  asserting Path 2 trigger phrases in aggregator.md..."
assert_grep "aggregator.md should fence the 1.5× LOC threshold" \
    "1.5×" prompts/aggregator.md
assert_grep "aggregator.md should fence the 2+ prior rounds threshold" \
    "2+ prior rounds" prompts/aggregator.md
assert_grep "aggregator.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/aggregator.md

echo "  asserting aggregator.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/aggregator.md; then
    echo "FAIL: aggregator.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

echo "  asserting Pre-PMF lens trigger phrases in critic.md..."
assert_grep "critic.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/critic.md

echo "  asserting critic.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/critic.md; then
    echo "FAIL: critic.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

# ----- carry-forward stress-test contract (PR#45) -----------------------
echo "  asserting carry-forward stress-test pass in critic.md..."
assert_grep "critic.md should fence Carry-forward stress-test pass" \
    "Carry-forward stress-test" prompts/critic.md
assert_grep "critic.md should fence the Carried-forward output section" \
    "Carried-forward findings" prompts/critic.md
assert_grep "critic.md should fence engagement-K signal" \
    "Engagement signal" prompts/critic.md

echo "  asserting K-decay thresholds in critic.md..."
assert_grep "critic.md should fence K >= 3 -> REFRAME-AS-QUESTION decay rule" \
    "K ≥ 3 with no engagement: REFRAME-AS-QUESTION" prompts/critic.md
assert_grep "critic.md should fence K >= 5 -> REMEDY-BLOAT decay rule" \
    "K ≥ 5 with no engagement: REMEDY-BLOAT" prompts/critic.md

echo "  asserting severe-bug carve-out for K-decay in critic.md..."
assert_grep "critic.md should carve severe-bug findings out of K-decay" \
    "Severe-bug carve-out for K-decay" prompts/critic.md
assert_grep "critic.md should key carve-out on failing-path text not specialist tag" \
    "Key on the cited failing-path text" prompts/critic.md
assert_grep "critic.md severe-bug carve-out should cover data-loss class" \
    "data loss" prompts/critic.md

echo "  asserting aggregator applies critic carry-forward verdicts..."
assert_grep "aggregator.md should reference critic's Carried-forward findings section" \
    "Carried-forward findings" prompts/aggregator.md
assert_grep "aggregator.md should defer carry-forward verdicts to the step-1 table" \
    "same step-1 verdict table below" prompts/aggregator.md
assert_grep "aggregator.md should fence the K >= 3 fallback to REFRAME-AS-QUESTION on unchanged code" \
    "K ≥ 3 rounds without engagement" prompts/aggregator.md

# ====================================================================
# Section 2: orchestrator wiring (formerly momentum-wire-smoke.sh)
# ====================================================================

ORCHESTRATE=lib/orchestrate.sh

echo "  asserting momentum.md invocation in orchestrate.sh..."
assert_grep "orchestrate.sh missing momentum.md reference" \
    "momentum.md" "$ORCHESTRATE"

echo "  asserting momentum gate on previous-review.md..."
# Fence the EXACT guard pattern, not the bare substring "previous-review.md"
# (which appears in unrelated write_scratch calls + comments and would PASS
# even if the re-review-only gate around the momentum specialist disappeared).
assert_grep "orchestrate.sh missing momentum gate (\$RUN_DIR/inputs/previous-review.md)" \
    'if [ -s "$RUN_DIR/inputs/previous-review.md" ]' "$ORCHESTRATE"

echo "  asserting momentum is dispatched..."
assert_grep "orchestrate.sh missing dispatch_agent momentum call" \
    'dispatch_agent momentum' "$ORCHESTRATE"

echo "  asserting momentum output symlink to .codex-scratch/momentum.md..."
assert_grep "orchestrate.sh missing symlink from RUN_DIR/agents/momentum/output.md to .codex-scratch/momentum.md" \
    ".codex-scratch/momentum.md" "$ORCHESTRATE"

echo "  asserting orchestrate.sh is sourced from review-one-pr.sh..."
assert_grep "review-one-pr.sh does not source lib/orchestrate.sh" \
    'orchestrate.sh' lib/review-one-pr.sh

echo "  PASS"
