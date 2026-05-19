#!/usr/bin/env bash
# Smoke for finalize_meta_json (lib/run-dir.sh).
#
# This is the writer-side of the recurrence-detection pipeline:
# stage_prior_reviews keys off `posted_at` (with status="completed"
# legacy fallback), and finalize_meta_json is what guarantees the
# `posted_at` signal is persisted before worker exit even when the
# early-stamp call site failed serialization. The repair branch is the
# bug fix the bot called out as needing a regression fence.
#
# Locks down four branches:
#   1. Completed run with early posted_at present → preserve early
#      posted_at (do NOT overwrite with finalize ts), add finished_at +
#      status="completed".
#   2. Aborted run, GH_POSTED=false (typical worker abort before gh
#      pr comment) → add finished_at + status="aborted", do NOT add
#      posted_at (would falsely include in recurrence).
#   3. Aborted run, GH_POSTED=true, no posted_at on disk (the bug fix
#      the bot wanted fenced — gh succeeded but early stamp failed) →
#      add finished_at + status="aborted" + posted_at=finished_at.
#   4. Malformed input meta.json → return 1, no .tmp file leak.
#
# Hermetic: sources lib/run-dir.sh directly and invokes the helper with
# explicit args; no closure state needed.

set -uo pipefail

TMPDIR=$(mktemp -d -t finalize-meta-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"
. "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

EXIT_TS="2026-04-29T16:00:00Z"

# ---- scenario 1: early posted_at preserved, status flipped to completed ----
echo "  scenario 1: early posted_at preserved + status=completed..."
META="$TMPDIR/m1.json"
echo '{"posted_at":"early-2026-04-29T15:30:00Z","other":"x"}' > "$META"
if ! finalize_meta_json "$META" "$EXIT_TS" "completed" "true"; then
    echo "FAIL: scenario 1 — finalize returned non-zero on valid input"
    exit 1
fi
posted_at=$(jq -r '.posted_at' "$META")
assert_eq "$posted_at" "early-2026-04-29T15:30:00Z" "scenario 1 — early posted_at was clobbered"
status=$(jq -r '.status' "$META")
assert_eq "$status" "completed" "scenario 1 — status not stamped"
finished_at=$(jq -r '.finished_at' "$META")
assert_eq "$finished_at" "$EXIT_TS" "scenario 1 — finished_at not stamped"
other=$(jq -r '.other' "$META")
assert_eq "$other" "x" "scenario 1 — pre-existing fields lost"

# ---- scenario 2: aborted, no gh post, no posted_at gratuitously added ----
echo "  scenario 2: aborted run, GH_POSTED=false → no gratuitous posted_at..."
META="$TMPDIR/m2.json"
echo '{"other":"y"}' > "$META"
if ! finalize_meta_json "$META" "$EXIT_TS" "aborted" "false"; then
    echo "FAIL: scenario 2 — finalize returned non-zero"
    exit 1
fi
posted_at=$(jq -r '.posted_at // "none"' "$META")
assert_eq "$posted_at" "none" "scenario 2 — posted_at was added even though gh never posted"
status=$(jq -r '.status' "$META")
assert_eq "$status" "aborted" "scenario 2 — status not aborted"

# ---- scenario 3: REPAIR — gh did post but early stamp failed ----
echo "  scenario 3: GH_POSTED=true + missing posted_at → REPAIRED..."
META="$TMPDIR/m3.json"
echo '{"other":"z"}' > "$META"
if ! finalize_meta_json "$META" "$EXIT_TS" "aborted" "true"; then
    echo "FAIL: scenario 3 — finalize returned non-zero"
    exit 1
fi
posted_at=$(jq -r '.posted_at // "missing"' "$META")
assert_eq "$posted_at" "$EXIT_TS" "scenario 3 — posted_at not repaired (recurrence detector would undercount)"
status=$(jq -r '.status' "$META")
assert_eq "$status" "aborted" "scenario 3 — status not stamped"

# ---- scenario 4: malformed input meta → return 1, no tmp leak ----
echo "  scenario 4: malformed input meta → return 1, no tmp file leak..."
META="$TMPDIR/m4.json"
echo 'this is not json {{' > "$META"
if finalize_meta_json "$META" "$EXIT_TS" "completed" "false"; then
    echo "FAIL: scenario 4 — finalize returned 0 on malformed input"
    exit 1
fi
# Original (broken) meta should be untouched.
tmp_leaked=$([ -f "$META.tmp" ] && echo "leaked" || echo "")
assert_empty "$tmp_leaked" "scenario 4 — tmp file leaked after jq failure"
meta_content=$(cat "$META")
assert_eq "$meta_content" "this is not json {{" "scenario 4 — input meta was modified despite jq failure"

echo "  PASS (4 scenarios: early-posted_at-preserved, no-gratuitous-stamp, REPAIR-on-gh-posted, bad-input-returns-1)"
