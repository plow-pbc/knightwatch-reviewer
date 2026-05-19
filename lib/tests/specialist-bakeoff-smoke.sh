#!/usr/bin/env bash
# Hermetic smoke for the bake-off parsers AND the driver (specialist-bakeoff.sh).
# No network, no real gh — a stub replaces gh on PATH.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_ROOT/lib/bakeoff-parsers.sh"
# shellcheck source=./assert.sh
. "$REPO_ROOT/lib/tests/assert.sh"

FIX_DIR="$REPO_ROOT/lib/tests/fixtures/specialist-bakeoff"

echo "  count_attributions: 5 probes across 4 specialists..."
got=$(count_attributions < "$FIX_DIR/review-1.md" | sort | uniq -c | awk '{print $2"="$1}' | sort)
want=$'aggregator=1\nshape=1\nsimplification=2\ntests=1'
if [ "$got" != "$want" ]; then
    echo "FAIL: count_attributions output mismatch"
    echo "got:"
    echo "$got"
    echo "want:"
    echo "$want"
    exit 1
fi

echo "  count_attributions: footer ignored AND multi-review streams counted correctly..."
# count_attributions filters by probe-line pattern (^N.) — so prose/
# footer/doc tokens are excluded by construction. Production streams
# multiple selected review bodies through one parser invocation; this
# test runs the fixture concatenated TWICE to exercise both invariants:
#   - footer's literal `[from: shape]` example never counts (would inflate
#     shape if line-pattern filter regressed to body-wide grep)
#   - both reviews' probe-line attributions count (would yield only review 1
#     if the parser ever truncated at the first `---` separator)
# Expected: data-integrity=2, shape=2 (each review has 1 of each on probe lines).
got=$(cat "$FIX_DIR/review-with-footer.md" "$FIX_DIR/review-with-footer.md" \
        | count_attributions | sort | uniq -c | awk '{print $2"="$1}' | sort)
want=$'data-integrity=2\nshape=2'
if [ "$got" != "$want" ]; then
    echo "FAIL: count_attributions multi-review boundary regressed"
    echo "got:"
    echo "$got"
    echo "want:"
    echo "$want"
    exit 1
fi

echo "  extract_memorize_attributions: quoted memorize names simplification..."
got=$(extract_memorize_attributions < "$FIX_DIR/memorize-quoted.md")
want="simplification"
assert_eq "$got" "$want" "memorize-quoted should attribute to simplification"

echo "  extract_memorize_attributions: unquoted memorize attributes to nobody..."
got=$(extract_memorize_attributions < "$FIX_DIR/memorize-no-quote.md") || true
assert_empty "$got" "memorize-no-quote should produce no attribution"

echo "  probe_cited_paths: Files-only extract; Edit clause excluded..."
input=$(cat <<'PROBES'
1. [blocking] [from: shape] [shape] Foo. Files: a.sh:1, b.md. Edit: see fake.sh:99.
2. [low] [from: tests] [tests] Bar. Files: t.sh. Edit: do x.
3. [open] [from: simplification] [simplification] **Q: foo?** — Q text. If yes, x. If no, y.
PROBES
)
got=$(printf '%s\n' "$input" | probe_cited_paths | sort)
want=$'a.sh\nb.md\nt.sh'
if [ "$got" != "$want" ]; then
    echo "FAIL: probe_cited_paths Files-only extract"
    echo "  got:"
    echo "$got"
    echo "  want:"
    echo "$want"
    exit 1
fi

echo "  probe_cited_paths: backtick + :LINE normalization..."
input2='1. [blocking] [from: shape] [shape] X. Files: `lib/foo.sh:42`, bar.md.'
got=$(printf '%s\n' "$input2" | probe_cited_paths | sort)
want2=$'bar.md\nlib/foo.sh'
if [ "$got" != "$want2" ]; then
    echo "FAIL: probe_cited_paths normalization"
    echo "  got:"
    echo "$got"
    echo "  want:"
    echo "$want2"
    exit 1
fi

# ============================================================
# Driver smoke: specialist-bakeoff.sh end-to-end, no network.
# Mirrors the gh-stub pattern from learn-from-replies-smoke.sh.
# ============================================================
echo "  driver smoke: paginated gh, trusted/untrusted memorize, ACK filter..."

export TMPDIR_SMOKE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

export STATE_DIR="$TMPDIR_SMOKE/state"
export OUT_FILE="$STATE_DIR/specialist-bakeoff.md"
export LOG_FILE="$STATE_DIR/bakeoff.log"
export DB_FILE="$STATE_DIR/bakeoff.db"
export BOT_USER="testbot"
export BOT_AUTO_POST_MARKER="<!-- knightwatch-reviewer:auto-post -->"
# REWALK_HOURS wide enough to cover all fixture timestamps (max 480 h = 20 days).
# SCORECARD_DAYS wide enough to cover the same (default 14 would exclude them).
export REWALK_HOURS=720
export SCORECARD_DAYS=30
mkdir -p "$STATE_DIR/tmp"

export STUB_BIN="$TMPDIR_SMOKE/bin"
mkdir -p "$STUB_BIN"
export MOCK_COMMENTS_FILE="$TMPDIR_SMOKE/comments.json"
echo "[]" > "$MOCK_COMMENTS_FILE"

# Stub gh: serves a fixed comments payload + a bulk collaborators list.
# trusted-human has push=true; untrusted-user has push=false.
cat > "$STUB_BIN/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ]; then
    endpoint=""
    paginate=""
    jq_expr=""
    next_is_jq=""
    for arg in "$@"; do
        if [ -n "$next_is_jq" ]; then
            jq_expr="$arg"
            next_is_jq=""
            continue
        fi
        case "$arg" in
            --paginate) paginate=1 ;;
            --jq)       next_is_jq=1 ;;
            repos/*)    endpoint="$arg" ;;
        esac
    done
    if [[ "$endpoint" == */issues/comments* ]] && [ -n "${MOCK_GH_API_FAIL:-}" ]; then
        echo "gh api: simulated failure" >&2
        exit 1
    fi
    if [[ "$endpoint" == */issues/comments* ]]; then
        # Return mock comments unfiltered — real GitHub's since= is
        # updated_at-based, so an old comment with a recent edit comes
        # back. The walker defends itself via its own .created_at >=
        # $window_floor jq fence; stub mirrors that "API may return
        # out-of-window comments" reality.
        cat "$MOCK_COMMENTS_FILE"
        if [ -n "$paginate" ] && [ -s "${MOCK_COMMENTS_FILE_PAGE2:-/dev/null}" ]; then
            cat "$MOCK_COMMENTS_FILE_PAGE2"
        fi
    elif [[ "$endpoint" == */collaborators* ]]; then
        printf '[{"login":"trusted-human","permissions":{"push":true}},{"login":"untrusted-user","permissions":{"push":false}}]\n'
    elif [[ "$endpoint" == */pulls/*/commits* ]] && [ -n "${MOCK_GH_PULLS_COMMITS_FAIL:-}" ]; then
        echo "gh api: simulated pulls/commits failure" >&2
        exit 1
    elif [[ "$endpoint" == */pulls/*/commits* ]]; then
        # MOCK_PULLS_COMMITS_FILE: TSV of sha\tauthor_date[\tcommitter_date] per line.
        # committer_date defaults to author_date when omitted (back-compat with
        # 2-column callers — committer is what the walker filters on for the
        # "landed after review" fence; author can differ in rebase scenarios).
        if [ -s "${MOCK_PULLS_COMMITS_FILE:-/dev/null}" ]; then
            commits_json=$(awk -F'\t' 'BEGIN{first=1; print "["}
{
    if (first) first=0; else print ",";
    cd = ($3 == "" ? $2 : $3);
    printf "{\"sha\":\"%s\",\"commit\":{\"author\":{\"date\":\"%s\"},\"committer\":{\"date\":\"%s\"}}}", $1, $2, cd
}
END{print "]"}' "$MOCK_PULLS_COMMITS_FILE")
        else
            commits_json="[]"
        fi
        if [ -n "$jq_expr" ]; then
            printf '%s' "$commits_json" | jq -r "$jq_expr"
        else
            printf '%s' "$commits_json"
        fi
    elif [[ "$endpoint" == */commits/* ]] && [ -n "${MOCK_GH_COMMIT_FAIL_SHA:-}" ] && [[ "${endpoint##*/commits/}" == "${MOCK_GH_COMMIT_FAIL_SHA%%\?*}" ]]; then
        echo "gh api: simulated commits/<sha> failure for $endpoint" >&2
        exit 1
    elif [[ "$endpoint" == */commits/* ]]; then
        # MOCK_COMMIT_FILES_DIR/<sha>.tsv: TSV of filename[\tprevious_filename] per line.
        # previous_filename is omitted (or empty) for normal edits; set it for
        # rename commits so the walker can match probes citing the pre-rename path.
        sha="${endpoint##*/commits/}"
        sha="${sha%%\?*}"
        files_file="${MOCK_COMMIT_FILES_DIR:-/dev/null}/$sha.tsv"
        if [ -s "$files_file" ]; then
            files_json=$(awk -F'\t' 'BEGIN{first=1; print "["}
{
    if (first) first=0; else print ",";
    if ($2 == "") {
        printf "{\"filename\":\"%s\"}", $1
    } else {
        printf "{\"filename\":\"%s\",\"previous_filename\":\"%s\"}", $1, $2
    }
}
END{print "]"}' "$files_file")
        else
            files_json="[]"
        fi
        printf '{"sha":"%s","files":%s}' "$sha" "$files_json"
    elif [[ "$endpoint" == */pulls/*/files* ]] && [ -n "${MOCK_GH_PULLS_FILES_FAIL:-}" ]; then
        echo "gh api: simulated pulls/files failure" >&2
        exit 1
    elif [[ "$endpoint" == */pulls/*/files* ]]; then
        # Driver feeds the touched-files set via MOCK_PULLS_FILES_FILE.
        # Each line is TSV: path\tadditions\tdeletions. additions+deletions
        # default to 0 when omitted (lets older scenarios keep 1-field lines).
        # Real `gh` runs --jq server-side; we mirror by piping through jq
        # when --jq was passed.
        if [ -s "${MOCK_PULLS_FILES_FILE:-/dev/null}" ]; then
            files_json=$(awk -F'\t' 'BEGIN{first=1; print "["}
{
    if (first) first=0; else print ",";
    add = ($2 == "" ? 0 : $2);
    del = ($3 == "" ? 0 : $3);
    printf "{\"filename\":\"%s\",\"additions\":%d,\"deletions\":%d}", $1, add, del
}
END{print "]"}' "$MOCK_PULLS_FILES_FILE")
        else
            files_json="[]"
        fi
        if [ -n "$jq_expr" ]; then
            printf '%s' "$files_json" | jq -r "$jq_expr"
        else
            printf '%s' "$files_json"
        fi
    else
        echo "{}"
    fi
else
    echo "{}"
fi
STUB
chmod +x "$STUB_BIN/gh"

export HOME="$TMPDIR_SMOKE/home"
mkdir -p "$HOME"
export PATH="$STUB_BIN:$PATH"

# Sandbox lib dir — copy needed libs.
export REVIEWER_LIB_DIR="$TMPDIR_SMOKE/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$REPO_ROOT/lib/tracked-repos.sh"    "$REVIEWER_LIB_DIR/tracked-repos.sh"
cp "$REPO_ROOT/lib/bakeoff-parsers.sh"  "$REVIEWER_LIB_DIR/bakeoff-parsers.sh"
cp "$REPO_ROOT/lib/bakeoff-store.sh"    "$REVIEWER_LIB_DIR/bakeoff-store.sh"

# Single tracked repo.
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("test-org/bakeoff-probe")
CONF

run_driver() {
    bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1
}

# ISO8601 timestamp N hours ago. All fixture timestamps in this file derive
# from this so they stay safely inside the walker's REWALK_HOURS=720 lookback
# regardless of when the suite is run. (Hardcoded calendar dates drift out
# of the window as the wall clock advances and the gh stub's since= filter
# starts dropping fixtures.) GNU date primary, BSD date fallback — same
# shape as specialist-bakeoff.sh's date-math.
hours_ago() {
    date -u -d "$1 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v "-${1}H" +%Y-%m-%dT%H:%M:%SZ
}

# Build a single substantive bot-review JSON object on stdout.
# Args: $1 id, $2 pr_num, $3 created_at, $4 specialists (comma-sep), $5 probes_md (use \n for newlines).
# Caller pipes one or more invocations through `jq -s .` to form the JSON array file.
build_bot_review() {
    local id="$1" pr="$2" ts="$3" spec="$4" probes="$5"
    local body
    # printf %b decodes \n escapes in $probes (and the boilerplate) into real
    # newlines, then jq --arg json-escapes the result back into a JSON string.
    body=$(printf '%b' "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=$spec -->\n\n**Probes**\n\n$probes\n\n_How to use: auto-reviews every new PR..._")
    jq -n --argjson id "$id" \
          --arg url "https://api.github.com/repos/srosro/test-repo/issues/$pr" \
          --arg ts "$ts" --arg body "$body" \
        '{id: $id, issue_url: $url, created_at: $ts, user: {login: "testbot"}, body: $body}'
}

# Build a trusted-human feedback comment JSON object on stdout (e.g. /srosro-props or /srosro-critique).
# Args: $1 id, $2 pr_num, $3 created_at, $4 body.
build_feedback_comment() {
    local id="$1" pr="$2" ts="$3" body="$4"
    jq -n --argjson id "$id" \
          --arg url "https://api.github.com/repos/srosro/test-repo/issues/$pr" \
          --arg ts "$ts" --arg body "$body" \
        '{id: $id, issue_url: $url, created_at: $ts, user: {login: "trusted-human"}, body: $body}'
}

# Stand up the simplest edited_after scenario: one bot review citing one path,
# one post-review commit (single sha) touching that same path. Each test that
# uses this then drives its own walks (run_driver / failure variations) and
# DB assertions.
# Args: $1 review_id, $2 pr_num, $3 review_ts, $4 cited_path, $5 commit_sha,
#       $6 commit_ts, $7 files_dir_basename (under $TMPDIR_SMOKE).
setup_edited_after_one_commit() {
    local rid=$1 pr=$2 rts=$3 path=$4 sha=$5 cts=$6 dir=$7
    build_bot_review "$rid" "$pr" "$rts" tests \
        "1. [blocking] [from: tests] [tests] Cited. Files: $path. Edit: do x." \
        | jq -s . > "$MOCK_COMMENTS_FILE"
    printf '%s\t1\t0\n' "$path" > "$MOCK_PULLS_FILES_FILE"
    printf '%s\t%s\n' "$sha" "$cts" > "$TMPDIR_SMOKE/commits.tsv"
    export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"
    mkdir -p "$TMPDIR_SMOKE/$dir"
    echo "$path" > "$TMPDIR_SMOKE/$dir/$sha.tsv"
    export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/$dir"
}

# ---- scenario 1: no comments → empty table (placeholder text) ----
echo "    scenario 1: no comments → placeholder text, no data rows..."
rm -f "$DB_FILE"
run_driver
if grep -qE '^\| [a-z]' "$OUT_FILE"; then
    echo "FAIL scenario 1: expected no data rows, got rows in $OUT_FILE"
    cat "$OUT_FILE"
    exit 1
fi
if ! grep -qF "Awaiting first reviews" "$OUT_FILE"; then
    echo "FAIL scenario 1: expected 'Awaiting first reviews' placeholder in $OUT_FILE"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 2: substantive review, ACK, untrusted memorize, trusted memorize ----
echo "    scenario 2: review + ACK + memorize (trusted+untrusted) → aggregator row..."
# Four comments split across two pages — load-bearing comment D is on page 2:
#   A: substantive bot review — has marker, roster, footer, [from: aggregator]
#   B: same-bot ACK — has marker, NO footer — must NOT count as a review
#   C: untrusted /srosro-memorize quoting [from: aggregator] — must be ignored
#   D: (PAGE 2) trusted /srosro-memorize quoting [from: aggregator] — must count
# A regression that drops --paginate would still produce Loved=0 (page-2
# trusted memorize never reaches extract_memorize_attributions), so the
# Loved=1 assertion below is the load-bearing pagination check.
rm -f "$DB_FILE"

TS_REVIEW=$(hours_ago 480)
TS_ACK=$(hours_ago 479)
TS_UNTRUSTED=$(hours_ago 478)
TS_TRUSTED=$(hours_ago 477)  # load-bearing: AFTER review for attribution

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 1, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "${TS_REVIEW}", "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=aggregator,tests,security,shape -->\n\n**Probes**\n\n1. [blocking] [from: aggregator] The aggregator logic is overfit.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
    {"id": 2, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "${TS_ACK}", "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."},
    {"id": 3, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "${TS_UNTRUSTED}", "user": {"login": "untrusted-user"}, "body": "Thanks! /srosro-memorize I agree with [from: aggregator] finding."},
]
print(json.dumps(comments))
PYEOF

export MOCK_COMMENTS_FILE_PAGE2="$TMPDIR_SMOKE/comments-page2.json"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE_PAGE2"
import json
comments = [
    {"id": 4, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "${TS_TRUSTED}", "user": {"login": "trusted-human"},  "body": "/srosro-memorize The [from: aggregator] tip was great."},
]
print(json.dumps(comments))
PYEOF

run_driver
unset MOCK_COMMENTS_FILE_PAGE2
rm -f "$TMPDIR_SMOKE/comments-page2.json"

# aggregator emitted a [from: aggregator] probe → shipped=1 → row IS rendered
# (conditional skip is shipped=0 only, so a real cross-angle finding shows).
if ! grep -q '^| aggregator ' "$OUT_FILE"; then
    echo "FAIL scenario 2: aggregator row should render when it has shipped probes"
    cat "$OUT_FILE"
    exit 1
fi
# loved_positive is persisted whether the row renders or not.
LOVED_AGG=$(sqlite3 "$DB_FILE" "SELECT loved_positive FROM specialist_runs WHERE specialist='aggregator' AND comment_id=1;")
assert_eq "$LOVED_AGG" "1" "scenario 2: aggregator loved_positive not persisted"

# ---- scenario 3: spoof — non-bot user posts marker → must NOT count ----
echo "    scenario 3: spoof marker from non-bot user → not counted..."
rm -f "$DB_FILE"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 10, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/30", "created_at": "$(hours_ago 480)", "user": {"login": "evil-actor"}, "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=aggregator,tests,security,shape -->\n\n**Probes**\n\n1. [blocking] [from: aggregator] fake review — would count under count_attributions if bot-user selector regressed.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
]
print(json.dumps(comments))
PYEOF
run_driver
if grep -qE '^\| aggregator' "$OUT_FILE"; then
    echo "FAIL scenario 3: spoof marker from non-bot user inflated the table"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 4: gh api failure → partial run, OUT_FILE not overwritten ----
echo "    scenario 4: gh api failure → exit non-zero, OUT_FILE not overwritten..."
rm -f "$DB_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
# Write a sentinel into OUT_FILE so we can confirm it was NOT overwritten.
echo "SENTINEL" > "$OUT_FILE"
MOCK_GH_API_FAIL=1 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1 && {
    echo "FAIL scenario 4: expected non-zero exit when a repo fetch fails"
    exit 1
}
if ! grep -q "SENTINEL" "$OUT_FILE" 2>/dev/null; then
    echo "FAIL scenario 4: OUT_FILE was overwritten despite fetch failure"
    cat "$OUT_FILE"
    exit 1
fi
if ! grep -q "PARTIAL RUN" "$LOG_FILE" 2>/dev/null; then
    echo "FAIL scenario 4: expected PARTIAL RUN in log"
    cat "$LOG_FILE"
    exit 1
fi

# ---- scenario 5: review with cited Files: that overlap PR-touched paths → Applied counted ----
echo "    scenario 5: review with cited Files: paths matching PR diff → shape Applied=1..."
# A substantive bot review citing x.sh as a Files: path. The mocked
# pulls/files endpoint reports x.sh in the PR's touched set.
# Expected: Reviews=1, Shipped=1, Applied=1, Loved=0, Critiqued=0.
rm -f "$DB_FILE"

build_bot_review 100 42 "$(hours_ago 480)" shape,tests \
    '1. [blocking] [from: shape] [shape] Foo. Files: x.sh. Edit: y.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"

export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'x.sh\t12\t3\n' > "$MOCK_PULLS_FILES_FILE"

run_driver

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE

# 11-col table: | spec | Reviews | Shipped | Cited | Edited | Blocking | Medium | Low+Nit | Open | +LOC | −LOC |
# Reviews=1, Shipped=1, Cited=1 (x.sh in PR diff), Edited=0 (no post-review commits),
# Blocking=1 ([blocking] probe), +LOC=12/−LOC=3 from the mocked pulls/files row.
if ! grep -qE '\| shape \| +1 \| +1 \| +1 \| +0 \| +1 \| +0 \| +0 \| +0 \| +12 \| +3 \|' "$OUT_FILE"; then
    echo "FAIL scenario 5: expected shape | 1 | 1 | 1 | 0 | 1 | 0 | 0 | 0 | 12 | 3 in table"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 6: substantive review WITHOUT roster marker → no rows in store ----
echo "    scenario 6: review without roster marker → no rows in store..."
rm -f "$DB_FILE"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
print(json.dumps([{
    "id": 600,
    "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/60",
    "created_at": "$(hours_ago 480)",
    "user": {"login": "testbot"},
    "body": "${BOT_AUTO_POST_MARKER}\n\n**Probes**\n\n1. [blocking] [from: tests] missing test. Files: x.sh.\n\n_How to use: auto-reviews every new PR..._"
}]))
PYEOF
run_driver
ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM specialist_runs;")
assert_eq "$ROW_COUNT" "0" "scenario 6: marker-less review should not create rows"

# ---- scenario 7: trusted /srosro-props after substantive review → loved_positive=1 ----
echo "    scenario 7: trusted /srosro-props after substantive review → loved_positive=1..."
rm -f "$DB_FILE"
TS_REVIEW=$(hours_ago 480)
TS_FEEDBACK=$(hours_ago 479)
{ build_bot_review 700 70 "$TS_REVIEW" tests,shape '1. [blocking] [from: tests] missing test. Files: x.sh.'
  build_feedback_comment 701 70 "$TS_FEEDBACK" '/srosro-props [from: tests] solid catch'; } \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
LOVED=$(sqlite3 "$DB_FILE" "SELECT loved_positive FROM specialist_runs WHERE specialist='tests';")
assert_eq "$LOVED" "1" "scenario 7: srosro-props should mark loved_positive=1"

# ---- scenario 8: trusted /srosro-critique after substantive review → critiqued=1 ----
echo "    scenario 8: trusted /srosro-critique after substantive review → critiqued=1..."
rm -f "$DB_FILE"
TS_REVIEW=$(hours_ago 480)
TS_FEEDBACK=$(hours_ago 479)
{ build_bot_review 800 80 "$TS_REVIEW" shape,tests '1. [blocking] [from: shape] cycle. Files: x.sh.'
  build_feedback_comment 801 80 "$TS_FEEDBACK" '/srosro-critique [from: shape] misread'; } \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
CRIT=$(sqlite3 "$DB_FILE" "SELECT critiqued FROM specialist_runs WHERE specialist='shape';")
assert_eq "$CRIT" "1" "scenario 8: srosro-critique should mark critiqued=1"

# ---- scenario 9: re-running walker is idempotent (rows + flags unchanged) ----
echo "    scenario 9: re-walk on same input is idempotent..."
# Don't rm DB — reuse scenario 8's state, run again.
BEFORE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(critiqued) FROM specialist_runs;")
run_driver
AFTER=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(critiqued) FROM specialist_runs;")
assert_eq "$BEFORE" "$AFTER" "scenario 9: re-walk must be idempotent"

# ---- scenario 11: pulls/files failure → non-zero exit, OUT_FILE preserved ----
echo "    scenario 11: pulls/files failure → non-zero exit, OUT_FILE preserved..."
rm -f "$DB_FILE"
TS_SEED=$(hours_ago 480)
build_bot_review 1101 111 "$TS_SEED" tests \
    '1. [blocking] [from: tests] bar. Files: y.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
echo "SENTINEL" > "$OUT_FILE"
MOCK_GH_PULLS_FILES_FAIL=1 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1 && {
    echo "FAIL scenario 11: expected non-zero exit when pulls/files fails"
    exit 1
}
unset MOCK_GH_PULLS_FILES_FAIL
assert_contains "$(cat "$OUT_FILE")" "SENTINEL" "scenario 11: OUT_FILE must not be overwritten on failure"

# ---- scenario 12: max_severity tracks the worst severity per specialist ----
echo "    scenario 12: max_severity = blocking when specialist emits [blocking] + [medium] probes..."
rm -f "$DB_FILE"
build_bot_review 1200 120 "$(hours_ago 480)" tests \
    '1. [medium] [from: tests] one issue. Files: x.sh.\n2. [blocking] [from: tests] worse issue. Files: y.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
SEV=$(sqlite3 "$DB_FILE" "SELECT max_severity FROM specialist_runs WHERE specialist='tests';")
assert_eq "$SEV" "blocking" "scenario 12: max_severity should be 'blocking' when specialist emits [blocking]"

# ---- scenario 13: rewalk with PR diff no longer touching cited path → applied resets to 0 ----
echo "    scenario 13: rewalk after PR diff stops touching cited path → applied resets..."
rm -f "$DB_FILE"
build_bot_review 1300 130 "$(hours_ago 480)" shape \
    '1. [blocking] [from: shape] cycle. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
# First walk: PR touches x.sh — applied should be 1.
export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'x.sh\t10\t2\n' > "$MOCK_PULLS_FILES_FILE"
run_driver
A1=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
assert_eq "$A1" "1|10|2" "scenario 13 first walk: applied|+LOC|-LOC"

# Second walk: PR no longer touches x.sh (force-push removed those changes).
# Applied should reset to 0; LOC should reset to 0.
printf 'unrelated.sh\t99\t0\n' > "$MOCK_PULLS_FILES_FILE"
run_driver
A2=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
assert_eq "$A2" "0|0|0" "scenario 13 rewalk: applied|+LOC|-LOC should reset when path no longer in diff"

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE


# ---- scenario 15: max_severity=nit when specialist emits only [nit] probes ----
echo "    scenario 15: max_severity = nit when specialist emits only [nit] probes..."
rm -f "$DB_FILE"
build_bot_review 1500 150 "$(hours_ago 480)" tests \
    '1. [nit] [from: tests] minor naming. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
SEV=$(sqlite3 "$DB_FILE" "SELECT max_severity FROM specialist_runs WHERE specialist='tests';")
assert_eq "$SEV" "nit" "scenario 15: max_severity should be 'nit' when specialist emits only [nit]"

# ---- scenario 16: rewalk where pulls/files returns empty → applied resets ----
echo "    scenario 16: empty pulls/files (force-push to empty diff) → applied resets to 0..."
rm -f "$DB_FILE"
build_bot_review 1600 160 "$(hours_ago 480)" shape \
    '1. [blocking] [from: shape] cycle. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
# First walk: PR touches x.sh — applied should be 1.
export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'x.sh\t10\t2\n' > "$MOCK_PULLS_FILES_FILE"
run_driver
A1=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
assert_eq "$A1" "1|10|2" "scenario 16 first walk: applied|+LOC|-LOC"

# Second walk: PR has zero files (force-push to empty diff). pulls/files
# returns []. With the empty-but-successful fix, clear_applied_for_review
# should still fire and reset applied/LOC to 0.
: > "$MOCK_PULLS_FILES_FILE"   # empty file → stub returns []
run_driver
A2=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
assert_eq "$A2" "0|0|0" "scenario 16 rewalk: applied|+LOC|-LOC must reset on empty pulls/files"

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE

# ---- scenario 17: cited path edited AFTER review → edited_after=1 ----
echo "    scenario 17: post-review commit touches cited path → edited_after=1..."
rm -f "$DB_FILE"
TS_REVIEW=$(hours_ago 20)
TS_COMMIT_AFTER=$(hours_ago 10)   # AFTER review
TS_COMMIT_BEFORE=$(hours_ago 30)  # BEFORE review

build_bot_review 70 40 "$TS_REVIEW" tests,shape \
    '1. [blocking] [from: tests] [tests] Touched-later. Files: src/a.py. Edit: do x.
2. [medium] [from: shape] [shape] Stale. Files: src/b.py. Edit: do y.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"

# Both paths in the PR diff so applied=1 for both.
export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'src/a.py\t10\t0\nsrc/b.py\t5\t0\n' > "$MOCK_PULLS_FILES_FILE"

# Two commits: one AFTER review touches src/a.py only, one BEFORE review touches src/b.py.
printf 'sha-after\t%s\nsha-before\t%s\n' "$TS_COMMIT_AFTER" "$TS_COMMIT_BEFORE" > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

mkdir -p "$TMPDIR_SMOKE/commit-files"
echo "src/a.py" > "$TMPDIR_SMOKE/commit-files/sha-after.tsv"
echo "src/b.py" > "$TMPDIR_SMOKE/commit-files/sha-before.tsv"
export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/commit-files"

run_driver

# tests cited src/a.py which was touched AFTER → edited_after=1
ROW=$(sqlite3 "$DB_FILE" "SELECT applied, edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=70;")
[ "$ROW" = "1|1" ] || { echo "FAIL scenario 17: tests row '$ROW' expected '1|1'"; cat "$OUT_FILE"; exit 1; }
# shape cited src/b.py which was touched BEFORE → edited_after=0
ROW=$(sqlite3 "$DB_FILE" "SELECT applied, edited_after FROM specialist_runs WHERE specialist='shape' AND comment_id=70;")
[ "$ROW" = "1|0" ] || { echo "FAIL scenario 17: shape row '$ROW' expected '1|0'"; cat "$OUT_FILE"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 18: re-walk after new post-review commit flips edited_after 0→1 ----
echo "    scenario 18: re-walk picks up newly-landed post-review commit..."
# Reset the after-commit's file list to empty initially, then add the cited path on rewalk.
printf 'sha-after\t%s\n' "$TS_COMMIT_AFTER" > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"
mkdir -p "$TMPDIR_SMOKE/commit-files-rewalk"
: > "$TMPDIR_SMOKE/commit-files-rewalk/sha-after.tsv"   # empty: no files yet
export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/commit-files-rewalk"

rm -f "$DB_FILE"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=70;")
assert_eq "$ROW" "0" "scenario 18: pre-rewalk edited_after should be 0 (commit has no files yet)"

# Now the rewalk: post-review commit grew to touch src/a.py.
echo "src/a.py" > "$TMPDIR_SMOKE/commit-files-rewalk/sha-after.tsv"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=70;")
assert_eq "$ROW" "1" "scenario 18: post-rewalk edited_after should flip to 1 when commit now touches cited path"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 19: coverage denominator from mixed marker/no-marker reviews ----
echo "    scenario 19: coverage counts substantive bot reviews — total vs with-marker..."
rm -f "$DB_FILE"
TS_R1=$(hours_ago 100)
TS_R2=$(hours_ago 90)
TS_R3=$(hours_ago 80)

TS_R4=$(hours_ago 70)

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
marker_body = "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=tests -->\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] X. Files: src/a.py. Edit: do x.\n\n_How to use: auto-reviews every new PR..._"
no_marker_body = "${BOT_AUTO_POST_MARKER}\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] X.\n\n_How to use: auto-reviews every new PR..._"
ack_body = "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."
# Substantive bot review that MENTIONS knightwatch-bakeoff in prose but lacks
# the real roster marker — must count as in_window (denominator) but NOT as
# with_marker (numerator). Guards against a regression to a permissive
# substring check.
prose_only_body = "${BOT_AUTO_POST_MARKER}\n\n**Overview** — discussing the knightwatch-bakeoff marker shape in this PR.\n\n_How to use: auto-reviews every new PR..._"
comments = [
    {"id": 80, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/50", "created_at": "${TS_R1}", "user": {"login": "testbot"}, "body": marker_body},
    {"id": 81, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/51", "created_at": "${TS_R2}", "user": {"login": "testbot"}, "body": no_marker_body},
    {"id": 82, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/52", "created_at": "${TS_R3}", "user": {"login": "testbot"}, "body": ack_body},
    {"id": 83, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/53", "created_at": "${TS_R4}", "user": {"login": "testbot"}, "body": prose_only_body},
]
print(json.dumps(comments))
PYEOF
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

run_driver

COV=$(sqlite3 "$DB_FILE" "SELECT reviews_total_in_window || '|' || reviews_with_marker_in_window FROM walks WHERE repo='test-org/bakeoff-probe';")
# Expected: 3 substantive bot reviews (id 80 + 81 + 83; ACK 82 excluded because
# it lacks the "How to use" footer); 1 with marker (id 80 only — id 83 has the
# marker token in prose but not the real <!-- ... --> shape).
[ "$COV" = "3|1" ] || { echo "FAIL scenario 19: coverage '$COV' expected '3|1' (prose mention of marker must NOT count)"; sqlite3 "$DB_FILE" "SELECT * FROM walks;"; exit 1; }
# Rendered caption must reflect the exact 1-of-3 → 33% derived from that DB row.
grep -qF "1 of 3 substantive bot reviews carried the roster marker (33%" "$OUT_FILE" \
    || { echo "FAIL scenario 19: caption missing '1 of 3 ... (33%'"; grep -F "carried the roster marker" "$OUT_FILE"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 20: rendered table shape — caption, severity cols, edited col, no aggregator ----
echo "    scenario 20: rendered table — honest caption, severity + edited cols, aggregator omitted..."
rm -f "$DB_FILE"
TS=$(hours_ago 50)

# Four reviews on four PRs, each with a different max severity so the rendered
# tests row has 1 in every severity bucket. Catches drift in Medium/Low+Nit/
# Open columns independently of Blocking (which the prior single-fixture
# version was the only check for).
{ build_bot_review 90 60 "$TS" tests,aggregator \
    '1. [blocking] [from: tests] [tests] X. Files: src/a.py. Edit: do x.'
  build_bot_review 91 61 "$TS" tests,aggregator \
    '1. [medium] [from: tests] [tests] X. Files: src/a.py. Edit: do x.'
  build_bot_review 92 62 "$TS" tests,aggregator \
    '1. [nit] [from: tests] [tests] X. Files: src/a.py. Edit: do x.'
  build_bot_review 93 63 "$TS" tests,aggregator \
    '1. [open] [from: tests] [tests] **Q: foo?** — Q text.'
} | jq -s . > "$MOCK_COMMENTS_FILE"
export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

run_driver

# Header includes coverage caption.
grep -qE '[0-9]+ of [0-9]+ substantive bot reviews carried the roster marker' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing 'N of M ... carried the roster marker' caption"; cat "$OUT_FILE"; exit 1; }

# Header row pins all 6 operator-facing column labels in their rendered order.
grep -qF '| Cited | Edited | Blocking | Medium | Low+Nit | Open |' "$OUT_FILE" \
    || { echo "FAIL scenario 20: header missing one of: Cited|Edited|Blocking|Medium|Low+Nit|Open"; cat "$OUT_FILE"; exit 1; }

# Per-repo coverage subtable is present with the test-org/bakeoff-probe row.
grep -qF '**Per-repo coverage (last 720 h walk)**' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing **Per-repo coverage (last 720 h walk)** header"; cat "$OUT_FILE"; exit 1; }
grep -qE '\| `test-org/bakeoff-probe` \| 4 \| 4 \| 100%' "$OUT_FILE" \
    || { echo "FAIL scenario 20: per-repo row missing or wrong: expected 4/4/100% for test-org/bakeoff-probe"; cat "$OUT_FILE"; exit 1; }

# aggregator must not appear as a data row.
if grep -qE '^\| aggregator ' "$OUT_FILE"; then
    echo "FAIL scenario 20: aggregator row leaked into rendered table"
    cat "$OUT_FILE"
    exit 1
fi

# tests row — field-positional assertion on all 4 severity columns.
# Awk fields with FS=' | ' (the markdown table separator):
#   $1 "| tests", $2 Reviews, $3 Shipped, $4 Cited, $5 Edited,
#   $6 Blocking, $7 Medium, $8 Low+Nit, $9 Open, $10 +LOC, $11 "-LOC |"
TESTS_ROW=$(grep -E '^\| tests ' "$OUT_FILE")
[ -n "$TESTS_ROW" ] || { echo "FAIL scenario 20: tests row missing"; cat "$OUT_FILE"; exit 1; }
SEV=$(echo "$TESTS_ROW" | awk -F' \\| ' '{print $6"|"$7"|"$8"|"$9}')
assert_eq "$SEV" "1|1|1|1" "scenario 20: tests severity columns (Blocking|Medium|Low+Nit|Open) must each be 1"

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 21: transient pulls/commits failure preserves prior edited_after ----
echo "    scenario 21: pulls/commits failure does NOT erase a previously-true edited_after..."
rm -f "$DB_FILE"
TS_REVIEW_21=$(hours_ago 30)
TS_COMMIT_21=$(hours_ago 20)   # AFTER review

export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
setup_edited_after_one_commit 110 70 "$TS_REVIEW_21" src/a.py sha-after "$TS_COMMIT_21" commit-files-21

# First walk: commits fetch succeeds → edited_after=1, OUT_FILE rendered with SENTINEL replaced.
echo SENTINEL > "$OUT_FILE"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=110;")
assert_eq "$ROW" "1" "scenario 21 setup: pre-fail edited_after should be 1 after successful first walk"
grep -q "SENTINEL" "$OUT_FILE" && { echo "FAIL scenario 21 (setup): OUT_FILE not rewritten after success"; exit 1; }

# Re-walk with simulated pulls/commits failure. edited_after must be preserved (data-integrity)
# AND the script must exit non-zero so the partial-run gate preserves OUT_FILE.
echo SENTINEL > "$OUT_FILE"
MOCK_GH_PULLS_COMMITS_FAIL=1 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1 && {
    echo "FAIL scenario 21: expected non-zero exit when pulls/commits fetch fails"
    exit 1
}
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=110;")
assert_eq "$ROW" "1" "scenario 21: edited_after must survive transient pulls/commits failure"
assert_contains "$(cat "$OUT_FILE")" "SENTINEL" "scenario 21: OUT_FILE must not be overwritten on pulls/commits failure"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 22: two reviews on one PR, commit between them → per-review fence ----
echo "    scenario 22: two reviews on one PR with intervening commit — cache key per-review fences edited_after..."
rm -f "$DB_FILE"
TS_R1_22=$(hours_ago 40)
TS_COMMIT_22=$(hours_ago 30)   # between R1 and R2
TS_R2_22=$(hours_ago 20)

{ build_bot_review 120 80 "$TS_R1_22" tests \
    '1. [blocking] [from: tests] [tests] Edited. Files: src/a.py. Edit: do x.'
  build_bot_review 121 80 "$TS_R2_22" tests \
    '1. [blocking] [from: tests] [tests] Edited. Files: src/a.py. Edit: do x.'
} | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
printf 'sha-mid\t%s\n' "$TS_COMMIT_22" > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"
mkdir -p "$TMPDIR_SMOKE/commit-files-22"
echo "src/a.py" > "$TMPDIR_SMOKE/commit-files-22/sha-mid.tsv"
export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/commit-files-22"

run_driver

# R1 saw the commit AFTER it → edited_after=1.
ROW1=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=120;")
assert_eq "$ROW1" "1" "scenario 22: R1 edited_after should be 1 (commit landed after R1)"
# R2 saw no commits after it → edited_after=0.
ROW2=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=121;")
assert_eq "$ROW2" "0" "scenario 22: R2 edited_after should be 0 (no commits after R2)"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 23: committer.date drives edited_after (handles rebased commits) ----
echo "    scenario 23: rebased commit (author.date BEFORE review, committer.date AFTER) → edited_after=1..."
rm -f "$DB_FILE"
TS_REVIEW_23=$(hours_ago 30)
TS_AUTHOR_OLD=$(hours_ago 40)    # BEFORE review (pre-existing on the branch)
TS_COMMITTER_NEW=$(hours_ago 20) # AFTER review (rebase landed it post-review)

build_bot_review 130 90 "$TS_REVIEW_23" tests \
    '1. [blocking] [from: tests] [tests] Cited. Files: src/a.py. Edit: do x.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
# 3-col TSV: sha, author_date (pre-review), committer_date (post-review).
printf 'sha-rebased\t%s\t%s\n' "$TS_AUTHOR_OLD" "$TS_COMMITTER_NEW" > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"
mkdir -p "$TMPDIR_SMOKE/commit-files-23"
echo "src/a.py" > "$TMPDIR_SMOKE/commit-files-23/sha-rebased.tsv"
export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/commit-files-23"

run_driver

ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=130;")
assert_eq "$ROW" "1" "scenario 23: rebased commit should count via committer.date (author/committer date filter)"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 25: post-review RENAME matches the cited (pre-rename) path ----
echo "    scenario 25: post-review rename of cited path → edited_after=1 via previous_filename..."
rm -f "$DB_FILE"
TS_REVIEW_25=$(hours_ago 30)
TS_COMMIT_25=$(hours_ago 20)

build_bot_review 150 110 "$TS_REVIEW_25" tests \
    '1. [blocking] [from: tests] [tests] Cited old path. Files: src/old.py. Edit: do x.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/new.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
printf 'sha-rename\t%s\n' "$TS_COMMIT_25" > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"
mkdir -p "$TMPDIR_SMOKE/commit-files-25"
# TSV: filename<TAB>previous_filename. The cited path src/old.py is the
# previous_filename; the commit's filename is src/new.py.
printf 'src/new.py\tsrc/old.py\n' > "$TMPDIR_SMOKE/commit-files-25/sha-rename.tsv"
export MOCK_COMMIT_FILES_DIR="$TMPDIR_SMOKE/commit-files-25"

run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=150;")
assert_eq "$ROW" "1" "scenario 25: rename of cited path should be matched via previous_filename"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 26: commits/<sha> failure preserves edited_after AND OUT_FILE ----
echo "    scenario 26: commits/<sha> per-commit failure → non-zero exit, edited_after preserved, OUT_FILE preserved..."
rm -f "$DB_FILE"
TS_REVIEW_26=$(hours_ago 30)
TS_COMMIT_26=$(hours_ago 20)

setup_edited_after_one_commit 160 120 "$TS_REVIEW_26" src/a.py sha-x "$TS_COMMIT_26" commit-files-26

# First walk: success → edited_after=1.
echo SENTINEL > "$OUT_FILE"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=160;")
assert_eq "$ROW" "1" "scenario 26 setup: pre-fail edited_after should be 1"

# Re-walk: pulls/commits succeeds, but commits/sha-x fails (per-commit failure).
echo SENTINEL > "$OUT_FILE"
MOCK_GH_COMMIT_FAIL_SHA=sha-x bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1 && {
    echo "FAIL scenario 26: expected non-zero exit on commits/<sha> failure"
    exit 1
}
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=160;")
assert_eq "$ROW" "1" "scenario 26: edited_after must survive commits/<sha> failure"
assert_contains "$(cat "$OUT_FILE")" "SENTINEL" "scenario 26: OUT_FILE must not be overwritten on commits/<sha> failure"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 27: successful rewalk where post-review commit no longer touches cited path → edited_after flips 1→0 ----
echo "    scenario 27: successful rewalk drops stale edited_after when post-review path is no longer touched..."
rm -f "$DB_FILE"
TS_REVIEW_27=$(hours_ago 30)
TS_COMMIT_27=$(hours_ago 20)

setup_edited_after_one_commit 170 130 "$TS_REVIEW_27" src/a.py sha-y "$TS_COMMIT_27" commit-files-27

run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=170;")
assert_eq "$ROW" "1" "scenario 27 setup: pre-rewalk edited_after should be 1"

# Rewalk: same post-review commit, but it no longer touches src/a.py
# (e.g. operator amended the commit to drop that file). Successful fetch,
# successful re-evaluation, edited_after should flip 1→0.
echo "src/other.py" > "$TMPDIR_SMOKE/commit-files-27/sha-y.tsv"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=170;")
assert_eq "$ROW" "0" "scenario 27: stale edited_after must be cleared on successful rewalk when path no longer touched"

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 28: out-of-window comment returned by since= filter is rejected by .created_at fence ----
echo "    scenario 28: comment with created_at older than REWALK_HOURS is rejected even when returned by since=..."
rm -f "$DB_FILE"
TS_OLD=$(date -u -d '60 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -v "-60d" +%Y-%m-%dT%H:%M:%SZ)
TS_RECENT=$(hours_ago 50)

# Two reviews — one with created_at 60 days ago (outside REWALK_HOURS=720), one
# with created_at 50h ago (in window). GitHub's since= filter is updated_at-
# based; the stub returns BOTH since it doesn't filter by created_at. The
# walker's jq predicate must reject the old one via the .created_at >=
# $window_floor fence regardless of what the API returned.
{ build_bot_review 180 140 "$TS_OLD" tests \
    '1. [blocking] [from: tests] [tests] old. Files: src/a.py. Edit: do x.'
  build_bot_review 181 141 "$TS_RECENT" tests \
    '1. [blocking] [from: tests] [tests] recent. Files: src/b.py. Edit: do y.'
} | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/a.py\t1\t0\nsrc/b.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

run_driver

# Old review must not have created a row.
OLD_ROWS=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM specialist_runs WHERE comment_id=180;")
assert_eq "$OLD_ROWS" "0" "scenario 28: out-of-window review must not create rows"
# Recent review should have created its tests row.
NEW_PUB=$(sqlite3 "$DB_FILE" "SELECT published FROM specialist_runs WHERE comment_id=181 AND specialist='tests';")
assert_eq "$NEW_PUB" "1" "scenario 28: in-window review's tests row must be present and published"
# Coverage caption should count 1 of 1, NOT 2 of 2.
COV=$(sqlite3 "$DB_FILE" "SELECT reviews_total_in_window || '|' || reviews_with_marker_in_window FROM walks WHERE repo='test-org/bakeoff-probe';")
assert_eq "$COV" "1|1" "scenario 28: coverage must count 1|1 (out-of-window review must not count)"

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 29: walker/renderer window split — walker sees 2, scorecard renders 1 ----
echo "    scenario 29: REWALK_HOURS=720 vs SCORECARD_DAYS=14 — walker counts both reviews, scorecard renders only the recent one..."
rm -f "$DB_FILE"

# Review A: 20 days (480h) ago — inside walker window (720h) but outside scorecard (14d = 336h).
# Review B: 2 days (48h) ago — inside both windows.
TS_OLD_29=$(hours_ago 480)
TS_RECENT_29=$(hours_ago 48)

{ build_bot_review 190 190 "$TS_OLD_29" tests \
    '1. [blocking] [from: tests] [tests] old-review. Files: src/old.py. Edit: fix it.'
  build_bot_review 191 191 "$TS_RECENT_29" tests \
    '1. [blocking] [from: tests] [tests] recent-review. Files: src/new.py. Edit: fix it.'
} | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/old.py\t1\t0\nsrc/new.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits-29.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits-29.tsv"

# Run with the production-default split: walker 30d, scorecard 14d.
REWALK_HOURS=720 SCORECARD_DAYS=14 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1

# Walker should have counted BOTH reviews (both inside 720h window).
WALKER_COV=$(sqlite3 "$DB_FILE" "SELECT reviews_with_marker_in_window FROM walks WHERE repo='test-org/bakeoff-probe';")
assert_eq "$WALKER_COV" "2" "scenario 29: walker should count both reviews in 720h window"

# Renderer's SCORECARD_DAYS=14 horizon must exclude the 20-day-old review.
# Per-specialist table row for 'tests' must show Reviews=1 (only 48h review in window).
if ! grep -qE '^\| tests \| +1 \|' "$OUT_FILE"; then
    echo "FAIL scenario 29: expected '| tests | 1 |' in per-specialist table (only recent review in 14d scorecard)"
    cat "$OUT_FILE"
    exit 1
fi

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 30: bare defaults — REWALK_HOURS=24, SCORECARD_DAYS=14 unset ----
# Existing scenarios pin both vars to wider values to keep legacy fixtures in window,
# so the production-default contract is otherwise untested. This scenario runs the
# driver with both vars explicitly removed from the environment (env -u) and asserts:
#   1. Rendered header says "last 14 days"  (SCORECARD_DAYS default)
#   2. Coverage heading says "last 24 h walk"  (REWALK_HOURS default)
echo "    scenario 30: bare defaults (REWALK_HOURS=24, SCORECARD_DAYS=14) — header + coverage label..."
rm -f "$DB_FILE"

# One bot review 2h ago — safely inside the default 24h walker window.
TS_30=$(hours_ago 2)
build_bot_review 200 200 "$TS_30" tests \
    '1. [blocking] [from: tests] [tests] default-window probe. Files: src/probe.py. Edit: fix it.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/probe.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits-30.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits-30.tsv"

# Run with BOTH knobs absent — uses the script defaults (24 / 14).
env -u REWALK_HOURS -u SCORECARD_DAYS bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1

# Header must reflect the 14-day default scorecard horizon.
grep -qF '# Specialist bake-off — last 14 days' "$OUT_FILE" \
    || { echo "FAIL scenario 30: default header missing 'last 14 days'"; cat "$OUT_FILE"; exit 1; }

# Coverage heading must reflect the 24h default walk window.
# (total_reviews > 0 because the review above landed a specialist_runs row.)
grep -qF '**Per-repo coverage (last 24 h walk)**' "$OUT_FILE" \
    || { echo "FAIL scenario 30: coverage heading missing '(last 24 h walk)' under defaults"; cat "$OUT_FILE"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 31: fetch-start watermark regression guard ----
# Locks in the contract that walks.last_walked_at is captured BEFORE the
# gh api comments fetch — not after. Stubs date(1) on PATH with a counter
# file: first bare invocation returns T_PRE, all subsequent ones return T_POST.
# -d / -v forms pass through to the real binary so the renderer's window
# math still works. If a future change moves walk_started_at=$(date -u ...) to
# AFTER the fetch (or restores an internal date -u inside set_repo_coverage),
# this scenario fails loudly: walks.last_walked_at would equal T_POST instead
# of T_PRE.
echo "    scenario 31: fetch-start watermark — walks.last_walked_at equals pre-fetch timestamp..."
rm -f "$DB_FILE"

DATE_STUB_PRE="2026-05-18T20:00:00Z"
DATE_STUB_POST="2026-05-18T20:00:10Z"
DATE_STUB_COUNTER="$TMPDIR_SMOKE/date-stub-counter"

# Build a dedicated stub dir so we can remove it cleanly without touching
# STUB_BIN (which holds the gh stub used by all other scenarios).
DATE_STUB_DIR="$TMPDIR_SMOKE/date-stub"
mkdir -p "$DATE_STUB_DIR"

cat > "$DATE_STUB_DIR/date" <<'DATESTUB'
#!/bin/bash
# Pass through -d / -v invocations to the real date binary — these are
# the renderer's window-math calls (e.g. date -u -d "14 days ago" ...).
# Only intercept the bare `date -u +%FT%TZ` form used for walk timestamps.
for arg in "$@"; do
    case "$arg" in
        -d|-v|--date=*) exec /bin/date "$@" ;;
    esac
done
count=$(cat "$DATE_STUB_COUNTER" 2>/dev/null || echo 0)
echo $((count + 1)) > "$DATE_STUB_COUNTER"
if [ "$count" = "0" ]; then
    echo "$DATE_STUB_PRE"
else
    echo "$DATE_STUB_POST"
fi
DATESTUB
chmod +x "$DATE_STUB_DIR/date"

# One bot review 2h ago — safely inside any walker window.
TS_31=$(hours_ago 2)
build_bot_review 210 210 "$TS_31" tests \
    '1. [blocking] [from: tests] [tests] watermark probe. Files: src/watermark.py. Edit: fix it.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/watermark.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits-31.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits-31.tsv"

rm -f "$DATE_STUB_COUNTER"
export DATE_STUB_PRE DATE_STUB_POST DATE_STUB_COUNTER
PATH="$DATE_STUB_DIR:$PATH" bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1

GOT_31=$(sqlite3 "$DB_FILE" "SELECT last_walked_at FROM walks WHERE repo='test-org/bakeoff-probe';")
[ "$GOT_31" = "$DATE_STUB_PRE" ] || {
    echo "FAIL scenario 31: walks.last_walked_at = '$GOT_31', expected '$DATE_STUB_PRE'"
    echo "  (regression — walk_started_at stamp captured AFTER fetch instead of BEFORE)"
    exit 1
}

rm -rf "$DATE_STUB_DIR"
unset MOCK_PULLS_COMMITS_FILE DATE_STUB_PRE DATE_STUB_POST DATE_STUB_COUNTER

# ---- scenario 32: operator-seeded space-format watermark normalizes correctly ----
# Regression for round-4 blocker: an operator who runs the documented deploy
# step (sqlite3 ... datetime('now')) writes last_walked_at in SQLite's space-
# separated format ("2026-05-18 23:00:00"). Without strftime normalization on
# read, that value lex-sorts before an ISO rewalk_floor on the SAME calendar
# day (ASCII space 0x20 < T 0x54), so the buggy comparison
#   "2026-05-18 23:00:00" < "2026-05-18T20:00:00Z"  (REWALK_HOURS=3)
# yields TRUE, and window_floor is set to the seeded space-format value instead
# of rewalk_floor.
#
# Determinism: stubs `date -u -d "3 hours ago" ...` to return a FIXED same-day
# ISO value (2026-05-18T20:00:00Z) via the PATH seam. The seeded watermark is
# also a literal (2026-05-18 23:00:00 space-format). Pure literals — no
# wall-clock dependency, so the test exercises the bug regardless of when it
# runs (including the 00:00–02:59 UTC window where live datetime('now') and
# live date-3h cross calendar days and the bug wouldn't fire).
#
# The critical observable: with the bug, window_floor = the seeded space-format
# value → log reads "scanning ... since 2026-05-18 23:00:00 ..." → sed captures
# "2026-05-18" (stops at space) ≠ rewalk stub value.
# With the fix: normalized last_walked = 2026-05-18T23:00:00Z > rewalk stub
# 2026-05-18T20:00:00Z → comparison FALSE → window_floor = rewalk_floor (ISO)
# → log reads "scanning ... since 2026-05-18T20:00:00Z".
echo "    scenario 32: operator-seeded space-format watermark normalizes correctly (strftime fix)..."
rm -f "$DB_FILE" "$LOG_FILE"

# Switch the tracked repo to normalize-probe so we have an isolated DB state.
cat > "$STATE_DIR/repos.conf" <<'CONF32'
REPOS=("test-org/normalize-probe")
CONF32

# A bot review created 1h ago — well within REWALK_HOURS=3.
TS_32=$(hours_ago 1)
build_bot_review 320 320 "$TS_32" tests \
    '1. [blocking] [from: tests] [tests] normalize probe. Files: src/probe.py. Edit: fix it.' \
    | jq -s . > "$MOCK_COMMENTS_FILE"
printf 'src/probe.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits-32.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits-32.tsv"

# Seed the walks table with a LITERAL space-format watermark — mirrors the
# operator deploy SQL: sqlite3 ... "UPDATE walks SET last_walked_at = datetime('now');"
# datetime('now') returns "YYYY-MM-DD HH:MM:SS" (no T, no Z), not ISO 8601.
# Using a fixed literal makes the test independent of wall-clock.
. "$REPO_ROOT/lib/bakeoff-store.sh"
store_init "$DB_FILE"
sqlite3 "$DB_FILE" "INSERT INTO walks (repo, last_walked_at, reviews_total_in_window, reviews_with_marker_in_window) VALUES ('test-org/normalize-probe', '2026-05-18 23:00:00', 0, 0);"

# Build a date stub: intercept ONLY the walker's rewalk_floor query
# `date -u -d "3 hours ago" +...` and return a fixed same-day ISO value.
# Everything else (bare date -u +%FT%TZ for walk_started_at, the renderer's
# date -u -d "$SCORECARD_DAYS days ago", etc.) passes through to real /bin/date.
DATE_STUB_32_DIR="$TMPDIR_SMOKE/date-stub-32"
mkdir -p "$DATE_STUB_32_DIR"
cat > "$DATE_STUB_32_DIR/date" <<'DATESTUB32'
#!/bin/bash
# Intercept: date -u -d "3 hours ago" +<fmt>  (walker's rewalk_floor call)
# Return a fixed same-day ISO value so the space-vs-T comparison is exercised
# regardless of what the real wall clock says.
if [ "$1" = "-u" ] && [ "$2" = "-d" ] && [ "$3" = "3 hours ago" ]; then
    echo "2026-05-18T20:00:00Z"
    exit 0
fi
exec /bin/date "$@"
DATESTUB32
chmod +x "$DATE_STUB_32_DIR/date"

# Run with REWALK_HOURS=3 (arg that produces the "3 hours ago" -d form the stub
# intercepts) and date stub on PATH. With the strftime fix:
#   normalized last_walked = 2026-05-18T23:00:00Z
#   rewalk_floor (stub)    = 2026-05-18T20:00:00Z
#   last_walked > rewalk_floor → comparison FALSE → window_floor = rewalk_floor
# Without the fix:
#   last_walked = "2026-05-18 23:00:00" (raw space-format)
#   lex compare: "2026-05-18 " < "2026-05-18T" → TRUE → window_floor = seeded value
PATH="$DATE_STUB_32_DIR:$PATH" REWALK_HOURS=3 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1

# Assertion: log must show the rewalk_floor stub value as window_floor.
# A regression to non-normalized read would log the seeded space-format value
# ("2026-05-18 23:00:00"), causing sed to capture only "2026-05-18" (stops at
# space) — definitively not the rewalk stub.
FLOOR_LOGGED_32=$(grep "scanning test-org/normalize-probe since" "$LOG_FILE" \
    | sed 's/.*since \([^ ]*\) .*/\1/' | tail -1)
[ "$FLOOR_LOGGED_32" = "2026-05-18T20:00:00Z" ] || {
    echo "FAIL scenario 32: window_floor in log was '$FLOOR_LOGGED_32', expected '2026-05-18T20:00:00Z' (strftime normalization regressed?)"
    grep "scanning test-org/normalize-probe" "$LOG_FILE" || true
    exit 1
}

# Restore the default tracked repo for any future scenarios.
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("test-org/bakeoff-probe")
CONF

rm -rf "$DATE_STUB_32_DIR"
unset MOCK_PULLS_COMMITS_FILE

echo "PASS"
