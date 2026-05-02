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

# Wiring lives in lib/orchestrate.sh (extracted from review-one-pr.sh) —
# the function `run_specialist_pipeline` is sourced and invoked from the
# main worker.
ORCHESTRATE="$PROJECT_ROOT/lib/orchestrate.sh"

echo "  asserting momentum.md invocation in orchestrate.sh..."
assert_grep "orchestrate.sh missing momentum.md reference" \
    "momentum.md" "$ORCHESTRATE"

echo "  asserting momentum gate on previous-review.md..."
# Fence the EXACT guard pattern, not the bare substring "previous-review.md"
# (which appears in unrelated write_scratch calls + comments and would PASS
# even if the re-review-only gate around the momentum specialist disappeared).
# A future refactor that drops the `if [ -s ... ]; then` around the momentum
# block now fails here instead of silently regressing.
assert_grep "orchestrate.sh missing momentum gate (\$RUN_DIR/inputs/previous-review.md)" \
    'if [ -s "$RUN_DIR/inputs/previous-review.md" ]' "$ORCHESTRATE"

echo "  asserting momentum is dispatched..."
# Dispatch goes through the generic `dispatch_agent NAME` helper which
# selects the right prompt builder and calls run-specialist.sh.
assert_grep "orchestrate.sh missing dispatch_agent momentum call" \
    'dispatch_agent momentum' "$ORCHESTRATE"

echo "  asserting momentum output symlink to .codex-scratch/momentum.md..."
assert_grep "orchestrate.sh missing symlink from RUN_DIR/agents/momentum/output.md to .codex-scratch/momentum.md" \
    ".codex-scratch/momentum.md" "$ORCHESTRATE"

echo "  asserting orchestrate.sh is sourced from review-one-pr.sh..."
assert_grep "review-one-pr.sh does not source lib/orchestrate.sh" \
    'orchestrate.sh' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  PASS"
