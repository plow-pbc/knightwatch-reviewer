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
#      ratio between first and last round's additions, OR UNKNOWN when
#      a prior round's SHA isn't in local history (rebase/force-push).
#   4. Runs without `posted_at` AND status != "completed" (in-flight or
#      aborted) are excluded from the trajectory table — same predicate
#      stage_prior_reviews uses (single owner via is_run_author_visible).
#   5. meta.json `.sha` wins over the run-dir name's SHA suffix —
#      regression fence for the BCR class flagged on PR #38 (round-2
#      review): the function must consume meta.json, not parse the
#      run-dir name.
#   6. meta.json `.reviewed_sha` (post-checkout HEAD) wins over `.sha`
#      (orchestrator-enumerated PR_SHA) when both are present —
#      regression fence for the BCR class flagged on PR #38 (round-3
#      review): an enumeration race must not anchor the trajectory to
#      a SHA the worker never evaluated.

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

# Test 6: STABLE trajectory — first round and last round have similar
# additions counts (ratio in [0.66, 1.5]). Use SHA1 (10 adds vs base) as
# the only prior, and SHA1 again as the current round → ratio 1.0 →
# STABLE.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_STABLE_PRIOR="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA1:0:7}"
mkdir -p "$RUN_STABLE_PRIOR"
jq -n --arg sha "$SHA1" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_STABLE_PRIOR/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA1" > "$OUT"
grep -qE 'Trajectory:.*STABLE' "$OUT" || {
    echo "FAIL: expected STABLE trajectory (round1=10 adds, current=10 adds)"
    cat "$OUT"
    exit 1
}

# Test 7: SHRINKING trajectory — first round large, last round small
# (ratio ≤ 0.66). Build a "fat" commit on top of round2; the fat round's
# adds-vs-base = 10 (round1) + 50 (round2) + 100 (fat) = 160 lines.
# Current = SHA1 (10 adds). Ratio 10/160 ≈ 0.06 → SHRINKING.
seq 1 100 > "$REPO/round_fat.txt"
git -C "$REPO" add round_fat.txt && git -C "$REPO" commit -qm "fat-round"
SHA_FAT=$(git -C "$REPO" rev-parse HEAD)
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_FAT_PRIOR="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA_FAT:0:7}"
mkdir -p "$RUN_FAT_PRIOR"
jq -n --arg sha "$SHA_FAT" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_FAT_PRIOR/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA1" > "$OUT"
grep -qE 'Trajectory:.*SHRINKING' "$OUT" || {
    echo "FAIL: expected SHRINKING trajectory (prior=160 adds, current=10 adds)"
    cat "$OUT"
    exit 1
}

# Test 8: UNKNOWN trajectory — a prior round's SHA isn't reachable in
# local history (rebase / force-push / shallow clone evicted it). Silent
# fall-through to STABLE here was the BCR class flagged on PR #38 round-3.
# Use a 40-hex string that's never been an object in the test repo.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
PHANTOM_SHA="deadbeef00000000000000000000000000000000"
RUN_PHANTOM="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${PHANTOM_SHA:0:7}"
mkdir -p "$RUN_PHANTOM"
jq -n --arg sha "$PHANTOM_SHA" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_PHANTOM/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA1" > "$OUT"
grep -qE 'Trajectory:.*UNKNOWN' "$OUT" || {
    echo "FAIL: expected UNKNOWN trajectory (prior round's SHA not in local history)"
    cat "$OUT"
    exit 1
}
grep -qE 'Trajectory:.*STABLE' "$OUT" && {
    echo "FAIL: phantom-SHA round silently classified as STABLE — UNKNOWN should supersede"
    cat "$OUT"
    exit 1
}

# Test 9: .reviewed_sha wins over .sha when both are present in meta.json
# — regression fence for the round-3 BCR finding. The orchestrator stamps
# .sha at meta-write time (PR_SHA, pre-checkout) and later stamps
# .reviewed_sha (post-checkout HEAD). Downstream consumers MUST prefer
# .reviewed_sha so an enumeration race doesn't anchor the trajectory to
# a SHA the worker never actually evaluated.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_BOTH="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__0000000"
mkdir -p "$RUN_BOTH"
jq -n --arg reviewed_sha "$SHA1" --arg sha "$PHANTOM_SHA" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, reviewed_sha:$reviewed_sha, started_at:$ts}' > "$RUN_BOTH/meta.json"
ROUNDS_OUT=$(author_visible_rounds "$STATE_DIR" "cncorp_plow" "999" "$CURRENT_RUN")
ROUNDS_SHA=$(printf '%s\n' "$ROUNDS_OUT" | head -1 | awk -F'\t' '{print $2}')
[ "$ROUNDS_SHA" = "$SHA1" ] || {
    echo "FAIL: author_visible_rounds returned $ROUNDS_SHA, expected $SHA1 (.reviewed_sha) — .sha won over .reviewed_sha"
    exit 1
}

echo "  PASS"
