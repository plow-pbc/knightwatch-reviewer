#!/bin/bash
# Smoke for go-deep tech-lead orchestrator wiring.
#
# Token-level fence — orchestrate.sh must reference go-deep.md, gate
# on "Calibration questions for go-deep" (the critic emits this for
# ≥20 LOC findings only — auto-scale to 0), cap at 3 parallel, and
# append outputs to specialists/<angle>.md under a Go-deep H2.
# Behavior assertions for ranker selection live in go-deep-rank-smoke.sh.
# Behavior assertions for go-deep-* prompt building live in
# dispatch-agent-smoke.sh. This smoke catches the "added the prompt
# but forgot to wire it into the pipeline" omission class.

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

echo "  asserting go-deep-* dispatch case in orchestrate.sh..."
assert_grep "orchestrate.sh missing go-deep-* dispatch case" \
    "go-deep-*)" "$PROJECT_ROOT/lib/orchestrate.sh"
assert_grep "orchestrate.sh go-deep-* should reference prompts/go-deep.md" \
    "prompts/go-deep.md" "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting hot-list gate token in run_specialist_pipeline..."
assert_grep "orchestrate.sh should call rank_hot_angles (lib/go-deep-rank.sh sourceable seam)" \
    'rank_hot_angles "$SPECIALISTS_DIR"' "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting rank_hot_angles helper exists with severity-band ranker..."
# Round-1 + round-2 regression fences moved into go-deep-rank-smoke.sh
# (behavior tests with synthetic specialist files). Token-grep here just
# fences the helper's existence + presence of the severity-band loop.
assert_grep "lib/go-deep-rank.sh missing parallel cap (-le 3)" \
    "-le 3" "$PROJECT_ROOT/lib/go-deep-rank.sh"
assert_grep "lib/go-deep-rank.sh missing severity-band loop" \
    'in "blocking" "medium" "low" "nit"' "$PROJECT_ROOT/lib/go-deep-rank.sh"
assert_grep "lib/go-deep-rank.sh should grep '### Finding N — <sev>' specialist contract" \
    '^### Finding [0-9]+ — $sev' "$PROJECT_ROOT/lib/go-deep-rank.sh"

echo "  asserting decline-history skipped on FORCE_WHOLE_PR=true..."
# Regression fence for the F1a round-1 finding: /srosro-review path
# commits to "Any prior review is intentionally NOT provided — evaluate
# this PR from scratch." Staging decline-history anyway breaks that
# contract. Mirrors the existing prior-reviews.md skip block.
assert_grep "review-one-pr.sh missing FORCE_WHOLE_PR gate around fetch_decline_history" \
    'FORCE_WHOLE_PR" = "true" ]; then
    log "$PR_ID: FORCE_WHOLE_PR=true — staging decline-history.md sentinel' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep dispatch via dispatch_agent..."
assert_grep "orchestrate.sh missing dispatch_agent invocation for go-deep-<angle>" \
    'dispatch_agent "go-deep-$angle"' "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting fail-loud abort on go-deep failure..."
# Regression fence for round-2 F4: silent degrade of go-deep failures
# would publish high-cost findings without calibration. Match momentum
# specialist's pattern.
assert_grep "orchestrate.sh missing fail-loud abort on go-deep failure" \
    "at least one go-deep tech-lead failed — aborting review" "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting go-deep output append under '## Go-deep tech-lead investigation'..."
assert_grep "orchestrate.sh missing append H2 for go-deep output" \
    "## Go-deep tech-lead investigation" "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting critic-splitter call between critic and go-deep..."
assert_grep "orchestrate.sh missing split_critic_to_specialists call" \
    "split_critic_to_specialists" "$PROJECT_ROOT/lib/orchestrate.sh"

echo "  PASS"
