#!/bin/bash
# Smoke for prepend_review_scope_note (lib/run-dir.sh).
#
# The worker computes REVIEW_SCOPE from FORCE_WHOLE_PR / KNOWN_SHA /
# USED_FALLBACK and asks the helper to inject a one-line scope notice
# right after the auto-post marker. Without this disclosure, an
# incremental re-review and a silent-fallback re-review (worker
# couldn't find KNOWN_SHA in local history and silently used the full
# PR diff while the prose still said "incremental") read identically
# even though the specialists evaluated different code.
#
# Lock down five branches:
#   1. scope="first"            → "First review" note, marker preserved
#   2. scope="whole"            → "Whole-PR re-review" note
#   3. scope="incremental:<sha>" → 7-char SHA prefix cited
#   4. scope="fallback:<sha>"   → SHA cited + force-push/rebase mentioned
#   5. scope="bogus"            → fail-fast: returns non-zero + writes a
#                                  diagnostic to stderr. scope is internally
#                                  generated, so an unknown value is an
#                                  invariant violation; per CLAUDE.md /
#                                  feedback_fail_hard, the helper must NOT
#                                  silently omit the disclosure (that would
#                                  let a regression ship a banner-less review)
#
# Every scenario also asserts: marker stays on first line (orchestrator's
# self-trigger filter depends on it) and the original body content
# (intent line + finding) is preserved.
#
# Hermetic: sources lib/run-dir.sh and invokes the helper with explicit
# args; no closure state needed.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

MARKER='<!-- knightwatch-reviewer:auto-post -->'
BODY=$(printf '%s\n_intent line_\n\n**Overview** — text\n\n**Findings**\n1. [medium] something' "$MARKER")

assert_marker_first() {
    local result="$1" scenario="$2"
    local first
    first=$(printf '%s' "$result" | head -1)
    if [ "$first" != "$MARKER" ]; then
        echo "FAIL: $scenario — first line is no longer the auto-post marker"
        echo "  got: $first"
        exit 1
    fi
}

assert_body_preserved() {
    local result="$1" scenario="$2"
    if ! printf '%s' "$result" | grep -q "_intent line_"; then
        echo "FAIL: $scenario — original intent line lost"
        echo "$result"
        exit 1
    fi
    if ! printf '%s' "$result" | grep -q "1\. \[medium\] something"; then
        echo "FAIL: $scenario — original finding text lost"
        echo "$result"
        exit 1
    fi
}

# ---- scenario 1: first review ----
echo "  scenario 1: scope=first → 'First review' note injected..."
result=$(prepend_review_scope_note "$BODY" "first")
assert_marker_first "$result" "scenario 1"
assert_body_preserved "$result" "scenario 1"
if ! printf '%s' "$result" | grep -q "First review"; then
    echo "FAIL: scenario 1 — 'First review' note missing"
    echo "$result"
    exit 1
fi

# ---- scenario 2: whole-PR re-review ----
echo "  scenario 2: scope=whole → 'Whole-PR re-review' note..."
result=$(prepend_review_scope_note "$BODY" "whole")
assert_marker_first "$result" "scenario 2"
assert_body_preserved "$result" "scenario 2"
if ! printf '%s' "$result" | grep -q "Whole-PR re-review"; then
    echo "FAIL: scenario 2 — 'Whole-PR re-review' note missing"
    echo "$result"
    exit 1
fi
# Must disclose the "from scratch / no prior review consulted" framing —
# this is the user-visible signal that distinguishes /srosro-review from
# the default incremental flow.
if ! printf '%s' "$result" | grep -q "from scratch"; then
    echo "FAIL: scenario 2 — 'from scratch' framing missing (whole-PR scope must disclose no prior consultation)"
    echo "$result"
    exit 1
fi

# ---- scenario 3: incremental re-review ----
echo "  scenario 3: scope=incremental:<sha> → SHA prefix cited..."
result=$(prepend_review_scope_note "$BODY" "incremental:abc1234567")
assert_marker_first "$result" "scenario 3"
assert_body_preserved "$result" "scenario 3"
if ! printf '%s' "$result" | grep -q '`abc1234`'; then
    echo "FAIL: scenario 3 — 7-char SHA prefix abc1234 missing from incremental note"
    echo "$result"
    exit 1
fi
if ! printf '%s' "$result" | grep -q "Re-review of changes since"; then
    echo "FAIL: scenario 3 — 'Re-review of changes since' phrase missing"
    echo "$result"
    exit 1
fi

# ---- scenario 4: silent-fallback re-review ----
echo "  scenario 4: scope=fallback:<sha> → SHA cited + force-push mention..."
result=$(prepend_review_scope_note "$BODY" "fallback:abc1234567")
assert_marker_first "$result" "scenario 4"
assert_body_preserved "$result" "scenario 4"
if ! printf '%s' "$result" | grep -q '`abc1234`'; then
    echo "FAIL: scenario 4 — 7-char SHA prefix abc1234 missing from fallback note"
    echo "$result"
    exit 1
fi
# The fallback's whole point is to disclose the silent-full-PR-diff
# behavior. If the wording stops naming the cause (force-push or rebase
# evicted the SHA), the reader can't tell why this re-review evaluated
# the whole PR instead of the incremental diff.
if ! printf '%s' "$result" | grep -q "force-push"; then
    echo "FAIL: scenario 4 — fallback note dropped the 'force-push' disclosure"
    echo "$result"
    exit 1
fi
if ! printf '%s' "$result" | grep -q "full PR diff"; then
    echo "FAIL: scenario 4 — fallback note dropped the 'full PR diff' disclosure"
    echo "$result"
    exit 1
fi

# ---- scenario 5: unknown scope → fail-fast ----
# An earlier cut had this scenario asserting silent no-op (return body
# unchanged on unknown scope). The bot review caught it: scope is
# internally generated by compute_review_scope, so an unknown value is
# an invariant violation — the only realistic way it happens is a future
# refactor adding a 5th scope to compute_review_scope without wiring it
# here. Silently no-op'ing in that case ships a normal-looking review
# with the scope banner missing, which is exactly the failure mode this
# whole helper exists to prevent. Now: print diagnostic + return 1.
echo "  scenario 5: scope=bogus → fail-fast (non-zero exit + stderr diagnostic)..."
result=$(prepend_review_scope_note "$BODY" "bogus" 2>/dev/null)
if [ "$?" -eq 0 ]; then
    echo "FAIL: scenario 5 — function returned 0 for unknown scope (silent degrade); should exit non-zero per CLAUDE.md fail-fast"
    exit 1
fi
err=$(prepend_review_scope_note "$BODY" "bogus" 2>&1 >/dev/null)
if ! printf '%s' "$err" | grep -q "unknown scope"; then
    echo "FAIL: scenario 5 — stderr diagnostic missing 'unknown scope' phrasing; got: $err"
    exit 1
fi

# ===== compute_review_scope (worker seam) =====
# The formatter scenarios above only cover the post-time injection. A
# second drift surface — flagged in PR #22's bot review as the recurring
# class — is the worker computation itself: if the case that flips
# USED_FALLBACK or the precedence between FORCE_WHOLE_PR / KNOWN_SHA
# regresses, the formatter still produces valid output but for the
# wrong scope. Pin the worker-seam mapping directly so a regression at
# either layer trips CI.

assert_scope() {
    local got="$1" want="$2" desc="$3"
    if [ "$got" != "$want" ]; then
        echo "FAIL: compute_review_scope — $desc: expected '$want', got '$got'"
        exit 1
    fi
}

echo "  compute_review_scope: force=true + no sha → 'whole'..."
assert_scope "$(compute_review_scope true "" false)" "whole" "force-only"

echo "  compute_review_scope: force=true + sha + fallback=true → 'whole' (force precedence)..."
# Precedence regression-fence: /srosro-review explicitly asks for a
# whole-PR re-review and must NOT be downgraded to incremental or
# fallback even when KNOWN_SHA is set or the SHA was evicted. If a
# refactor accidentally checks KNOWN_SHA first, this trips.
assert_scope "$(compute_review_scope true "abc1234567" true)" "whole" "force takes precedence over sha+fallback"

echo "  compute_review_scope: no force + no sha → 'first'..."
assert_scope "$(compute_review_scope false "" false)" "first" "no-sha → first"

echo "  compute_review_scope: no force + sha + fallback=false → 'incremental:<sha>'..."
assert_scope "$(compute_review_scope false "abc1234567" false)" "incremental:abc1234567" "incremental path"

echo "  compute_review_scope: no force + sha + fallback=true → 'fallback:<sha>'..."
# The bug the original PR #22 was meant to disclose: USED_FALLBACK=true
# previously got framed as incremental in the banner. This pin prevents
# a refactor from dropping the fallback branch and silently regressing
# back to the original misframe.
assert_scope "$(compute_review_scope false "abc1234567" true)" "fallback:abc1234567" "fallback path — must not be misframed as incremental"

echo "  PASS (5 formatter scenarios incl. unknown-scope fail-fast + 5 worker-seam scenarios)"
