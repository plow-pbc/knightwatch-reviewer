#!/bin/bash
# Smoke for compute_loc_trend (lib/loc-trend.sh) and
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

# Pin REVIEWER_LIB_DIR to the checkout's lib/ so lib/loc-trend.sh
# sources its run-dir.sh dependency from the checkout, not from an
# inherited installed copy that may lag behind (e.g. missing
# is_run_author_visible / author_visible_rounds). Without this pin
# the smoke would test the installed helpers instead of the ones
# under review — silent false-pass.
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

# Source the loc-trend lib directly. lib/loc-trend.sh handles its own
# run-dir.sh dependency (single owner of is_run_author_visible /
# author_visible_rounds), so the smoke gets both compute_loc_trend and
# author_visible_rounds without going through the orchestrator's
# bootstrap.
. "$PROJECT_ROOT/lib/loc-trend.sh"

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

# Test 10: GROWING from a reachable_zero baseline. First round's diff
# vs base is empty (e.g. round was rebase-only or already-merged work);
# later round adds real code. The pre-typed-states classifier silently
# called this STABLE because first_round_adds==0 short-circuited the
# ratio. With explicit per-row states the trajectory must be GROWING.
# Closes the round-4 BCR(a) bug.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
# Use BASE_SHA itself as the first reviewed round → reachable_zero
# (cat-file -e succeeds, BASE...BASE diff is empty).
RUN_ZERO_BASELINE="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${BASE_SHA:0:7}"
mkdir -p "$RUN_ZERO_BASELINE"
jq -n --arg sha "$BASE_SHA" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_ZERO_BASELINE/meta.json"
# Current = SHA2 (50 adds vs base) → first=reachable_zero, last=numeric.
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA2" > "$OUT"
grep -qE 'Trajectory:.*GROWING' "$OUT" || {
    echo "FAIL: expected GROWING from zero baseline (first=reachable_zero, last=numeric)"
    cat "$OUT"
    exit 1
}
grep -qE 'Trajectory:.*STABLE' "$OUT" && {
    echo "FAIL: zero-baseline + later adds silently classified as STABLE — BCR(a) regressed"
    cat "$OUT"
    exit 1
}

# Test 11: all rounds reachable_zero → STABLE (legitimately stable at
# zero). Distinct from UNKNOWN — every SHA is reachable, the diff just
# happens to be empty (e.g. nothing added relative to base).
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_ALL_ZERO="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${BASE_SHA:0:7}"
mkdir -p "$RUN_ALL_ZERO"
jq -n --arg sha "$BASE_SHA" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_ALL_ZERO/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$BASE_SHA" > "$OUT"
grep -qE 'Trajectory:.*STABLE' "$OUT" || {
    echo "FAIL: expected STABLE for all-reachable-zero rounds"
    cat "$OUT"
    exit 1
}
grep -qE 'Trajectory:.*UNKNOWN' "$OUT" && {
    echo "FAIL: all-reachable-zero misclassified as UNKNOWN — typed state collapsed unavailable + reachable_zero"
    cat "$OUT"
    exit 1
}

# Test 12: display column renders "(zero diff)" for reachable_zero
# rounds, NOT "(sha not in local history)". Closes the round-4 BCR(b)
# display bug — the prior implementation rendered any empty shortstat
# as "(sha not in local history)" regardless of whether the SHA was
# evicted or just had a legitimate zero-diff.
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_DISPLAY="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${BASE_SHA:0:7}"
mkdir -p "$RUN_DISPLAY"
jq -n --arg sha "$BASE_SHA" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_DISPLAY/meta.json"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$BASE_SHA" > "$OUT"
grep -qF '(zero diff)' "$OUT" || {
    echo "FAIL: expected display '(zero diff)' for reachable_zero round"
    cat "$OUT"
    exit 1
}
grep -qF '(sha not in local history)' "$OUT" && {
    echo "FAIL: reachable_zero round rendered as '(sha not in local history)' — BCR(b) display conflation regressed"
    cat "$OUT"
    exit 1
}

# Test 13: deletion-only round (adds=0, dels>0) classifies as
# deletion_only, NOT reachable_zero. Display renders "(0 adds, N dels)";
# trajectory math still treats the row as 0 adds (the loop-breaker
# cares about additions; deletions are good). Closes round-6 BCR(F1.b).
#
# Build a branch where the only diff vs base is a `git rm` of seed.txt.
# Use a fresh branch so we don't perturb main. seed.txt has 1 line so
# dels=1 vs base.
git -C "$REPO" checkout -q -b deletion-only-branch "$BASE_SHA"
git -C "$REPO" rm -q seed.txt
git -C "$REPO" commit -qm "delete-only round"
SHA_DEL=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_DEL="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA_DEL:0:7}"
mkdir -p "$RUN_DEL"
jq -n --arg sha "$SHA_DEL" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_DEL/meta.json"
# Current = SHA_DEL too — last_state=deletion_only, classifier folds it
# to reachable_zero → STABLE. The display assertion below is the load-
# bearing check.
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA_DEL" > "$OUT"
grep -qF '(0 adds, 1 dels)' "$OUT" || {
    echo "FAIL: expected display '(0 adds, 1 dels)' for deletion-only round"
    cat "$OUT"
    exit 1
}
grep -qF '(zero diff)' "$OUT" && {
    echo "FAIL: deletion-only round rendered as '(zero diff)' — F1.b display conflation regressed"
    cat "$OUT"
    exit 1
}
# Trajectory math: deletion_only row counts as 0 adds for ratio
# purposes. With first=last=deletion_only, classifier resolves to STABLE.
grep -qE 'Trajectory:.*STABLE' "$OUT" || {
    echo "FAIL: deletion-only first AND last round should resolve to STABLE (deletion_only folds to 0-adds for trajectory)"
    cat "$OUT"
    exit 1
}

# Trajectory: GROWING from a deletion-only baseline → numeric current
# round. First round dels everything; current round adds code. Closes
# the symmetric case to Test 10 (zero-diff baseline → GROWING).
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA2" > "$OUT"
grep -qE 'Trajectory:.*GROWING' "$OUT" || {
    echo "FAIL: deletion-only baseline + numeric current should resolve to GROWING"
    cat "$OUT"
    exit 1
}

# Test 14: failed `git diff --numstat` exit code on a reachable SHA
# classifies as unavailable, NOT reachable_zero. Closes round-6 BCR(F1.a).
# Stub `git` on PATH so cat-file -e still succeeds (delegating to real
# git) but `diff --numstat` exits non-zero with empty stdout — the
# realistic failure mode for corrupted history / partial fetch.
STUB_DIR="$TMPDIR/stub-bin"
mkdir -p "$STUB_DIR"
REAL_GIT=$(command -v git)
cat > "$STUB_DIR/git" <<STUB_EOF
#!/bin/bash
# Test stub: pass through to real git, except diff --numstat exits 1
# with empty stdout. Mimics a corrupted-history / partial-fetch
# failure where cat-file -e still succeeds.
REAL_GIT='$REAL_GIT'
STUB_EOF
cat >> "$STUB_DIR/git" <<'STUB_EOF'
for arg in "$@"; do
    if [ "$arg" = "--numstat" ]; then
        exit 1
    fi
done
exec "$REAL_GIT" "$@"
STUB_EOF
chmod +x "$STUB_DIR/git"
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
RUN_FAIL="$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__${SHA1:0:7}"
mkdir -p "$RUN_FAIL"
jq -n --arg sha "$SHA1" --arg ts "2026-05-01T00:00:00Z" \
    '{status:"completed", sha:$sha, started_at:$ts}' > "$RUN_FAIL/meta.json"
PATH="$STUB_DIR:$PATH" compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" "$CURRENT_RUN" "$SHA1" > "$OUT"
# UNKNOWN supersedes — prior round's diff failed; we cannot trust the row.
grep -qE 'Trajectory:.*UNKNOWN' "$OUT" || {
    echo "FAIL: failed 'git diff --numstat' on reachable SHA should classify as unavailable -> UNKNOWN trajectory"
    cat "$OUT"
    exit 1
}
grep -qF '(sha not in local history)' "$OUT" || {
    echo "FAIL: failed-numstat row should display '(sha not in local history)' (folded into unavailable)"
    cat "$OUT"
    exit 1
}
grep -qF '(zero diff)' "$OUT" && {
    echo "FAIL: failed-numstat row silently rendered as '(zero diff)' — F1.a regressed"
    cat "$OUT"
    exit 1
}

echo "  PASS"
