#!/usr/bin/env bash
# Persistent store for the specialist bake-off.
#
# One row per (repo, comment_id, specialist) — every specialist that was
# invoked on a posted review gets a row, regardless of whether it had any
# findings. Booleans capture the per-review per-specialist outcome:
#   - published:      did this specialist contribute any probe to the review
#   - applied:        was any cited path of any of its probes touched by the PR
#   - loved_positive: did a /srosro-props or /srosro-memorize quoting it land
#   - critiqued:      did a /srosro-critique quoting it land
#
# Re-walks must NOT reset the flag columns to 0 — that's why row creation
# uses `INSERT … ON CONFLICT DO UPDATE` that touches only `last_walked_at`,
# and flag updates are separate UPDATE statements.

# SQL injection invariant: every string field interpolated below ($repo,
# $specialist, $ts, $before_ts) MUST be pre-validated by callers — the
# parsers in lib/bakeoff-parsers.sh constrain inputs to [a-z][a-z,-]*
# (specialist names) and ISO8601 timestamps (timestamps); $repo comes from
# operator-controlled tracked-repos.sh; integer fields (comment_id,
# pr_number) are unquoted and rely on jq -r .id producing integers.
# If you add a new helper that interpolates a new field, audit its
# upstream parser/validator before merging.

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
    applied_added   INTEGER NOT NULL DEFAULT 0,
    applied_removed INTEGER NOT NULL DEFAULT 0,
    loved_positive  INTEGER NOT NULL DEFAULT 0,
    critiqued       INTEGER NOT NULL DEFAULT 0,
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
mark_critiqued()      { _mark_flag "$1" "$2" "$3" "$4" critiqued; }

# Set both LOC counters in one UPDATE. SET semantics (overwrite, not increment),
# so a re-walk that observes a different commit on the PR replaces stale values.
set_applied_loc() {
    local db="$1" repo="$2" comment_id="$3" specialist="$4" added="$5" removed="$6"
    sqlite3 "$db" <<SQL
UPDATE specialist_runs
   SET applied_added = $added,
       applied_removed = $removed
 WHERE repo = '$repo' AND comment_id = $comment_id AND specialist = '$specialist';
SQL
}

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

# Find the most-recent prior review on (repo, pr) before before_ts.
# Used by the walker's pass-2 to attribute feedback comments to a specific
# (review, specialist) row. Returns empty string if no qualifying review.
find_target_review_for_feedback() {
    local db="$1" repo="$2" pr_number="$3" before_ts="$4"
    sqlite3 "$db" <<SQL
SELECT comment_id FROM specialist_runs
 WHERE repo = '$repo'
   AND pr_number = $pr_number
   AND ran_at < '$before_ts'
 ORDER BY ran_at DESC
 LIMIT 1;
SQL
}

# TSV: specialist\treviews\tshipped\tapplied\tadded\tremoved\tloved\tcritiqued
# Caller passes window cutoff to keep the function pure (no date math).
query_window_aggregates() {
    local db="$1" window_iso="$2"
    sqlite3 -separator $'\t' "$db" <<SQL
SELECT
    specialist,
    COUNT(*) AS reviews,
    SUM(published) AS shipped,
    SUM(applied) AS applied,
    SUM(applied_added) AS added,
    SUM(applied_removed) AS removed,
    SUM(loved_positive) AS loved,
    SUM(critiqued) AS critiqued
FROM specialist_runs
WHERE ran_at >= '$window_iso'
GROUP BY specialist
ORDER BY shipped DESC;
SQL
}
