#!/usr/bin/env bash
# Smoke for the elegant-convergence prompt contract.
#
# Locks the prompt-shape invariants from the elegant-convergence
# refactor (Tasks 2-7 on feat/elegant-convergence).
#
# Contracts:
#   1. aggregator.md step 38 contains the cited-shape-at-HEAD rule.
#   2. aggregator.md does NOT contain Bug-Class-Recurrence wording.
#   3. aggregator.md Path 2 trigger references count[N] < count[N-1]
#      strict-decrease over 3 rounds.
#   4. aggregator.md Path 2 action includes "Skip the per-angle Probes block".
#   5. critic.md does NOT contain K-decay or engagement-aware wording.
#   6. momentum.md does NOT reference the deleted GROWING/STABLE/SHRINKING tags.
#   7. loc-trend.sh does NOT emit a Trajectory: line.
#
# This file's ASSERTIONS ARE THE CONTRACT — removing an assertion removes
# a fence. Each fence was written in response to a specific regression
# in the elegant-convergence refactor.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0

assert_present() {
    local label="$1" pattern="$2" file="$3"
    if ! grep -qF -- "$pattern" "$file"; then
        echo "FAIL: $label (pattern not found: '$pattern')"
        fail=1
    fi
}

assert_absent() {
    local label="$1" pattern="$2" file="$3"
    if grep -qF -- "$pattern" "$file"; then
        echo "FAIL: $label (pattern must be absent: '$pattern')"
        fail=1
    fi
}

# Contract 1: cited-shape-at-HEAD rule present in step 38
echo "  asserting step 38 cited-shape-at-HEAD rule in aggregator.md..."
assert_present \
    "step 38 cited-shape-at-HEAD rule" \
    "cited \`Files:\` shape still exist at HEAD" \
    "$PROJECT_ROOT/prompts/aggregator.md"

# Contract 2: Bug-Class-Recurrence fully deleted from aggregator
echo "  asserting BCR removed from aggregator.md..."
assert_absent \
    "BCR removed from aggregator" \
    "Bug-Class-Recurrence" \
    "$PROJECT_ROOT/prompts/aggregator.md"

# Contract 3: Path 2 strict-decrease trigger
echo "  asserting Path 2 strict-decrease trigger in aggregator.md..."
assert_present \
    "Path 2 strict-decrease trigger (count[N] < count[N-1])" \
    'count[N] < count[N-1]' \
    "$PROJECT_ROOT/prompts/aggregator.md"

# Contract 4: Path 2 halt action
echo "  asserting Path 2 halt action in aggregator.md..."
assert_present \
    "Path 2 halt action (Skip the per-angle Probes block)" \
    "Skip the per-angle Probes block entirely this round" \
    "$PROJECT_ROOT/prompts/aggregator.md"

# Contract 5: K-decay deleted from critic
echo "  asserting K-decay removed from critic.md..."
assert_absent \
    "K-decay removed from critic" \
    "K-decay" \
    "$PROJECT_ROOT/prompts/critic.md"
assert_absent \
    "engagement-aware removed from critic" \
    "engagement-aware" \
    "$PROJECT_ROOT/prompts/critic.md"

# Contract 6: momentum trichotomy tags gone
echo "  asserting momentum trichotomy refs removed from momentum.md..."
for tag in GROWING STABLE SHRINKING; do
    assert_absent \
        "momentum trichotomy tag '$tag' removed" \
        "$tag" \
        "$PROJECT_ROOT/prompts/standalone/momentum.md"
done

# Contract 7: loc-trend.sh emits no Trajectory: line
echo "  asserting loc-trend.sh emits no Trajectory: line..."
assert_absent \
    "loc-trend.sh emits no Trajectory: line" \
    "Trajectory:" \
    "$PROJECT_ROOT/lib/loc-trend.sh"

if [ "$fail" -ne 0 ]; then
    echo "FAIL: aggregator-convergence-smoke"
    exit 1
fi
echo "  PASS"
