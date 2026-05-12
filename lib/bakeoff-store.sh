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
#   - edited_after:   did any cited path of any of its probes get touched by a commit landing AFTER the bot review (stronger signal than `applied`)
#
# Re-walks must NOT reset the flag columns to 0 — that's why row creation
# uses `INSERT … ON CONFLICT DO UPDATE` that touches only `last_walked_at`,
# and flag updates are separate UPDATE statements.

# SQL injection invariant: every string field interpolated below ($repo,
# $specialist, $ts, $before_ts, $sev) MUST be pre-validated by callers — the
# parsers in lib/bakeoff-parsers.sh constrain inputs to [a-z][a-z,-]*
# (specialist names) and ISO8601 timestamps (timestamps); $repo comes from
# operator-controlled tracked-repos.sh; $sev comes from probe_severity() in
# lib/bakeoff-parsers.sh which constrains to [a-z]+ via the `^N. [<sev>]`
# probe shape, and callers MUST pass a value from severity_rank()'s key set
# (blocking|medium|low|nit|open|''); integer fields (comment_id, pr_number) are
# unquoted and rely on jq -r .id producing integers.
# If you add a new helper that interpolates a new field, audit its
# upstream parser/validator before merging.

# Bootstrap the schema. Idempotent — safe to call on every walk.
store_init() {
    local db="$1"
    # Schema note: max_severity (added 2026-05-07) is in CREATE TABLE below
    # AND in the pragma-gated ALTER below (handles pre-existing DBs from PR #66).
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
    edited_after    INTEGER NOT NULL DEFAULT 0,
    max_severity    TEXT    NOT NULL DEFAULT '',
    last_walked_at  TEXT    NOT NULL,
    PRIMARY KEY (repo, comment_id, specialist)
);
CREATE INDEX IF NOT EXISTS idx_runs_spec_time
    ON specialist_runs(specialist, ran_at);

CREATE TABLE IF NOT EXISTS walks (
    repo                            TEXT PRIMARY KEY,
    last_walked_at                  TEXT    NOT NULL,
    reviews_total_in_window         INTEGER NOT NULL DEFAULT 0,
    reviews_with_marker_in_window   INTEGER NOT NULL DEFAULT 0
);
SQL

    # Migration: add max_severity column to pre-existing DBs (added 2026-05-07).
    # SQLite has no ALTER TABLE ... ADD COLUMN IF NOT EXISTS; check via pragma.
    if ! sqlite3 "$db" "SELECT 1 FROM pragma_table_info('specialist_runs') WHERE name='max_severity';" | grep -q 1; then
        sqlite3 "$db" "ALTER TABLE specialist_runs ADD COLUMN max_severity TEXT NOT NULL DEFAULT '';"
    fi

    # Migration: add edited_after column to pre-existing DBs (added 2026-05-12).
    if ! sqlite3 "$db" "SELECT 1 FROM pragma_table_info('specialist_runs') WHERE name='edited_after';" | grep -q 1; then
        sqlite3 "$db" "ALTER TABLE specialist_runs ADD COLUMN edited_after INTEGER NOT NULL DEFAULT 0;"
    fi

    # Migration: add coverage columns to pre-existing DBs (added 2026-05-12).
    if ! sqlite3 "$db" "SELECT 1 FROM pragma_table_info('walks') WHERE name='reviews_total_in_window';" | grep -q 1; then
        sqlite3 "$db" "ALTER TABLE walks ADD COLUMN reviews_total_in_window INTEGER NOT NULL DEFAULT 0;"
    fi
    if ! sqlite3 "$db" "SELECT 1 FROM pragma_table_info('walks') WHERE name='reviews_with_marker_in_window';" | grep -q 1; then
        sqlite3 "$db" "ALTER TABLE walks ADD COLUMN reviews_with_marker_in_window INTEGER NOT NULL DEFAULT 0;"
    fi
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
mark_edited_after()   { _mark_flag "$1" "$2" "$3" "$4" edited_after; }

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

# Persist per-repo coverage counters — substantive bot reviews seen in the
# WINDOW_DAYS lookback, total vs marker-equipped. Renormalized per walk.
# Upsert so the row exists even if get_walk_watermark hasn't been called
# (e.g. coverage-only run on a brand-new DB).
set_repo_coverage() {
    local db="$1" repo="$2" total="$3" with_marker="$4"
    # Integer fields (total, with_marker) — caller guarantees jq-extracted int.
    sqlite3 "$db" <<SQL
INSERT INTO walks (repo, last_walked_at, reviews_total_in_window, reviews_with_marker_in_window)
VALUES ('$repo', '$(date -u +%FT%TZ)', $total, $with_marker)
ON CONFLICT(repo) DO UPDATE SET
    reviews_total_in_window = excluded.reviews_total_in_window,
    reviews_with_marker_in_window = excluded.reviews_with_marker_in_window;
SQL
}

# Returns "total|with_marker". Empty walks row → "0|0".
query_coverage() {
    local db="$1" repo="$2"
    local row
    row=$(sqlite3 "$db" "SELECT reviews_total_in_window || '|' || reviews_with_marker_in_window FROM walks WHERE repo='$repo';")
    [ -n "$row" ] && echo "$row" || echo "0|0"
}

# Severity ordering — single source of truth. Higher number = worse.
# blocking > medium > low > nit > open > '' (empty = no probes yet).
severity_rank() {
    case "${1:-}" in
        blocking) echo 5 ;;
        medium)   echo 4 ;;
        low)      echo 3 ;;
        nit)      echo 2 ;;
        open)     echo 1 ;;
        *)        echo 0 ;;
    esac
}

# Set max_severity to the given value. Caller is responsible for picking
# the max via severity_rank — this helper is a plain SET so SQL stays
# simple and severity_rank stays the only seam that knows the order.
set_max_severity() {
    local db="$1" repo="$2" comment_id="$3" specialist="$4" sev="$5"
    # $sev MUST be from severity_rank()'s key set: blocking|medium|low|nit|open|''
    # (validated upstream by probe_severity() in lib/bakeoff-parsers.sh).
    sqlite3 "$db" <<SQL
UPDATE specialist_runs
   SET max_severity = '$sev'
 WHERE repo = '$repo' AND comment_id = $comment_id AND specialist = '$specialist';
SQL
}

# Reset applied + applied_added + applied_removed + edited_after for every
# (specialist) row of a given (repo, comment_id). Called by the walker
# BEFORE recomputing applied matches, so that stale credit (PR diff stopped
# touching the previously-matched path) gets cleared. Only call AFTER
# pulls/files succeeds — otherwise you'd nuke previously-correct data on a
# transient API failure.
clear_applied_for_review() {
    local db="$1" repo="$2" comment_id="$3"
    sqlite3 "$db" <<SQL
UPDATE specialist_runs
   SET applied = 0, applied_added = 0, applied_removed = 0, edited_after = 0
 WHERE repo = '$repo' AND comment_id = $comment_id;
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
#      \tedited\tblocking\tmedium\tlow_nit\topen
# Severity buckets count reviews where max_severity falls in each tier.
# `low_nit` collapses [low] + [nit] (adjacent on the severity ladder).
# Reviews with unset max_severity (no probes) fall outside every bucket.
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
    SUM(critiqued) AS critiqued,
    SUM(edited_after) AS edited,
    SUM(CASE WHEN max_severity = 'blocking' THEN 1 ELSE 0 END) AS blocking,
    SUM(CASE WHEN max_severity = 'medium'   THEN 1 ELSE 0 END) AS medium,
    SUM(CASE WHEN max_severity IN ('low','nit') THEN 1 ELSE 0 END) AS low_nit,
    SUM(CASE WHEN max_severity = 'open'     THEN 1 ELSE 0 END) AS open_cnt
FROM specialist_runs
WHERE ran_at >= '$window_iso'
GROUP BY specialist
ORDER BY shipped DESC;
SQL
}
