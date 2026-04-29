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
#   3. Two prior completed runs + current → both prior outputs in chronological
#      order, current excluded, headers correct
#   4. Aborted run (meta.json.status="aborted") with non-empty output.md
#      → skipped (this is the bug fix from the bot's round-2 review:
#      output.md exists from the moment codex starts writing, so the prior
#      [-s output.md] check would stage reviews that never landed in front
#      of the author after a downstream worker abort like missing VERDICT
#      or gh-post failure)
#   4b. Run dir with no meta.json at all (in-flight or legacy) → skipped
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

# Helper: create a run dir with a given timestamp suffix, aggregator output,
# and meta.json status. Status defaults to "completed" (the typical
# post-finalize state); pass "aborted" to simulate a failed run, or empty
# string to skip writing meta.json entirely (legacy/in-flight case).
make_run() {
    local slug="$1" pr="$2" ts="$3" sha7="$4" body="$5" status="${6-completed}"
    local rd="$TMPDIR/state/runs/${slug}__${pr}__${ts}__${sha7}"
    mkdir -p "$rd/agents/aggregator"
    if [ -n "$body" ]; then
        printf '%s' "$body" > "$rd/agents/aggregator/output.md"
    fi
    if [ -n "$status" ]; then
        printf '{"status":"%s"}' "$status" > "$rd/meta.json"
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

# ---- scenario 4: aborted run (status=aborted) → skipped ----
# Even with non-empty output.md, an aborted run never landed in front of
# the author and must not contribute to recurrence detection.
echo "  scenario 4: aborted run (status=aborted) with output.md → skipped..."
make_run "$REPO_SLUG" "$PR" "20260429T090000000Z" "3333333" "## aborted review body — author never saw this" "aborted" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "aborted review body"; then
    echo "FAIL: scenario 4 — run with status=aborted was not skipped"
    echo "$result"
    exit 1
fi

# ---- scenario 4b: missing meta.json → skipped (in-flight or legacy) ----
echo "  scenario 4b: run with no meta.json (in-flight or legacy) → skipped..."
make_run "$REPO_SLUG" "$PR" "20260429T080000000Z" "4444444" "## in-flight review body" "" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "in-flight review body"; then
    echo "FAIL: scenario 4b — run without meta.json was not skipped"
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

echo "  PASS (6 scenarios: no-runs, self-excluded, chronological-prior, aborted-skipped, no-meta-skipped, foreign-pr-filtered)"
