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

echo "  severity_rank: blocking > medium > low > nit > open > '' (empty)..."
[ "$(severity_rank blocking)" = "5" ] || { echo "FAIL: blocking rank"; exit 1; }
[ "$(severity_rank medium)"   = "4" ] || { echo "FAIL: medium rank"; exit 1; }
[ "$(severity_rank low)"      = "3" ] || { echo "FAIL: low rank"; exit 1; }
[ "$(severity_rank nit)"      = "2" ] || { echo "FAIL: nit rank"; exit 1; }
[ "$(severity_rank open)"     = "1" ] || { echo "FAIL: open rank"; exit 1; }
[ "$(severity_rank '')"       = "0" ] || { echo "FAIL: empty rank"; exit 1; }

echo "  set_max_severity: writes severity into the row..."
DB6="$TMP/bakeoff6.db"
store_init "$DB6"
upsert_specialist_run "$DB6" srosro/repo 9000 tests 99 2026-04-15T12:00:00Z
set_max_severity "$DB6" srosro/repo 9000 tests blocking
ROW=$(sqlite3 "$DB6" "SELECT max_severity FROM specialist_runs WHERE comment_id=9000 AND specialist='tests';")
[ "$ROW" = "blocking" ] || { echo "FAIL: set_max_severity round-trip: $ROW"; exit 1; }

echo "  clear_applied_for_review: resets applied + LOC for all rows of a (repo, comment_id)..."
DB7="$TMP/bakeoff7.db"
store_init "$DB7"
upsert_specialist_run "$DB7" srosro/repo 5000 tests 99 2026-04-15T00:00:00Z
upsert_specialist_run "$DB7" srosro/repo 5000 shape 99 2026-04-15T00:00:00Z
mark_applied "$DB7" srosro/repo 5000 tests
mark_applied "$DB7" srosro/repo 5000 shape
set_applied_loc "$DB7" srosro/repo 5000 tests 50 10
set_applied_loc "$DB7" srosro/repo 5000 shape 25 5
clear_applied_for_review "$DB7" srosro/repo 5000
OUT=$(sqlite3 -separator , "$DB7" "SELECT specialist, applied, applied_added, applied_removed FROM specialist_runs WHERE comment_id=5000 ORDER BY specialist;")
EXPECTED='shape,0,0,0
tests,0,0,0'
[ "$OUT" = "$EXPECTED" ] || { echo "FAIL: clear_applied_for_review: got '$OUT'"; exit 1; }

echo "  clear_applied_for_review: scoped to (repo, comment_id) — other rows untouched..."
upsert_specialist_run "$DB7" srosro/repo 6000 tests 88 2026-04-15T00:00:00Z
mark_applied "$DB7" srosro/repo 6000 tests
clear_applied_for_review "$DB7" srosro/repo 5000   # different comment_id
OUT=$(sqlite3 "$DB7" "SELECT applied FROM specialist_runs WHERE comment_id=6000 AND specialist='tests';")
[ "$OUT" = "1" ] || { echo "FAIL: cross-comment leak — comment_id=6000 got reset, applied='$OUT'"; exit 1; }

echo "  store_init: ALTER adds max_severity to a pre-existing DB without the column..."
DB8="$TMP/bakeoff8.db"
# Simulate an old-schema DB (PR #66 era — no max_severity column).
sqlite3 "$DB8" <<'OLDSQL'
CREATE TABLE specialist_runs (
    repo TEXT NOT NULL,
    comment_id INTEGER NOT NULL,
    specialist TEXT NOT NULL,
    pr_number INTEGER NOT NULL,
    ran_at TEXT NOT NULL,
    published INTEGER NOT NULL DEFAULT 0,
    applied INTEGER NOT NULL DEFAULT 0,
    applied_added INTEGER NOT NULL DEFAULT 0,
    applied_removed INTEGER NOT NULL DEFAULT 0,
    loved_positive INTEGER NOT NULL DEFAULT 0,
    critiqued INTEGER NOT NULL DEFAULT 0,
    last_walked_at TEXT NOT NULL,
    PRIMARY KEY (repo, comment_id, specialist)
);
INSERT INTO specialist_runs VALUES ('srosro/repo', 100, 'tests', 7, '2026-04-01T00:00:00Z', 1, 0, 0, 0, 0, 0, '2026-04-01T00:00:00Z');
OLDSQL
store_init "$DB8"
HAS=$(sqlite3 "$DB8" "SELECT 1 FROM pragma_table_info('specialist_runs') WHERE name='max_severity';")
[ "$HAS" = "1" ] || { echo "FAIL: ALTER did not add max_severity"; exit 1; }
# Verify pre-existing data survives the migration.
ROW=$(sqlite3 "$DB8" "SELECT comment_id, specialist FROM specialist_runs;")
[ "$ROW" = "100|tests" ] || { echo "FAIL: pre-existing row lost: $ROW"; exit 1; }
# Verify the new column defaults to '' for the migrated row.
SEV=$(sqlite3 "$DB8" "SELECT max_severity FROM specialist_runs WHERE comment_id=100;")
[ "$SEV" = "" ] || { echo "FAIL: migrated row should have empty max_severity, got '$SEV'"; exit 1; }

echo "PASS"
