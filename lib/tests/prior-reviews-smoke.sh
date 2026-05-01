#!/bin/bash
# Smoke for stage_prior_reviews (lib/run-dir.sh).
#
# Bug-Class-Recurrence detection depends entirely on this helper returning
# the right concatenation of prior aggregator outputs. A bad `find` glob,
# missing self-exclusion, wrong predicate, or other-PR cross-contamination
# would silently disable or distort recurrence detection without tripping
# any existing smoke. Lock down the branches:
#
#   1. No runs at all → empty output (first review on PR)
#   2. Only the current run → empty output (self-exclusion works)
#   3. Two prior posted runs + current → both prior outputs in chronological
#      order, current excluded, headers correct
#   4. Aborted run with no posted_at (worker exited before reaching gh
#      pr comment, e.g. missing VERDICT or aggregator empty) → skipped
#   4b. Run with no meta.json at all (in-flight or legacy pre-#11) → skipped
#   4c. Run with posted_at present but status=aborted — this is the case
#      where gh pr comment succeeded but state_set or finalize failed
#      afterward. The author DID see the review on GitHub, so the helper
#      MUST include it.
#   4d. Legacy run with status=completed but no posted_at — runs created
#      before this PR added the posted_at field. status only flips to
#      "completed" after state_set succeeds, which in production runs
#      after gh has posted, so status=completed reliably implies
#      "gh post succeeded" for any preserved run. Without this fallback,
#      the first-deploy rollout drops all pre-#15 history.
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

# Helper: create a run dir with a given timestamp suffix, aggregator
# output, status, and posted_at. Defaults model a typical posted+completed
# run (the production happy path). Pass status="aborted" + posted_at=""
# for "review never reached gh"; pass status="aborted" + posted_at="<ts>"
# for the rare "gh succeeded, state_set failed" case (review was
# delivered but lifecycle aborted afterward). Pass status="" to skip
# writing meta.json entirely (legacy/in-flight case).
make_run() {
    local slug="$1" pr="$2" ts="$3" sha7="$4" body="$5"
    local status="${6-completed}" posted_at="${7-2026-04-29T15:00:00Z}"
    local rd="$TMPDIR/state/runs/${slug}__${pr}__${ts}__${sha7}"
    mkdir -p "$rd/agents/aggregator"
    if [ -n "$body" ]; then
        printf '%s' "$body" > "$rd/agents/aggregator/output.md"
    fi
    if [ -n "$status" ]; then
        if [ -n "$posted_at" ]; then
            printf '{"status":"%s","posted_at":"%s"}' "$status" "$posted_at" > "$rd/meta.json"
        else
            printf '{"status":"%s"}' "$status" > "$rd/meta.json"
        fi
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

# ---- scenario 4: aborted run with no posted_at → skipped ----
# Worker exited before reaching gh pr comment (e.g. aggregator empty,
# VERDICT missing). Author never saw this review.
echo "  scenario 4: aborted run with no posted_at → skipped..."
make_run "$REPO_SLUG" "$PR" "20260429T090000000Z" "3333333" "## aborted review body — author never saw this" "aborted" "" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "aborted review body"; then
    echo "FAIL: scenario 4 — aborted run with no posted_at was not skipped"
    echo "$result"
    exit 1
fi

# ---- scenario 4b: missing meta.json → skipped (in-flight or legacy) ----
echo "  scenario 4b: run with no meta.json (in-flight or legacy) → skipped..."
make_run "$REPO_SLUG" "$PR" "20260429T080000000Z" "4444444" "## in-flight review body" "" "" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if echo "$result" | grep -q "in-flight review body"; then
    echo "FAIL: scenario 4b — run without meta.json was not skipped"
    echo "$result"
    exit 1
fi

# ---- scenario 4c: posted_at present but status=aborted → INCLUDED ----
# gh pr comment succeeded (author saw the review on GitHub) but state_set
# or finalize failed afterward. The earlier fix (key off status="completed")
# would have excluded this; keying off posted_at correctly includes it.
echo "  scenario 4c: posted_at present, status=aborted (gh-ok+state_set-failed) → INCLUDED..."
make_run "$REPO_SLUG" "$PR" "20260429T070000000Z" "5555555" "## review three body — author saw this even though state_set failed" "aborted" "2026-04-29T07:05:00Z" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if ! echo "$result" | grep -q "review three body"; then
    echo "FAIL: scenario 4c — posted-but-aborted review was not included; recurrence detector would undercount"
    echo "$result"
    exit 1
fi

# ---- scenario 4d: legacy run (status=completed, no posted_at) → INCLUDED ----
# Runs created before this PR landed have status=completed but no
# posted_at field. On first deploy, those legacy runs MUST count for
# recurrence detection — the long-running PRs this feature targets
# already have multi-review history. Predicate falls back to status when
# posted_at is missing.
echo "  scenario 4d: legacy run (status=completed, no posted_at) → INCLUDED..."
make_run "$REPO_SLUG" "$PR" "20260429T060000000Z" "6666666" "## review four body — legacy pre-#15 completed run" "completed" "" >/dev/null
result=$(stage_prior_reviews "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if ! echo "$result" | grep -q "review four body"; then
    echo "FAIL: scenario 4d — legacy completed run (no posted_at) was excluded; rollout drops history exactly where the feature is needed"
    echo "$result"
    exit 1
fi

# ---- scenario 5: different PR / repo slug → not included ----
echo "  scenario 5: runs from other PR / repo slug → filtered out..."
make_run "$REPO_SLUG" "999" "20260429T120000000Z" "9999999" "## OTHER PR review (should NOT appear)" >/dev/null
make_run "other_repo" "$PR" "20260429T120000000Z" "8888888" "## OTHER REPO review (should NOT appear)" >/dev/null
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

# ---- scenario 6: latest_author_visible_review returns latest body ----
# Single-seam regression fence for the round-7 BCR fix: PREV_BODY now
# sources from runs/ via this helper instead of state.json. The helper
# must return the LATEST author-visible review's body (last by timestamp),
# skip the current run, and skip non-author-visible runs.
#
# Layout reuses scenarios 3 + 4c's runs (already in $TMPDIR/state/runs):
#   T060000000Z (visible: legacy completed)        — review four body
#   T070000000Z (visible: posted+aborted)          — review three body  ← latest visible
#   T080000000Z (skip: no meta.json)
#   T090000000Z (skip: aborted, no posted_at)
#   T100000000Z (visible)                          — review one body
#   T110000000Z (visible)                          — review two body
#   T120000000Z (current, self-excluded)
#
# Wait — scenario 3 made T100000000Z and T110000000Z, both completed. So
# the LATEST visible is T110000000Z = "review two body". Verify that.
echo "  scenario 6: latest_author_visible_review returns the most recent author-visible body..."
result=$(latest_author_visible_review "$TMPDIR/state" "$REPO_SLUG" "$PR" "$current")
if ! echo "$result" | grep -q "review two body"; then
    echo "FAIL: scenario 6 — latest body should be 'review two body' (T110000000Z), got:"
    echo "$result"
    exit 1
fi
# Must not include earlier rounds' bodies (only the LATEST is returned —
# unlike stage_prior_reviews which concatenates all).
if echo "$result" | grep -q "review one body"; then
    echo "FAIL: scenario 6 — earlier round leaked through; helper should return ONLY the latest"
    echo "$result"
    exit 1
fi

# ---- scenario 7: no prior author-visible runs → empty output ----
# First review on the PR. previous-review.md staging keys off [ -s file ],
# so empty output here flows through as "no previous-review.md content"
# and the momentum gate correctly skips.
echo "  scenario 7: latest_author_visible_review with no prior runs → empty..."
result=$(latest_author_visible_review "$TMPDIR/state" "$REPO_SLUG" "999999" "$current")
if [ -n "$result" ]; then
    echo "FAIL: scenario 7 — expected empty for PR with no prior runs, got: $result"
    exit 1
fi

# ---- scenario 8: latest_author_visible_review_sha — reviewed_sha precedence ----
# Round-8 BCR fence: KNOWN_SHA now reads from runs/ via this helper instead
# of state.json. The selected run's meta.json wins, and within meta.json,
# .reviewed_sha (post-checkout HEAD the worker actually evaluated) wins
# over .sha (orchestrator-enumerated, can drift). All three of body/sha/
# approved must point at the SAME run (latest author-visible) — the
# helper trio shares _latest_author_visible_run_dir to enforce that.
echo "  scenario 8: latest_author_visible_review_sha — uses .reviewed_sha when present..."
SHA_PR=601
shaq_current=$(make_run "$REPO_SLUG" "$SHA_PR" "20260429T120000000Z" "ccccccc" "## current run for sha test")
sha_run_a=$(make_run "$REPO_SLUG" "$SHA_PR" "20260429T100000000Z" "1111111" "## sha-test review one
VERDICT: COMMENT")
sha_run_b=$(make_run "$REPO_SLUG" "$SHA_PR" "20260429T110000000Z" "2222222" "## sha-test review two
VERDICT: APPROVE")
# Add reviewed_sha to the LATEST run's meta.json. .reviewed_sha must win
# over the run-dir-name suffix and over a hypothetical legacy .sha field.
jq --arg s "abcdef0123456789abcdef0123456789abcdef01" \
   '. + {reviewed_sha: $s, sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}' \
   "$sha_run_b/meta.json" > "$sha_run_b/meta.json.tmp" && mv "$sha_run_b/meta.json.tmp" "$sha_run_b/meta.json"
result=$(latest_author_visible_review_sha "$TMPDIR/state" "$REPO_SLUG" "$SHA_PR" "$shaq_current")
if [ "$result" != "abcdef0123456789abcdef0123456789abcdef01" ]; then
    echo "FAIL: scenario 8 — expected reviewed_sha (abcdef...01), got: $result"
    exit 1
fi

# ---- scenario 8b: latest_author_visible_review_sha — falls back to .sha ----
# Legacy run pre-dating the .reviewed_sha field. The fallback chain
# matches author_visible_rounds (the LOC trajectory consumer): both must
# project the same SHA from the same run.
echo "  scenario 8b: latest_author_visible_review_sha — falls back to .sha when reviewed_sha absent..."
SHA_PR2=602
shaq2_current=$(make_run "$REPO_SLUG" "$SHA_PR2" "20260429T120000000Z" "ddddddd" "## current run for sha-fallback test")
sha2_run=$(make_run "$REPO_SLUG" "$SHA_PR2" "20260429T100000000Z" "3333333" "## fallback review one
VERDICT: APPROVE")
# Only .sha, no .reviewed_sha.
jq '. + {sha: "fedcba9876543210fedcba9876543210fedcba98"}' \
   "$sha2_run/meta.json" > "$sha2_run/meta.json.tmp" && mv "$sha2_run/meta.json.tmp" "$sha2_run/meta.json"
result=$(latest_author_visible_review_sha "$TMPDIR/state" "$REPO_SLUG" "$SHA_PR2" "$shaq2_current")
if [ "$result" != "fedcba9876543210fedcba9876543210fedcba98" ]; then
    echo "FAIL: scenario 8b — expected .sha fallback (fedcba...98), got: $result"
    exit 1
fi

# ---- scenario 9: latest_author_visible_review_approved — VERDICT: APPROVE → true ----
echo "  scenario 9: latest_author_visible_review_approved — APPROVE → true..."
result=$(latest_author_visible_review_approved "$TMPDIR/state" "$REPO_SLUG" "$SHA_PR" "$shaq_current")
if [ "$result" != "true" ]; then
    echo "FAIL: scenario 9 — expected 'true' for VERDICT: APPROVE, got: '$result'"
    exit 1
fi

# ---- scenario 9b: latest_author_visible_review_approved — VERDICT: APPROVE — pending: ... → true ----
# Aggregator contract permits "VERDICT: APPROVE — pending: <items>". The
# helper anchors on `^VERDICT: APPROVE` so the pending suffix doesn't
# downgrade the verdict to "false" (a false-negative would force a
# spurious "not approved" handoff to the next round's prompt).
echo "  scenario 9b: latest_author_visible_review_approved — APPROVE with pending → true..."
APPR_PR=701
appr_current=$(make_run "$REPO_SLUG" "$APPR_PR" "20260429T120000000Z" "eeeeeee" "## current run for approve-pending test")
make_run "$REPO_SLUG" "$APPR_PR" "20260429T100000000Z" "4444444" \
    "## approve-pending review body
some text
VERDICT: APPROVE — pending: refactor X" >/dev/null
result=$(latest_author_visible_review_approved "$TMPDIR/state" "$REPO_SLUG" "$APPR_PR" "$appr_current")
if [ "$result" != "true" ]; then
    echo "FAIL: scenario 9b — expected 'true' for APPROVE with pending, got: '$result'"
    exit 1
fi

# ---- scenario 9c: latest_author_visible_review_approved — VERDICT: COMMENT → false ----
echo "  scenario 9c: latest_author_visible_review_approved — COMMENT → false..."
COMM_PR=702
comm_current=$(make_run "$REPO_SLUG" "$COMM_PR" "20260429T120000000Z" "fffffff" "## current run for comment test")
make_run "$REPO_SLUG" "$COMM_PR" "20260429T100000000Z" "5555556" \
    "## comment review body
findings here
VERDICT: COMMENT" >/dev/null
result=$(latest_author_visible_review_approved "$TMPDIR/state" "$REPO_SLUG" "$COMM_PR" "$comm_current")
if [ "$result" != "false" ]; then
    echo "FAIL: scenario 9c — expected 'false' for VERDICT: COMMENT, got: '$result'"
    exit 1
fi

# ---- scenario 10: no prior author-visible runs → sha + approved both empty ----
# Must mirror latest_author_visible_review's empty-on-first-review shape
# so the worker's "no prior round" branch is consistent across all three
# values. Empty PREV_APPROVED + empty KNOWN_SHA together drive
# REVIEW_SCOPE=first via compute_review_scope.
echo "  scenario 10: latest_author_visible_review_sha + _approved with no prior runs → empty..."
sha_result=$(latest_author_visible_review_sha "$TMPDIR/state" "$REPO_SLUG" "999998" "$current")
appr_result=$(latest_author_visible_review_approved "$TMPDIR/state" "$REPO_SLUG" "999998" "$current")
if [ -n "$sha_result" ]; then
    echo "FAIL: scenario 10 — sha helper expected empty for PR with no prior runs, got: '$sha_result'"
    exit 1
fi
if [ -n "$appr_result" ]; then
    echo "FAIL: scenario 10 — approved helper expected empty for PR with no prior runs, got: '$appr_result'"
    exit 1
fi

echo "  PASS (16 scenarios: no-runs, self-excluded, chronological-prior, aborted-skipped, no-meta-skipped, posted-but-aborted-INCLUDED, legacy-completed-no-posted-at-INCLUDED, foreign-pr-filtered, latest-author-visible-review, latest-empty-on-first-review, sha-reviewed_sha-precedence, sha-falls-back-to-sha, approved-APPROVE-true, approved-APPROVE-pending-true, approved-COMMENT-false, no-prior-empty)"
