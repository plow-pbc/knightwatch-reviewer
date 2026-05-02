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

echo "  asserting probe-resolver job description in critic.md..."
assert_grep "critic.md should describe probe resolution job" \
    "probe resolution" prompts/critic.md

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

# Legacy critic-verdict-token fences (REMEDY-BLOAT in aggregator,
# branch-negative alternative phrasing) were removed once the aggregator's
# probe-resolver path replaced the verdict-token mapping. The critic still
# emits REMEDY-BLOAT on the critic side (legacy bucket retained for
# back-compat); aggregator no longer consumes it as a token — the
# probe Answer: no/Severity-if-yes path subsumes it.

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

echo "  asserting Open Questions Q: format in aggregator.md..."
assert_grep "aggregator.md should describe Q: question template" \
    "**Q:" prompts/aggregator.md
echo "  asserting [from: <specialist>] attribution token in aggregator.md..."
assert_grep "aggregator.md should describe per-line specialist attribution" \
    "[from: <specialist>]" prompts/aggregator.md
echo "  asserting unified Probes section in aggregator.md..."
assert_grep "aggregator.md should have **Probes** unified section" \
    "**Probes**" prompts/aggregator.md
echo "  asserting AI-author callout in aggregator.md..."
assert_grep "aggregator.md should have **For AI authors** callout" \
    "**For AI authors**" prompts/aggregator.md
echo "  asserting unified-probes section ordering instructions..."
assert_grep "aggregator.md should fence Answer: yes ordering" \
    "Answer: yes" prompts/aggregator.md
for specialist in shape simplification architecture consumers tests performance security data-integrity; do
    echo "  asserting complexity-cost probe class in ${specialist}.md..."
    assert_grep "${specialist}.md should list complexity-cost as a probe class" \
        "Class: complexity-cost" "prompts/${specialist}.md"
done

echo "  asserting unified complexity-cost expectation in common-header.md..."
assert_grep "common-header.md should describe complexity-cost probe expectation" \
    "Complexity-cost probe expectation" prompts/common-header.md

echo "  asserting legacy finding-format carry-forward bucket in critic.md..."
assert_grep "critic.md should describe Legacy finding-format conversion path" \
    "Legacy finding-format" prompts/critic.md
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

# Pre-PMF lens (critic.md) — the probe-resolver model uses an always-on
# Pre-PMF lens; the old "any prior round" trigger phrase no longer applies.
# Fence the new pre-pmf lens token instead.
echo "  asserting Pre-PMF lens (always-on) in critic.md..."
assert_grep "critic.md should fence Pre-PMF lens (always-on)" \
    "Pre-PMF lens (always-on)" prompts/critic.md

# ----- carry-forward stress-test contract (PR#45, updated PR#48) ----------
# Probe-resolver model: carry-forward is now a probe-resolution pass (not a
# finding-level stress-test). Fence the new probe-model tokens.
echo "  asserting carry-forward stress-test pass in critic.md..."
assert_grep "critic.md should fence Carry-forward stress-test pass" \
    "Carry-forward stress-test" prompts/critic.md

echo "  asserting K-decay thresholds in critic.md..."
# The probe-resolver model uses "K ≥ 3 with no engagement and Class ≠ bug"
# and "K ≥ 5 with no engagement and Class ≠ bug" — pair threshold with Class guard.
assert_grep "critic.md should fence K >= 3 decay rule with Class guard" \
    "K ≥ 3 with no engagement" prompts/critic.md
assert_grep "critic.md should fence K >= 5 decay rule with Class guard" \
    "K ≥ 5 with no engagement" prompts/critic.md

echo "  asserting severe-bug carve-out in critic.md..."
assert_grep "critic.md should carve severe-bug probes out of decay/Pre-PMF" \
    "Severe-bug carve-out" prompts/critic.md
# Non-security severe-bug token — guards against a regression that
# narrows the carve-out back to security-only by dropping data-loss
# class words from the prompt prose.
assert_grep "critic.md severe-bug carve-out should cover data-loss class" \
    "data loss" prompts/critic.md

echo "  asserting aggregator reads carry-forward via specialists/critic.md sink..."
# Probe-era carry-forward routes prior probes through the same
# specialists/critic.md sink as critic-generated probes (single channel,
# single render path). Fence both the routing claim and the union-verdict
# rule so a regression that splits the sink trips here.
assert_grep "aggregator.md should reference specialists/critic.md as the carry-forward sink" \
    "specialists/critic.md" prompts/aggregator.md
assert_grep "aggregator.md should fence the union-of-current-and-carried-forward verdict rule" \
    "union of current and carried-forward" prompts/aggregator.md

echo "  PASS"
