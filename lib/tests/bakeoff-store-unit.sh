#!/usr/bin/env bash
# Unit tests for lib/bakeoff-store.sh — schema bootstrap, upserts, watermark.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../bakeoff-store.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
DB="$TMP/bakeoff.db"

echo "=== bakeoff-store unit tests ==="

echo "  init: schema bootstraps cleanly..."
store_init "$DB"
sqlite3 "$DB" '.schema specialist_runs' | grep -q 'PRIMARY KEY' || { echo "FAIL: missing PK"; exit 1; }
sqlite3 "$DB" '.schema walks' | grep -q 'PRIMARY KEY' || { echo "FAIL: walks PK"; exit 1; }

echo "  init: idempotent (re-running does not error or wipe data)..."
store_init "$DB"
upsert_specialist_run "$DB" srosro/repo 100 tests 7 2026-05-01T00:00:00Z
store_init "$DB"
COUNT=$(sqlite3 "$DB" "SELECT COUNT(*) FROM specialist_runs;")
[ "$COUNT" = "1" ] || { echo "FAIL: re-init wiped row (count=$COUNT)"; exit 1; }

echo "  upsert_specialist_run: inserts new row with default flags 0..."
upsert_specialist_run "$DB" srosro/repo 200 security 8 2026-05-02T00:00:00Z
ROW=$(sqlite3 "$DB" "SELECT specialist, published, applied, loved_positive, critiqued FROM specialist_runs WHERE comment_id=200 AND specialist='security';")
[ "$ROW" = "security|0|0|0|0" ] || { echo "FAIL: defaults wrong: $ROW"; exit 1; }

echo "  upsert_specialist_run: re-upsert preserves flag columns..."
mark_published "$DB" srosro/repo 200 security
mark_applied "$DB" srosro/repo 200 security
upsert_specialist_run "$DB" srosro/repo 200 security 8 2026-05-02T00:00:00Z
ROW=$(sqlite3 "$DB" "SELECT published, applied FROM specialist_runs WHERE comment_id=200 AND specialist='security';")
[ "$ROW" = "1|1" ] || { echo "FAIL: rewalk wiped flags: $ROW"; exit 1; }

echo "  mark_loved_positive: idempotent (bool, not count)..."
mark_loved_positive "$DB" srosro/repo 200 security
mark_loved_positive "$DB" srosro/repo 200 security
ROW=$(sqlite3 "$DB" "SELECT loved_positive FROM specialist_runs WHERE comment_id=200 AND specialist='security';")
[ "$ROW" = "1" ] || { echo "FAIL: loved_positive not bool: $ROW"; exit 1; }

echo "  watermark: get returns empty when unset, set+get round-trips..."
EMPTY=$(get_walk_watermark "$DB" srosro/repo)
[ -z "$EMPTY" ] || { echo "FAIL: empty watermark not empty: '$EMPTY'"; exit 1; }
set_walk_watermark "$DB" srosro/repo 2026-05-06T12:00:00Z
WM=$(get_walk_watermark "$DB" srosro/repo)
[ "$WM" = "2026-05-06T12:00:00Z" ] || { echo "FAIL: watermark round-trip: $WM"; exit 1; }

echo "  watermark: set is upsert (overwrites prior value)..."
set_walk_watermark "$DB" srosro/repo 2026-05-07T00:00:00Z
WM=$(get_walk_watermark "$DB" srosro/repo)
[ "$WM" = "2026-05-07T00:00:00Z" ] || { echo "FAIL: watermark overwrite: $WM"; exit 1; }

# query_window_aggregates uses a fresh DB so prior tests' rows don't pollute counts.
DB2="$TMP/bakeoff2.db"

echo "  query_window_aggregates: empty store → empty output..."
store_init "$DB2"
OUT=$(query_window_aggregates "$DB2" "2026-01-01T00:00:00Z")
[ -z "$OUT" ] || { echo "FAIL: empty store: '$OUT'"; exit 1; }

echo "  query_window_aggregates: in-window row counted, out-of-window excluded..."
upsert_specialist_run "$DB2" srosro/repo 1 tests 5 2026-04-01T00:00:00Z
upsert_specialist_run "$DB2" srosro/repo 2 tests 6 2025-01-01T00:00:00Z
OUT=$(query_window_aggregates "$DB2" "2026-03-01T00:00:00Z")
[ "$OUT" = $'tests\t1\t0\t0\t0\t0\t0\t0' ] || { echo "FAIL: window filter: '$OUT'"; exit 1; }

echo "  query_window_aggregates: ORDER BY shipped DESC (more-published first)..."
upsert_specialist_run "$DB2" srosro/repo 10 alpha 9 2026-04-10T00:00:00Z
upsert_specialist_run "$DB2" srosro/repo 11 alpha 9 2026-04-11T00:00:00Z
mark_published "$DB2" srosro/repo 10 alpha
mark_published "$DB2" srosro/repo 11 alpha
upsert_specialist_run "$DB2" srosro/repo 12 beta 9 2026-04-12T00:00:00Z
mark_published "$DB2" srosro/repo 12 beta
OUT=$(query_window_aggregates "$DB2" "2026-04-01T00:00:00Z")
FIRST_SPEC=$(printf '%s\n' "$OUT" | head -1 | cut -f1)
[ "$FIRST_SPEC" = "alpha" ] || { echo "FAIL: ordering — first='$FIRST_SPEC' expected 'alpha'"; exit 1; }

echo "  find_target_review_for_feedback: empty when no rows..."
DB3="$TMP/bakeoff3.db"
store_init "$DB3"
OUT=$(find_target_review_for_feedback "$DB3" srosro/repo 99 2026-04-15T12:00:00Z)
[ -z "$OUT" ] || { echo "FAIL: empty store should return empty: '$OUT'"; exit 1; }

echo "  find_target_review_for_feedback: returns most-recent review before cutoff..."
upsert_specialist_run "$DB3" srosro/repo 1001 tests 99 2026-04-10T00:00:00Z
upsert_specialist_run "$DB3" srosro/repo 1002 tests 99 2026-04-12T00:00:00Z
upsert_specialist_run "$DB3" srosro/repo 1003 tests 99 2026-04-20T00:00:00Z   # after cutoff
OUT=$(find_target_review_for_feedback "$DB3" srosro/repo 99 2026-04-15T00:00:00Z)
[ "$OUT" = "1002" ] || { echo "FAIL: expected most-recent before cutoff (1002), got '$OUT'"; exit 1; }

echo "  find_target_review_for_feedback: scoped to (repo, pr_number)..."
upsert_specialist_run "$DB3" other/repo 2002 tests 99 2026-04-13T00:00:00Z   # different repo
upsert_specialist_run "$DB3" srosro/repo 3003 tests 88 2026-04-13T00:00:00Z   # different PR
OUT=$(find_target_review_for_feedback "$DB3" srosro/repo 99 2026-04-15T00:00:00Z)
[ "$OUT" = "1002" ] || { echo "FAIL: cross-(repo, pr) leak — got '$OUT' expected 1002"; exit 1; }

echo "  set_applied_loc: writes added + removed into the row..."
DB4="$TMP/bakeoff4.db"
store_init "$DB4"
upsert_specialist_run "$DB4" srosro/repo 7000 tests 42 2026-04-15T12:00:00Z
set_applied_loc "$DB4" srosro/repo 7000 tests 18 5
ROW=$(sqlite3 "$DB4" "SELECT applied_added, applied_removed FROM specialist_runs WHERE comment_id=7000 AND specialist='tests';")
[ "$ROW" = "18|5" ] || { echo "FAIL: set_applied_loc round-trip: $ROW"; exit 1; }

echo "  set_applied_loc: idempotent (SET overwrites, not increment)..."
set_applied_loc "$DB4" srosro/repo 7000 tests 18 5
set_applied_loc "$DB4" srosro/repo 7000 tests 22 7   # later rewalk with new commit
ROW=$(sqlite3 "$DB4" "SELECT applied_added, applied_removed FROM specialist_runs WHERE comment_id=7000 AND specialist='tests';")
[ "$ROW" = "22|7" ] || { echo "FAIL: SET semantic broken: $ROW"; exit 1; }

echo "  query_window_aggregates: emits added + removed columns..."
DB5="$TMP/bakeoff5.db"
store_init "$DB5"
upsert_specialist_run "$DB5" srosro/repo 8000 tests 99 2026-04-15T00:00:00Z
mark_published "$DB5" srosro/repo 8000 tests
mark_applied "$DB5" srosro/repo 8000 tests
set_applied_loc "$DB5" srosro/repo 8000 tests 30 10
OUT=$(query_window_aggregates "$DB5" "2026-04-01T00:00:00Z")
# TSV: specialist  reviews  shipped  applied  added  removed  loved  critiqued
[ "$OUT" = $'tests\t1\t1\t1\t30\t10\t0\t0' ] || { echo "FAIL: TSV shape: $OUT"; exit 1; }

echo "PASS"
