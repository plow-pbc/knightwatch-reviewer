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
ROW=$(sqlite3 "$DB" "SELECT specialist, published, applied, loved_positive, loved_negative FROM specialist_runs WHERE comment_id=200 AND specialist='security';")
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

echo "PASS"
