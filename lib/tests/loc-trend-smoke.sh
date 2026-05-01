#!/bin/bash
# Smoke for compute_loc_trend (lib/review-one-pr.sh).
#
# Three contracts:
#   1. Empty runs/ dir (first review, no prior rounds) → emits header
#      noting it's the first review, no table rows.
#   2. N>1 prior runs → emits a table with one row per run, sorted by
#      timestamp, each row carrying base..head shortstat.
#   3. Trajectory line classifies GROWING / STABLE / SHRINKING based on
#      ratio between first and last round's additions.

set -uo pipefail

TMPDIR=$(mktemp -d -t loc-trend-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

# Build a fake STATE_DIR/runs layout.
STATE_DIR="$TMPDIR/state"
mkdir -p "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA1:0:7}"
mkdir -p "$STATE_DIR/runs/cncorp_plow__999__20260501T010000000Z__${SHA2:0:7}"

OUT="$TMPDIR/loc-trend.md"

# Source review-one-pr.sh in --source-only mode so compute_loc_trend is
# defined without running the orchestrator's main body.
. "$PROJECT_ROOT/lib/review-one-pr.sh" --source-only

# Test 1: 2 prior runs → table with 2 rows + GROWING trajectory
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" > "$OUT"
grep -q '^# LOC trend' "$OUT" || { echo "FAIL: missing header"; cat "$OUT"; exit 1; }
grep -qE 'Trajectory:.*GROWING' "$OUT" || { echo "FAIL: missing/wrong trajectory"; cat "$OUT"; exit 1; }
ROW_COUNT=$(grep -cE '^\| [0-9]+ \|' "$OUT")
[ "$ROW_COUNT" = "2" ] || { echo "FAIL: expected 2 table rows, got $ROW_COUNT"; cat "$OUT"; exit 1; }

# Test 2: empty runs/ dir → first-review header, no table rows
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" > "$OUT"
grep -qE 'first review|no prior rounds' "$OUT" || { echo "FAIL: missing first-review header"; cat "$OUT"; exit 1; }
ROW_COUNT=$(grep -cE '^\| [0-9]+ \|' "$OUT")
[ "$ROW_COUNT" = "0" ] || { echo "FAIL: expected 0 table rows on empty runs/, got $ROW_COUNT"; cat "$OUT"; exit 1; }

echo "  PASS"
