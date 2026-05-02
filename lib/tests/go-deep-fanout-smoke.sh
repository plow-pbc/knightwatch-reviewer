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

echo "  asserting decline-history gated on FORCE_WHOLE_PR=true AND first-review..."
# Regression fence for the round-1 F1a + round-4 F5 findings:
# /srosro-review path commits to "evaluate from scratch"; first reviews
# have no prior bot findings to have declined. Both paths must stage
# the sentinel rather than fetching real declines.
#
# Multi-line grep -F treats each line as an independent pattern, so a
# multi-line assertion would false-green when the lines are present
# anywhere in the file (not adjacent). Split into per-line tokens AND
# perl one-liners that pin each conditional+sentinel pair as adjacent.
assert_grep "review-one-pr.sh missing FORCE_WHOLE_PR=true conditional" \
    'FORCE_WHOLE_PR" = "true" ]; then' "$PROJECT_ROOT/lib/review-one-pr.sh"
assert_grep "review-one-pr.sh missing whole-PR decline-history sentinel log" \
    'FORCE_WHOLE_PR=true — staging decline-history.md sentinel' "$PROJECT_ROOT/lib/review-one-pr.sh"
assert_grep "review-one-pr.sh missing first-review elif gate on PRIOR_REVIEWS" \
    'elif [ -z "${PRIOR_REVIEWS:-}" ]; then' "$PROJECT_ROOT/lib/review-one-pr.sh"
assert_grep "review-one-pr.sh missing first-review decline-history sentinel log" \
    'first review (no prior bot reviews) — staging decline-history.md sentinel' "$PROJECT_ROOT/lib/review-one-pr.sh"
# Adjacency check — both conditional+log pairs must be in the same block.
if ! perl -0777 -ne '
    exit 0 if /FORCE_WHOLE_PR" = "true" \]; then\s*\n\s*log [^\n]*FORCE_WHOLE_PR=true — staging decline-history\.md sentinel/;
    exit 1
' "$PROJECT_ROOT/lib/review-one-pr.sh"; then
    echo "FAIL: review-one-pr.sh FORCE_WHOLE_PR conditional and sentinel log are not adjacent"
    exit 1
fi
if ! perl -0777 -ne '
    exit 0 if /elif \[ -z "\$\{PRIOR_REVIEWS:-\}" \]; then\s*\n\s*log [^\n]*first review \(no prior bot reviews\) — staging decline-history\.md sentinel/;
    exit 1
' "$PROJECT_ROOT/lib/review-one-pr.sh"; then
    echo "FAIL: review-one-pr.sh first-review elif and sentinel log are not adjacent"
    exit 1
fi

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
