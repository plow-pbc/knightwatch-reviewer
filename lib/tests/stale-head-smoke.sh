#!/bin/bash
# Smoke for prepend_stale_head_note (lib/run-dir.sh).
#
# The worker fetches the current PR head right before posting the review
# comment. If it differs from the SHA the review was generated against
# (head moved mid-run), a warning gets injected after the auto-post
# marker line so the user doesn't read the posted review as if it were
# evaluating the current state.
#
# Lock down three branches:
#   1. SHAs match → no warning, body returned verbatim.
#   2. SHAs differ → warning prepended after first line; both SHA prefixes
#      cited; auto-post marker still on first line; original body still
#      present in full.
#   3. CURRENT_HEAD empty (gh pr view failed) → no-op, no warning. Caller
#      gets behavior identical to pre-change code in this case.
#
# Hermetic: sources lib/run-dir.sh directly and invokes the helper with
# explicit args; no closure state needed.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

MARKER='<!-- knightwatch-reviewer:auto-post -->'
BODY=$(printf '%s\n_intent line_\n\n**Overview** — text\n\n**Findings**\n1. [medium] something' "$MARKER")

# ---- scenario 1: SHAs match → unchanged ----
echo "  scenario 1: SHAs match → body unchanged..."
result=$(prepend_stale_head_note "$BODY" "abc1234567" "abc1234567")
if [ "$result" != "$BODY" ]; then
    echo "FAIL: scenario 1 — body was modified when SHAs match"
    diff <(printf '%s' "$BODY") <(printf '%s' "$result")
    exit 1
fi

# ---- scenario 2: SHAs differ → warning prepended ----
echo "  scenario 2: SHAs differ → warning prepended after marker..."
result=$(prepend_stale_head_note "$BODY" "abc1234567" "def9876543")

# 2a. First line is still the auto-post marker (orchestrator's
#     self-trigger filter depends on this).
first=$(printf '%s' "$result" | head -1)
if [ "$first" != "$MARKER" ]; then
    echo "FAIL: scenario 2 — first line is no longer the auto-post marker"
    echo "  got: $first"
    exit 1
fi

# 2b. Warning text is present and cites both SHA prefixes.
if ! printf '%s' "$result" | grep -q "Stale review"; then
    echo "FAIL: scenario 2 — 'Stale review' marker missing"
    echo "$result"
    exit 1
fi
if ! printf '%s' "$result" | grep -q '`abc1234`'; then
    echo "FAIL: scenario 2 — reviewed SHA prefix abc1234 missing from warning"
    echo "$result"
    exit 1
fi
if ! printf '%s' "$result" | grep -q '`def9876`'; then
    echo "FAIL: scenario 2 — current head prefix def9876 missing from warning"
    echo "$result"
    exit 1
fi

# 2c. Warning points to "commands at the bottom of this comment" — single
#     source of truth for usage. No /srosro-* command name in the warning.
if ! printf '%s' "$result" | grep -q "commands at the bottom"; then
    echo "FAIL: scenario 2 — warning doesn't reference 'commands at the bottom'"
    echo "$result"
    exit 1
fi
if printf '%s' "$result" | grep -q "/srosro-update-review"; then
    # The footer in the real bot post DOES contain /srosro-update-review,
    # but BODY in this test doesn't include the footer — so a hit means
    # the warning itself is duplicating the command name. That defeats
    # the "single source of truth" intent.
    echo "FAIL: scenario 2 — warning duplicates a slash-command name (should defer to footer)"
    echo "$result"
    exit 1
fi

# 2d. Original body content is still present in full (intent line + finding).
if ! printf '%s' "$result" | grep -q "_intent line_"; then
    echo "FAIL: scenario 2 — original intent line lost"
    echo "$result"
    exit 1
fi
if ! printf '%s' "$result" | grep -q "1\. \[medium\] something"; then
    echo "FAIL: scenario 2 — original finding text lost"
    echo "$result"
    exit 1
fi

# ---- scenario 3: empty CURRENT_HEAD (gh failure) → unchanged ----
echo "  scenario 3: empty CURRENT_HEAD (gh pr view failed) → body unchanged..."
result=$(prepend_stale_head_note "$BODY" "abc1234567" "")
if [ "$result" != "$BODY" ]; then
    echo "FAIL: scenario 3 — body was modified when CURRENT_HEAD is empty"
    diff <(printf '%s' "$BODY") <(printf '%s' "$result")
    exit 1
fi

echo "  PASS (3 scenarios: matched-shas-noop, differing-shas-warning, gh-failure-noop)"
