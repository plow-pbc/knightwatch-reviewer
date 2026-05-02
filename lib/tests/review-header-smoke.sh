#!/usr/bin/env bash
# Smoke for the unified deterministic-registry rendering path:
#   prepend_review_header COMMENT_BODY NOTE [NOTE...]
#   format_review_scope SCOPE  (scope-token → human-readable fragment)
#   compute_review_scope FORCE KNOWN_SHA USED_FALLBACK
#   classify_just_test_outcome TEST_EXIT TEST_LOG TEST_TIMEOUT
#
# REVIEW_NOTES is the single registry the worker assembles before posting.
# Each entry is a fully-rendered fragment (icon + text, no trailing
# punctuation); the helper joins with ". " and emits one blockquote
# under the auto-post marker. Adding a new deterministic check is one
# line at the worker's REVIEW_NOTES assembly site — no helper change.
#
# Coverage:
#   - join: 1 / 2 / 3+ notes — joined with ". " + final "."
#   - empty notes list → fail-fast (rc=1, stderr diagnostic)
#   - exactly one blockquote line (no stacking)
#   - marker stays first line (orchestrator's self-trigger filter
#     depends on it)
#   - body content preserved
#   - scope-fragment mapping per token (first / whole / incremental:X /
#     fallback:X), with fallback ≠ incremental wording-fenced so a
#     regression that misframes fallback as incremental trips here
#   - regression-fences: no "diff alone" tail (PR #24 round 4), no
#     "next orchestrator tick" auto-recovery copy, scope-fragment
#     wording stays stable
#   - compute_review_scope worker-seam (5 scenarios)
#   - classify_just_test_outcome worker-seam (9 scenarios)
#
# Hermetic — sources lib/run-dir.sh and invokes helpers with explicit
# args; no closure state.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

MARKER='<!-- knightwatch-reviewer:auto-post -->'
AI_AUTHOR_MARKER='<!-- knightwatch-reviewer:ai-author note=load-bearing-probes operating-point=pre-pmf prefer=cut-loc-over-add -->'
BODY=$(printf '%s\n%s\n_intent line_\n\n**Overview** — text\n\n**Findings**\n1. [medium] something' "$MARKER" "$AI_AUTHOR_MARKER")

SHA_OLD="abc1234567"
SHA_NEW="def9876543"

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

assert_contains() {
    local result="$1" needle="$2" scenario="$3"
    if ! printf '%s' "$result" | grep -qF "$needle"; then
        echo "FAIL: $scenario — expected to contain: $needle"
        echo "  got:"
        echo "$result"
        exit 1
    fi
}

assert_one_blockquote() {
    # The whole point of a single registry: one blockquote line, never
    # stacked. Count lines starting with `> ` — must be exactly 1.
    local result="$1" scenario="$2" count
    count=$(printf '%s\n' "$result" | grep -c '^> ')
    if [ "$count" -ne 1 ]; then
        echo "FAIL: $scenario — expected exactly 1 blockquote line, got $count"
        echo "$result"
        exit 1
    fi
}

# ===== prepend_review_header — join behavior =====
echo "  asserting BOT_AI_AUTHOR_MARKER prepended after auto-post marker..."
result=$(prepend_review_header "$BODY" "📋 First review of this PR")
grep -q '<!-- knightwatch-reviewer:auto-post -->' <<< "$result" || { echo "FAIL: auto-post marker missing"; exit 1; }
grep -q '<!-- knightwatch-reviewer:ai-author' <<< "$result" || { echo "FAIL: ai-author marker missing"; exit 1; }

echo "  one note → blockquote has just that note + final '.'..."
result=$(prepend_review_header "$BODY" "📋 First review of this PR")
assert_marker_first "$result" "one-note"
assert_body_preserved "$result" "one-note"
assert_one_blockquote "$result" "one-note"
assert_contains "$result" "> 📋 First review of this PR." "one-note rendered with final period"

echo "  two notes → joined with '. ' + final '.'..."
result=$(prepend_review_header "$BODY" "📋 First review of this PR" "🧪 Tests not run")
assert_one_blockquote "$result" "two-notes"
assert_contains "$result" "> 📋 First review of this PR. 🧪 Tests not run." "two-notes joined with '. '"

echo "  three notes → joined with '. '..."
result=$(prepend_review_header "$BODY" "A" "B" "C")
assert_one_blockquote "$result" "three-notes"
assert_contains "$result" "> A. B. C." "three-notes joined"

echo "  empty notes list → fail-fast (rc=1 + stderr diagnostic)..."
prepend_review_header "$BODY" 2>/dev/null
if [ "$?" -eq 0 ]; then
    echo "FAIL: empty-notes — function returned 0 (silent degrade); should exit non-zero per CLAUDE.md fail-fast"
    exit 1
fi
err=$(prepend_review_header "$BODY" 2>&1 >/dev/null)
if ! printf '%s' "$err" | grep -q "empty notes list"; then
    echo "FAIL: empty-notes — stderr diagnostic missing 'empty notes list' phrasing; got: $err"
    exit 1
fi

# Realistic worker-output combinations: scope + skipped checks + gap
# fragments. Verifies the helper handles every typical REVIEW_NOTES
# composition without splitting into multiple blockquote lines.
echo "  scope + tests-skip + KID-skip + strict-typing-gap → one blockquote, all four..."
SCOPE=$(format_review_scope "first")
result=$(prepend_review_header "$BODY" \
    "$SCOPE" \
    "🧪 Tests not run" \
    "🔍 Prior-art (KID) not run" \
    "❌ Strict typing not enforced")
assert_one_blockquote "$result" "all-four-signals"
assert_contains "$result" "First review of this PR" "all-four-signals scope"
assert_contains "$result" "🧪 Tests not run" "all-four-signals tests"
assert_contains "$result" "🔍 Prior-art (KID) not run" "all-four-signals kid"
assert_contains "$result" "❌ Strict typing not enforced" "all-four-signals strict-typing"

# Regression-fence: the bot flagged the trailing "review based on the
# diff alone" clause as misleading on KID-only skips (tests + specialists
# still ran). Make sure a worker passing only the KID skip note doesn't
# get a "diff alone" tail re-introduced anywhere in the output.
echo "  KID-only skip → no 'diff alone' tail re-introduced (PR #24 round 4 fence)..."
result=$(prepend_review_header "$BODY" \
    "$(format_review_scope "first")" \
    "🔍 Prior-art (KID) not run")
if printf '%s' "$result" | grep -q "diff alone"; then
    echo "FAIL: kid-only — re-introduced misleading 'diff alone' tail"
    exit 1
fi

# Order regression-fence: notes render in the order the worker pushed
# them. Worker convention: scope → stale → tests → KID → gaps. Helper
# must preserve that order, not sort.
echo "  push order = render order (worst-case header)..."
result=$(prepend_review_header "$BODY" \
    "$(format_review_scope "incremental:$SHA_OLD" "$SHA_NEW")" \
    "⚠️ Stale: head moved from \`${SHA_OLD:0:7}\` to \`${SHA_NEW:0:7}\` mid-run — see commands below to re-run" \
    "🧪 Tests not run" \
    "🔍 Prior-art (KID) not run" \
    "❌ Strict typing not enforced")
assert_one_blockquote "$result" "worst-case"
result_line=$(printf '%s\n' "$result" | grep '^> ')
scope_pos=$(printf '%s' "$result_line" | grep -bo "Re-review of changes from" | head -1 | cut -d: -f1)
stale_pos=$(printf '%s' "$result_line" | grep -bo "Stale: head moved" | head -1 | cut -d: -f1)
tests_pos=$(printf '%s' "$result_line" | grep -bo "Tests not run" | head -1 | cut -d: -f1)
kid_pos=$(printf '%s' "$result_line" | grep -bo "Prior-art" | head -1 | cut -d: -f1)
strict_pos=$(printf '%s' "$result_line" | grep -bo "Strict typing" | head -1 | cut -d: -f1)
if ! { [ "$scope_pos" -lt "$stale_pos" ] && \
       [ "$stale_pos" -lt "$tests_pos" ] && \
       [ "$tests_pos" -lt "$kid_pos"   ] && \
       [ "$kid_pos"   -lt "$strict_pos" ]; }; then
    echo "FAIL: worst-case — order regressed (scope=$scope_pos, stale=$stale_pos, tests=$tests_pos, kid=$kid_pos, strict=$strict_pos)"
    echo "$result_line"
    exit 1
fi

# Regression-fence: the previous wording promised auto-recovery on the
# next orchestrator tick. Real cadence is STABLE_SECS=3600 — non-forced
# re-reviews wait an hour. Stale-fragment must defer to the footer
# commands, not name a specific slash-command in the fragment itself.
echo "  stale fragment must NOT promise auto-recovery on next tick..."
stale_note="⚠️ Stale: head moved from \`${SHA_OLD:0:7}\` to \`${SHA_NEW:0:7}\` mid-run — see commands below to re-run"
if printf '%s' "$stale_note" | grep -q "next orchestrator tick"; then
    echo "FAIL: stale-fragment — re-introduced misleading 'next orchestrator tick' auto-recovery promise"
    exit 1
fi
if printf '%s' "$stale_note" | grep -q "/srosro-update-review"; then
    echo "FAIL: stale-fragment — duplicates a slash-command name (should defer to footer)"
    exit 1
fi

# ===== format_review_scope — token → fragment mapping =====
assert_scope_text() {
    local got="$1" want="$2" desc="$3"
    if [ "$got" != "$want" ]; then
        echo "FAIL: format_review_scope — $desc: expected '$want', got '$got'"
        exit 1
    fi
}

echo "  format_review_scope: first → fragment..."
assert_scope_text \
    "$(format_review_scope first)" \
    "📋 First review of this PR" \
    "first"

echo "  format_review_scope: whole → fragment with /srosro-review citation..."
result=$(format_review_scope whole)
assert_contains "$result" "Whole-PR re-review" "whole keyword"
assert_contains "$result" '`/srosro-review`' "whole cites trigger"
assert_contains "$result" "from scratch" "whole discloses no-prior-review"

echo "  format_review_scope: incremental:<from> <to> → cites both SHAs and the git diff command..."
result=$(format_review_scope "incremental:$SHA_OLD" "$SHA_NEW")
assert_scope_text "$result" "📋 Re-review of changes from \`abc1234\` to \`def9876\` (\`git diff abc1234..def9876\`)" "incremental"

echo "  format_review_scope: incremental without head_sha → fail-fast (rc=1 + stderr diagnostic)..."
format_review_scope "incremental:$SHA_OLD" 2>/dev/null
if [ "$?" -eq 0 ]; then
    echo "FAIL: incremental w/o head_sha — returned 0 (silent degrade); should fail-fast per CLAUDE.md"
    exit 1
fi
err=$(format_review_scope "incremental:$SHA_OLD" 2>&1 >/dev/null)
if ! printf '%s' "$err" | grep -q "incremental scope requires head_sha"; then
    echo "FAIL: incremental w/o head_sha — stderr diagnostic missing 'incremental scope requires head_sha'; got: $err"
    exit 1
fi

# Wording-fence — fallback MUST NOT be misframed as incremental. A bug
# class flagged in PR #22 bot review (USED_FALLBACK=true previously got
# rendered as incremental; pin it here so a regression trips the smoke).
echo "  format_review_scope: fallback:<sha> → 'clean incremental unavailable' (must NOT match 'Re-review of changes from')..."
result=$(format_review_scope "fallback:$SHA_OLD")
assert_contains "$result" "clean incremental unavailable" "fallback names cause"
assert_contains "$result" "evaluated full PR" "fallback discloses full-PR scope"
assert_contains "$result" '`abc1234`' "fallback cites short SHA"
if printf '%s' "$result" | grep -q "Re-review of changes from"; then
    echo "FAIL: fallback wording — fragment matches incremental wording 'Re-review of changes from' (regression)"
    echo "  got: $result"
    exit 1
fi

echo "  format_review_scope: bogus → fail-fast (rc=1 + stderr diagnostic)..."
format_review_scope "bogus" 2>/dev/null
if [ "$?" -eq 0 ]; then
    echo "FAIL: bogus scope — format_review_scope returned 0 (silent degrade)"
    exit 1
fi
err=$(format_review_scope "bogus" 2>&1 >/dev/null)
if ! printf '%s' "$err" | grep -q "unknown scope"; then
    echo "FAIL: bogus scope — stderr missing 'unknown scope'; got: $err"
    exit 1
fi

# ===== compute_review_scope (worker seam) — unchanged =====
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
assert_scope "$(compute_review_scope true "abc1234567" true)" "whole" "force takes precedence over sha+fallback"

echo "  compute_review_scope: no force + no sha → 'first'..."
assert_scope "$(compute_review_scope false "" false)" "first" "no-sha → first"

echo "  compute_review_scope: no force + sha + fallback=false → 'incremental:<sha>'..."
assert_scope "$(compute_review_scope false "abc1234567" false)" "incremental:abc1234567" "incremental path"

echo "  compute_review_scope: no force + sha + fallback=true → 'fallback:<sha>'..."
# The original silent-fallback bug: USED_FALLBACK=true previously got
# framed as incremental in the banner. Pin against regression.
assert_scope "$(compute_review_scope false "abc1234567" true)" "fallback:abc1234567" "fallback path — must not be misframed as incremental"

# ===== classify_just_test_outcome (worker seam) — unchanged =====
TMPLOG=$(mktemp)
trap 'rm -f "$TMPLOG"' EXIT

assert_classify() {
    local test_exit="$1" log_content="$2" expected_ran="$3" expected_summary="$4" desc="$5"
    printf '%s' "$log_content" > "$TMPLOG"
    local got_ran got_summary
    IFS=$'\t' read -r got_ran got_summary < <(classify_just_test_outcome "$test_exit" "$TMPLOG" "30m")
    if [ "$got_ran" != "$expected_ran" ] || [ "$got_summary" != "$expected_summary" ]; then
        echo "FAIL: classify($test_exit, ...) — $desc"
        echo "  expected: ($expected_ran, $expected_summary)"
        echo "  got:      ($got_ran, $got_summary)"
        exit 1
    fi
}

echo "  classify: exit 0 → PASSED..."
assert_classify 0 "" "true" "PASSED" "tests ran and passed"

echo "  classify: exit 124 → TIMED OUT..."
assert_classify 124 "" "true" "TIMED OUT (>30m)" "timeout expired"

echo "  classify: exit 127 + 'Recipe failed' → not run (cmd-not-found inside)..."
assert_classify 127 "sh: 1: pytest: not found
error: Recipe \`test\` failed on line 2 with exit code 127" \
    "false" "not run (recipe ran but command-not-found inside, exit 127)" \
    "recipe invoked, command inside missing (e.g. pytest)"

echo "  classify: exit 1 + 'Recipe failed' → FAILED (exit 1, real test failure)..."
assert_classify 1 "FAILED tests/test_foo.py::test_bar - assert 1 == 2
error: Recipe \`test\` failed on line 2 with exit code 1" \
    "true" "FAILED (exit 1)" \
    "recipe ran, test framework returned failure"

echo "  classify: exit 1 + no 'Recipe failed' line ('No justfile found') → not run (pre-recipe)..."
assert_classify 1 "error: No justfile found" \
    "false" "not run (just pre-recipe failure: see test-results below)" \
    "just couldn't discover any justfile — pre-recipe failure"

echo "  classify: exit 1 + no 'Recipe failed' line ('does not contain recipe') → not run (pre-recipe)..."
assert_classify 1 "error: Justfile does not contain recipe \`test\`" \
    "false" "not run (just pre-recipe failure: see test-results below)" \
    "missing test recipe — pre-recipe failure, no Recipe-failed line"

echo "  classify: exit 1 + no 'Recipe failed' line ('Failed to write recipe to /tmp/just-…') → not run (pre-recipe)..."
assert_classify 1 "error: Failed to write recipe to /tmp/just-AbC123/test" \
    "false" "not run (just pre-recipe failure: see test-results below)" \
    "just-internal infra error (e.g. /tmp not writable) — must not be misclassified as FAILED"

echo "  classify: exit 2 + 'Recipe failed' → FAILED (exit 2, e.g. pytest collection error)..."
assert_classify 2 "ERROR collecting tests/test_foo.py
error: Recipe \`test\` failed on line 2 with exit code 2" \
    "true" "FAILED (exit 2)" \
    "non-special non-zero exit, recipe ran"

echo "  classify: exit 1 + empty log → not run (defaults to safe pre-recipe class)..."
assert_classify 1 "" "false" "not run (just pre-recipe failure: see test-results below)" \
    "no 'Recipe failed' line in empty log → safe default to pre-recipe class"

echo "  classify: exit 1 + missing log file → not run (defaults to safe pre-recipe class)..."
GHOST_LOG="$TMPLOG.ghost"
rm -f "$GHOST_LOG"
IFS=$'\t' read -r got_ran got_summary < <(classify_just_test_outcome 1 "$GHOST_LOG" "30m")
if [ "$got_ran" != "false" ] || [ "$got_summary" != "not run (just pre-recipe failure: see test-results below)" ]; then
    echo "FAIL: classify with missing log file — expected (false, 'not run (just pre-recipe...)'), got ($got_ran, $got_summary)"
    exit 1
fi

echo "  PASS (join 1/2/3 + empty fail-fast + worst-case order + KID-only/diff-alone fence + 4 scope-fragment mappings + bogus-scope fail-fast + 5 compute_review_scope + 9 classify scenarios)"
