#!/bin/bash
# Smoke for stage_prior_reviews (lib/run-dir.sh).
#
# Bug-Class-Recurrence detection is the headline feature of PR #15, but
# it depends entirely on this function returning the right concatenation
# of prior aggregator outputs. A bad `find` glob, missing self-exclusion,
# wrong empty-file filter, or other-PR cross-contamination would silently
# disable or distort recurrence detection without tripping any existing
# smoke. Lock down the five branches:
#
#   1. No runs at all → empty output (first review on PR)
#   2. Only the current run → empty output (self-exclusion works)
#   3. Two prior runs + current → both prior outputs in chronological order,
#      current excluded, headers correct
#   4. Prior run dir exists but aggregator/output.md missing or empty
#      (aborted run that never reached aggregator) → skipped
#   5. Run dirs from a DIFFERENT PR or DIFFERENT repo sharing the slug
#      prefix → not included (slug+pr glob filters them)
#
# Sources lib/run-dir.sh directly so the test exercises the same function
# the worker calls. Runs in a private tmpdir.

set -uo pipefail

TMPDIR=$(mktemp -d -t prior-reviews-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

# Helper: create a run dir with a given timestamp suffix and aggregator output.
make_run() {
    local slug="$1" pr="$2" ts="$3" sha7="$4" body="$5"
    local rd="$TMPDIR/state/runs/${slug}__${pr}__${ts}__${sha7}"
    mkdir -p "$rd/agents/aggregator"
    if [ -n "$body" ]; then
        printf '%s' "$body" > "$rd/agents/aggregator/output.md"
    fi
    echo "$rd"
}

REPO_SLUG="cncorp_plow"
PR=523

# ---- scenario 1: no runs at all ----
echo "  scenario 1: no runs → empty output..."
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$TMPDIR/state/runs/missing")
if [ -n "$result" ]; then
    echo "FAIL: expected empty, got: $result"
    exit 1
fi

# ---- scenario 2: only the current run → self-excluded ----
echo "  scenario 2: only current run → empty (self-excluded)..."
current=$(make_run "$REPO_SLUG" "$PR" "20260429T120000000Z" "aaaaaaa" "## current review (should be excluded)")
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if [ -n "$result" ]; then
    echo "FAIL: current run was not excluded:"
    echo "$result"
    exit 1
fi

# ---- scenario 3: two prior runs + current → chronological, current excluded ----
echo "  scenario 3: two prior runs + current → both prior, chronological, current excluded..."
make_run "$REPO_SLUG" "$PR" "20260429T100000000Z" "1111111" "## review one body" >/dev/null
make_run "$REPO_SLUG" "$PR" "20260429T110000000Z" "2222222" "## review two body" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")

if ! echo "$result" | grep -q "review one body"; then
    echo "FAIL: scenario 3 — first prior review missing"
    echo "$result"
    exit 1
fi
if ! echo "$result" | grep -q "review two body"; then
    echo "FAIL: scenario 3 — second prior review missing"
    echo "$result"
    exit 1
fi
if echo "$result" | grep -q "current review (should be excluded)"; then
    echo "FAIL: scenario 3 — current review leaked through"
    echo "$result"
    exit 1
fi
# Chronological: review one's marker appears before review two's marker.
one_pos=$(echo "$result" | grep -n "T100000000Z" | head -1 | cut -d: -f1)
two_pos=$(echo "$result" | grep -n "T110000000Z" | head -1 | cut -d: -f1)
if [ -z "$one_pos" ] || [ -z "$two_pos" ] || [ "$one_pos" -ge "$two_pos" ]; then
    echo "FAIL: scenario 3 — prior reviews not in chronological order (one_pos=$one_pos, two_pos=$two_pos)"
    echo "$result"
    exit 1
fi

# ---- scenario 4: aborted run with no aggregator output → skipped ----
echo "  scenario 4: aborted run (empty aggregator output) → skipped..."
aborted_rd="$TMPDIR/state/runs/${REPO_SLUG}__${PR}__20260429T090000000Z__3333333"
mkdir -p "$aborted_rd/agents/aggregator"
# No output.md written — aborted before aggregator step.
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
# The result still has reviews 1 and 2 from scenario 3 (didn't tear down).
if echo "$result" | grep -q "T090000000Z"; then
    echo "FAIL: scenario 4 — aborted run with missing output.md was not skipped"
    echo "$result"
    exit 1
fi
# Also test: aggregator output.md exists but is empty.
empty_rd="$TMPDIR/state/runs/${REPO_SLUG}__${PR}__20260429T080000000Z__4444444"
mkdir -p "$empty_rd/agents/aggregator"
: > "$empty_rd/agents/aggregator/output.md"
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "T080000000Z"; then
    echo "FAIL: scenario 4 — run with zero-byte aggregator output was not skipped"
    echo "$result"
    exit 1
fi

# ---- scenario 5: different PR / repo slug → not included ----
echo "  scenario 5: runs from other PR / repo slug → filtered out..."
make_run "$REPO_SLUG" "999" "20260429T120000000Z" "5555555" "## OTHER PR review (should NOT appear)" >/dev/null
make_run "other_repo" "$PR" "20260429T120000000Z" "6666666" "## OTHER REPO review (should NOT appear)" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "OTHER PR review"; then
    echo "FAIL: scenario 5 — run from a different PR leaked through"
    echo "$result"
    exit 1
fi
if echo "$result" | grep -q "OTHER REPO review"; then
    echo "FAIL: scenario 5 — run from a different repo leaked through"
    echo "$result"
    exit 1
fi

echo "  PASS (5 scenarios: no-runs, self-excluded, chronological-prior, aborted-skipped, foreign-pr-filtered)"
