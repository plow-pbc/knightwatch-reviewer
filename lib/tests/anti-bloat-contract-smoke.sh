#!/usr/bin/env bash
# Smoke: anti-bloat prompt-contract sync.
#
# Token-level sync check between prompts/common-header.md, prompts/critic.md,
# and prompts/aggregator.md — ensures the REMEDY-BLOAT handshake stays
# intact across edits to either side, and Rule 8 (Remedy-cost framing)
# survives in common-header.md.
#
# Deliberately NOT a content-pinning test. Rule 8 itself forbids tests
# that calcify prompt prose; what we fence here is contract integrity
# (token presence, branch-negative alternative still allowed), not literal
# wording.
#
# Failure modes this catches:
#   - REMEDY-BLOAT removed from critic.md but not aggregator.md (or vice versa)
#   - Rule 8 deleted entirely from common-header.md
#   - aggregator handler narrowed back to LOC-only (loses the branch-negative
#     framing aligned with Rule 8's cost model — conditionals + special cases
#     + defensive branches + new abstractions)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

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
# Token-level fence that the performance + consumers specialists are
# wired into the critic and aggregator read lists, and that
# common-header documents the dead-code.md scratch the consumers
# specialist consumes. Catches the "added a prompt file but forgot
# to register it" omission class.

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

# Path 2 trigger semantics — fence the actual SHAPE of the trigger, not
# just the token presence. Round-5 finding: an earlier smoke only checked
# "loc-trend.md" appears, which is satisfied even if the file is mentioned
# without naming the threshold (≥1.5×) or the prior-rounds-only condition
# (the gotcha is real — momentum runs before the critic, so "this round's"
# Bug-Class-Recurrence isn't visible to it yet). Token-level fences below;
# Rule 8 still bars pinning prose.
echo "  asserting Path 2 trigger phrases in aggregator.md..."
assert_grep "aggregator.md should fence the 1.5× LOC threshold" \
    "1.5×" prompts/aggregator.md
assert_grep "aggregator.md should fence the 2+ prior rounds threshold" \
    "2+ prior rounds" prompts/aggregator.md
assert_grep "aggregator.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/aggregator.md

# Negative fence: the positive "any prior round" assertion above is
# satisfied by the bad regression string "this round or any prior round"
# too (it contains "any prior round" as a substring). Reject the literal
# bad string so a regression to the Round-5 wording trips this smoke.
echo "  asserting aggregator.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/aggregator.md; then
    echo "FAIL: aggregator.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

# Pre-PMF lens (critic.md) — same prior-rounds-only fence; catches a
# regression of the Round-5 spec/critic drift where critic.md said "this
# round or any prior round" (unreachable, since the critic and Bug-Class-
# Recurrence labelling happen in the same step).
echo "  asserting Pre-PMF lens trigger phrases in critic.md..."
assert_grep "critic.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/critic.md

# Negative fence (matches the aggregator.md fence above) — same
# false-positive risk: the positive assertion is satisfied by the bad
# regression string. Reject the literal bad string here too.
echo "  asserting critic.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/critic.md; then
    echo "FAIL: critic.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

# ----- carry-forward stress-test contract (PR#45) -----------------------
# Fences the new contract that closes the carry-forward-bypasses-critic
# loop: critic.md must run a stress-test on prior [blocking]/[medium]
# findings and emit a "Carried-forward findings" section; aggregator.md
# must apply those verdicts in re-review handling. The K-decay thresholds
# and the severe-bug carve-out are what stop the loop from collapsing into
# either a stuck record (no decay) or a severe-bug gate (decay too aggressive).
echo "  asserting carry-forward stress-test pass in critic.md..."
assert_grep "critic.md should fence Carry-forward stress-test pass" \
    "Carry-forward stress-test" prompts/critic.md
assert_grep "critic.md should fence the Carried-forward output section" \
    "Carried-forward findings" prompts/critic.md
assert_grep "critic.md should fence engagement-K signal" \
    "Engagement signal" prompts/critic.md

echo "  asserting K-decay thresholds in critic.md..."
# Unique paired tokens — bare "K ≥ 3" / "K ≥ 5" also appear in the
# carve-out clause, so a regression that deletes only the decay bullets
# would still satisfy bare-threshold assertions. Pair the threshold with
# the verdict it triggers, which only appears in the decay bullets.
assert_grep "critic.md should fence K >= 3 -> REFRAME-AS-QUESTION decay rule" \
    "K ≥ 3 with no engagement: REFRAME-AS-QUESTION" prompts/critic.md
assert_grep "critic.md should fence K >= 5 -> REMEDY-BLOAT decay rule" \
    "K ≥ 5 with no engagement: REMEDY-BLOAT" prompts/critic.md

echo "  asserting severe-bug carve-out for K-decay in critic.md..."
assert_grep "critic.md should carve severe-bug findings out of K-decay" \
    "Severe-bug carve-out for K-decay" prompts/critic.md
assert_grep "critic.md should key carve-out on failing-path text not specialist tag" \
    "Key on the cited failing-path text" prompts/critic.md
# Non-security severe-bug token — guards against a regression that
# narrows the carve-out back to security-only by dropping data-loss
# class words from the prompt prose.
assert_grep "critic.md severe-bug carve-out should cover data-loss class" \
    "data loss" prompts/critic.md

echo "  asserting aggregator applies critic carry-forward verdicts..."
# Same uniqueness concern — generic "Carried-forward findings" appears
# both in the section heading and in cross-references. The aggregator's
# carry-forward verdict mapping is the load-bearing rule, so fence its
# unique phrasing rather than a substring that can survive elsewhere.
assert_grep "aggregator.md should reference critic's Carried-forward findings section" \
    "Carried-forward findings" prompts/aggregator.md
assert_grep "aggregator.md should defer carry-forward verdicts to the step-1 table" \
    "same step-1 verdict table below" prompts/aggregator.md
assert_grep "aggregator.md should fence the K >= 3 fallback to REFRAME-AS-QUESTION on unchanged code" \
    "K ≥ 3 rounds without engagement" prompts/aggregator.md

echo "  PASS"
