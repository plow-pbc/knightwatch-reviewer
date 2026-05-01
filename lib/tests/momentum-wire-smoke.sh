#!/bin/bash
# Smoke for momentum specialist orchestrator wiring.
#
# Token-level fence — the orchestrator's momentum invocation block must
# reference momentum.md, gate on previous-review.md, and call run-specialist.sh.
# (Behavior assertion would require a real codex invocation + fixtures;
#  this catches the "added the prompt but forgot to wire it" omission class.)

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

echo "  asserting momentum.md invocation in review-one-pr.sh..."
assert_grep "review-one-pr.sh missing momentum.md reference" \
    "momentum.md" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting momentum gate on previous-review.md..."
assert_grep "review-one-pr.sh missing previous-review.md gate around momentum" \
    "previous-review.md" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting momentum dispatch via run-specialist.sh..."
assert_grep "review-one-pr.sh missing run-specialist.sh dispatch for momentum" \
    'run-specialist.sh" "momentum"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  PASS"
