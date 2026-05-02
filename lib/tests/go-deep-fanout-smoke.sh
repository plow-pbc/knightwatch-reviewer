#!/bin/bash
# Smoke for go-deep tech-lead orchestrator wiring.
#
# Token-level fence — review-one-pr.sh must reference go-deep.md, gate
# on "Calibration questions for go-deep" (the critic emits this for
# ≥20 LOC findings only — auto-scale to 0), cap at 3 parallel, and
# append outputs to specialists/<angle>.md under a Go-deep H2.
# Behavior assertion would require a real codex invocation + fixtures;
# this catches the "added the prompt but forgot to wire it" omission class.

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

echo "  asserting go-deep.md prompt referenced in review-one-pr.sh..."
assert_grep "review-one-pr.sh missing go-deep.md reference" \
    "go-deep.md" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting hot-list gate on Calibration questions token..."
assert_grep "review-one-pr.sh missing 'Calibration questions for go-deep' gate" \
    "Calibration questions for go-deep" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting parallel cap at 3..."
assert_grep "review-one-pr.sh missing parallel cap (-gt 3)" \
    "-gt 3" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting severity-band ranker..."
assert_grep "review-one-pr.sh missing severity-band ranker (blocking medium low nit loop)" \
    'in "blocking" "medium" "low" "nit"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting ranker matches specialist contract (### Finding N — <severity>)..."
# Regression fence for the F2 round-1 finding: earlier code grepped for
# "[blocking]" (aggregator-published format) but specialist files at this
# stage emit "### Finding N — blocking" per common-header.md:48. Wrong
# pattern would silently empty HOT_ANGLES on the 4+ specialist case.
assert_grep "review-one-pr.sh ranker should grep '### Finding N — <sev>' specialist contract" \
    '^### Finding [0-9]+ — $sev' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep prompt build uses substitute_placeholders (not build_specialist_prompt)..."
# Regression fence for the F3 round-1 finding: build_specialist_prompt
# prepends common-header.md (specialist Surveyed/Finding-N contract) which
# conflicts with go-deep.md's "no extra headers + Recommendation block"
# contract. Mirror the intent step's substitute_placeholders pattern.
assert_grep "review-one-pr.sh go-deep build should call substitute_placeholders directly" \
    'substitute_placeholders \\
            "$HOME/.pr-reviewer/prompts/go-deep.md"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting decline-history skipped on FORCE_WHOLE_PR=true..."
# Regression fence for the F1a round-1 finding: /srosro-review path
# commits to "Any prior review is intentionally NOT provided — evaluate
# this PR from scratch." Staging decline-history anyway breaks that
# contract. Mirrors the existing prior-reviews.md skip block.
assert_grep "review-one-pr.sh missing FORCE_WHOLE_PR gate around fetch_decline_history" \
    'FORCE_WHOLE_PR" = "true" ]; then
    log "$PR_ID: FORCE_WHOLE_PR=true — skipping decline-history.md' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep dispatch via run-specialist.sh..."
assert_grep "review-one-pr.sh missing 'go-deep-' agent name prefix" \
    '"go-deep-$angle"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep output append under '## Go-deep tech-lead investigation'..."
assert_grep "review-one-pr.sh missing append H2 for go-deep output" \
    "## Go-deep tech-lead investigation" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep output append into specialists/<angle>.md..."
assert_grep "review-one-pr.sh missing redirect into specialists/<angle>.md" \
    'SPECIALISTS_DIR/${angle}.md"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  PASS"
