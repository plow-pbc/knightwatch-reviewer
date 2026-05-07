#!/usr/bin/env bash
# Persistent store for the specialist bake-off.
#
# One row per (repo, comment_id, specialist) — every specialist that was
# invoked on a posted review gets a row, regardless of whether it had any
# findings. Booleans capture the per-review per-specialist outcome:
#   - published:      did this specialist contribute any probe to the review
#   - applied:        was any cited path of any of its probes touched by the PR
#   - loved_positive: did a /kw-props or /srosro-memorize quoting it land
#   - loved_negative: did a /kw-critique quoting it land
#
# Re-walks must NOT reset the flag columns to 0 — that's why row creation
# uses `INSERT … ON CONFLICT DO UPDATE` that touches only `last_walked_at`,
# and flag updates are separate UPDATE statements.

# Bootstrap the schema. Idempotent — safe to call on every walk.
store_init() {
    local db="$1"
    sqlite3 "$db" <<'SQL'
CREATE TABLE IF NOT EXISTS specialist_runs (
    repo            TEXT    NOT NULL,
    comment_id      INTEGER NOT NULL,
    specialist      TEXT    NOT NULL,
    pr_number       INTEGER NOT NULL,
    ran_at          TEXT    NOT NULL,
    published       INTEGER NOT NULL DEFAULT 0,
    applied         INTEGER NOT NULL DEFAULT 0,
    loved_positive  INTEGER NOT NULL DEFAULT 0,
    loved_negative  INTEGER NOT NULL DEFAULT 0,
    last_walked_at  TEXT    NOT NULL,
    PRIMARY KEY (repo, comment_id, specialist)
);
CREATE INDEX IF NOT EXISTS idx_runs_spec_time
    ON specialist_runs(specialist, ran_at);

CREATE TABLE IF NOT EXISTS walks (
    repo            TEXT PRIMARY KEY,
    last_walked_at  TEXT NOT NULL
);
SQL
}

# Insert a (repo, comment_id, specialist) row if absent. Preserves any
# prior flag columns on conflict — only refreshes last_walked_at.
upsert_specialist_run() {
    local db="$1" repo="$2" comment_id="$3" specialist="$4" pr_number="$5" ran_at="$6"
    local now; now=$(date -u +%FT%TZ)
    sqlite3 "$db" <<SQL
INSERT INTO specialist_runs
    (repo, comment_id, specialist, pr_number, ran_at, last_walked_at)
VALUES
    ('$repo', $comment_id, '$specialist', $pr_number, '$ran_at', '$now')
ON CONFLICT(repo, comment_id, specialist)
DO UPDATE SET last_walked_at = excluded.last_walked_at;
SQL
}

_mark_flag() {
    local db="$1" repo="$2" comment_id="$3" specialist="$4" col="$5"
    sqlite3 "$db" <<SQL
UPDATE specialist_runs
   SET $col = 1
 WHERE repo = '$repo' AND comment_id = $comment_id AND specialist = '$specialist';
SQL
}

mark_published()      { _mark_flag "$1" "$2" "$3" "$4" published; }
mark_applied()        { _mark_flag "$1" "$2" "$3" "$4" applied; }
mark_loved_positive() { _mark_flag "$1" "$2" "$3" "$4" loved_positive; }
mark_loved_negative() { _mark_flag "$1" "$2" "$3" "$4" loved_negative; }

get_walk_watermark() {
    local db="$1" repo="$2"
    sqlite3 "$db" "SELECT last_walked_at FROM walks WHERE repo='$repo';"
}

set_walk_watermark() {
    local db="$1" repo="$2" ts="$3"
    sqlite3 "$db" <<SQL
INSERT INTO walks (repo, last_walked_at) VALUES ('$repo', '$ts')
ON CONFLICT(repo) DO UPDATE SET last_walked_at = excluded.last_walked_at;
SQL
}

# TSV: specialist\treviews\tshipped\tapplied\tloved\tcritiqued
# Caller passes window cutoff to keep the function pure (no date math).
query_window_aggregates() {
    local db="$1" window_iso="$2"
    sqlite3 -separator $'\t' "$db" <<SQL
SELECT
    specialist,
    COUNT(*) AS reviews,
    SUM(published) AS shipped,
    SUM(applied) AS applied,
    SUM(loved_positive) AS loved,
    SUM(loved_negative) AS critiqued
FROM specialist_runs
WHERE ran_at >= '$window_iso'
GROUP BY specialist
ORDER BY shipped DESC;
SQL
}
