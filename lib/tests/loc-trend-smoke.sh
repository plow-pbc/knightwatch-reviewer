#!/bin/bash
# Smoke for compute_loc_trend (lib/review-one-pr.sh) and
# author_visible_rounds (lib/run-dir.sh).
#
# Contracts:
#   1. Empty runs/ dir (first review, no prior rounds) → emits header
#      noting it's the first review, plus the current round's row.
#   2. N>=1 prior author-visible runs → emits a table with one row per
#      author-visible run + the current round, sorted by timestamp,
#      each row carrying base..head shortstat.
#   3. Trajectory line classifies GROWING / STABLE / SHRINKING based on
#      ratio between first and last round's additions.
#   4. Runs without `posted_at` AND status != "completed" (in-flight or
#      aborted) are excluded from the trajectory table — same predicate
#      stage_prior_reviews uses (single owner via is_run_author_visible).
#   5. meta.json `.sha` wins over the run-dir name's SHA suffix —
#      regression fence for the BCR class flagged on PR #38 (round-2
#      review): the function must consume meta.json, not parse the
#      run-dir name.

set -uo pipefail

TMPDIR=$(mktemp -d -t loc-trend-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Pin REVIEWER_LIB_DIR to the checkout's lib/ before sourcing the
# orchestrator in --source-only mode. Without this, an inherited
# REVIEWER_LIB_DIR (set by a parent env or a prior test) would cause
# review-one-pr.sh to source the *installed* lib/run-dir.sh, which may
# lag behind the checkout (e.g. missing is_run_author_visible /
# author_visible_rounds). The smoke would then test the installed
# helpers instead of the ones under review — silent false-pass.
export REVIEWER_LIB_DIR="$PROJECT_ROOT/lib"

# Build a fake repo with two commits the function can shortstat against.
REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt && git -C "$REPO" commit -qm "seed"
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

# round1: small diff
seq 1 10 > "$REPO/round1.txt"
git -C "$REPO" add round1.txt && git -C "$REPO" commit -qm "round1"
SHA1=$(git -C "$REPO" rev-parse HEAD)

# round2: larger diff vs base (more insertions → GROWING trajectory)
seq 1 50 > "$REPO/round2.txt"
git -C "$REPO" add round2.txt && git -C "$REPO" commit -qm "round2"
SHA2=$(git -C "$REPO" rev-parse HEAD)

# Build a fake STATE_DIR/runs layout. Each fake run-dir gets a meta.json
# with status=completed AND .sha set so it passes is_run_author_visible
# AND author_visible_rounds picks the canonical SHA from meta (not the
# truncated suffix in the run-dir name).
STATE_DIR="$TMPDIR/state"
RUN1="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA1:0:7}"
RUN2="$STATE_DIR/runs/cncorp_plow__999__20260501T010000000Z__${SHA2:0:7}"
mkdir -p "$RUN1" "$RUN2"
jq -n --arg sha "$SHA1" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN1/meta.json"
jq -n --arg sha "$SHA2" --arg ts "2026-05-01T01:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN2/meta.json"

# Dummy current-run dir (doesn't need to exist on disk; the function only
# uses it for self-exclusion of the in-flight run).
CURRENT_RUN="$STATE_DIR/runs/cncorp_plow__999__99999999T999999999Z__current"
CURRENT_SHA="$SHA2"

OUT="$TMPDIR/loc-trend.md"

# Source review-one-pr.sh in --source-only mode so compute_loc_trend is
# defined without running the orchestrator's main body.
. "$PROJECT_ROOT/lib/review-one-pr.sh" --source-only

# Test 1: 2 prior author-visible runs + current round → 3 rows + GROWING
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$CURRENT_SHA" > "$OUT"
grep -q '^# LOC trend' "$OUT" || { echo "FAIL: missing header"; cat "$OUT"; exit 1; }
grep -qE 'Trajectory:.*GROWING' "$OUT" || { echo "FAIL: missing/wrong trajectory"; cat "$OUT"; exit 1; }
ROW_COUNT=$(grep -cE '^\| [0-9]+ \|' "$OUT")
[ "$ROW_COUNT" = "3" ] || { echo "FAIL: expected 3 table rows (2 prior + current), got $ROW_COUNT"; cat "$OUT"; exit 1; }

# Test 2: empty runs/ dir → first-review header + current-round row only
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$CURRENT_SHA" > "$OUT"
grep -qE 'first review|no prior rounds' "$OUT" || { echo "FAIL: missing first-review header"; cat "$OUT"; exit 1; }
ROW_COUNT=$(grep -cE '^\| [0-9]+ \|' "$OUT")
[ "$ROW_COUNT" = "1" ] || { echo "FAIL: expected 1 table row (current round only) on empty runs/, got $ROW_COUNT"; cat "$OUT"; exit 1; }

# Test 3: a non-author-visible run (status=started, no posted_at) is
# EXCLUDED from the trajectory table — same predicate as stage_prior_reviews.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_VISIBLE="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA1:0:7}"
RUN_INFLIGHT="$STATE_DIR/runs/cncorp_plow__999__20260501T010000000Z__${SHA2:0:7}"
mkdir -p "$RUN_VISIBLE" "$RUN_INFLIGHT"
jq -n --arg sha "$SHA1" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_VISIBLE/meta.json"
jq -n --arg sha "$SHA2" --arg ts "2026-05-01T01:00:00Z" \
    '{status:"started", sha:$sha, started_at:$ts}' > "$RUN_INFLIGHT/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$CURRENT_SHA" > "$OUT"
ROW_COUNT=$(grep -cE '^\| [0-9]+ \|' "$OUT")
# 1 author-visible prior + 1 current row = 2 rows; the started run is excluded
[ "$ROW_COUNT" = "2" ] || { echo "FAIL: expected 2 rows (1 prior visible + current), got $ROW_COUNT — non-author-visible run leaked through"; cat "$OUT"; exit 1; }

# Test 4: meta.json `.sha` wins over the run-dir name's SHA suffix.
# Regression fence for the BCR theme: compute_loc_trend / author_visible_rounds
# must consume meta.json (the canonical source the worker stamps), not parse
# the run-dir name. Set the run-dir-name suffix to a bogus 7-char string,
# put the real SHA in meta.json, and assert the table cites the meta SHA.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
BOGUS_SUFFIX="0000000"
RUN_META_WINS="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${BOGUS_SUFFIX}"
mkdir -p "$RUN_META_WINS"
jq -n --arg sha "$SHA1" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_META_WINS/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$CURRENT_SHA" > "$OUT"
grep -qF "${SHA1:0:7}" "$OUT" || {
    echo "FAIL: expected meta.json's SHA (${SHA1:0:7}) in table; meta.json was ignored in favor of run-dir-name parse"
    cat "$OUT"
    exit 1
}
grep -qF "$BOGUS_SUFFIX" "$OUT" && {
    echo "FAIL: bogus run-dir-name SHA ($BOGUS_SUFFIX) leaked into table — run-dir-name parse won over meta.json"
    cat "$OUT"
    exit 1
}

# Test 5: author_visible_rounds is callable directly (single-owner contract
# fence — anyone wiring up a new consumer of the round list should hit
# the helper, not re-implement the walk).
ROUNDS_OUT=$(author_visible_rounds "$STATE_DIR" "cncorp_plow" "999" "$CURRENT_RUN")
[ -n "$ROUNDS_OUT" ] || { echo "FAIL: author_visible_rounds emitted nothing"; exit 1; }
# One line: <ts>\t<sha>; sha column should be the meta.json SHA.
ROUNDS_SHA=$(printf '%s\n' "$ROUNDS_OUT" | head -1 | awk -F'\t' '{print $2}')
[ "$ROUNDS_SHA" = "$SHA1" ] || {
    echo "FAIL: author_visible_rounds returned SHA $ROUNDS_SHA, expected $SHA1 (meta.json)"
    exit 1
}

echo "  PASS"
