#!/usr/bin/env bash
# Hermetic smoke for the bake-off parsers AND the driver (specialist-bakeoff.sh).
# No network, no real gh — a stub replaces gh on PATH.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_ROOT/lib/bakeoff-parsers.sh"

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
if [ "$got" != "$want" ]; then
    echo "FAIL: memorize-quoted should attribute to simplification, got '$got'"
    exit 1
fi

echo "  extract_memorize_attributions: unquoted memorize attributes to nobody..."
got=$(extract_memorize_attributions < "$FIX_DIR/memorize-no-quote.md") || true
if [ -n "$got" ]; then
    echo "FAIL: memorize-no-quote should produce no attribution, got '$got'"
    exit 1
fi

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

TMPDIR_SMOKE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SMOKE"' EXIT

export STATE_DIR="$TMPDIR_SMOKE/state"
export OUT_FILE="$STATE_DIR/specialist-bakeoff.md"
export LOG_FILE="$STATE_DIR/bakeoff.log"
export DB_FILE="$STATE_DIR/bakeoff.db"
export BOT_USER="testbot"
export BOT_AUTO_POST_MARKER="<!-- knightwatch-reviewer:auto-post -->"
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
        # Honor since= query param: filter mock comments by created_at >= since.
        # If no since= present, return all (for scenarios that don't care about
        # watermark behavior).
        SINCE=""
        if [[ "$endpoint" == *since=* ]]; then
            SINCE="${endpoint#*since=}"
            SINCE="${SINCE%%&*}"
        fi
        _filter() {
            if [ -n "$SINCE" ]; then
                jq --arg since "$SINCE" '[.[] | select(.created_at >= $since)]'
            else
                jq '.'
            fi
        }
        if [ -n "$paginate" ] && [ -s "${MOCK_COMMENTS_FILE_PAGE2:-/dev/null}" ]; then
            cat "$MOCK_COMMENTS_FILE" | _filter
            cat "$MOCK_COMMENTS_FILE_PAGE2" | _filter
        else
            cat "$MOCK_COMMENTS_FILE" | _filter
        fi
    elif [[ "$endpoint" == */collaborators* ]]; then
        printf '[{"login":"trusted-human","permissions":{"push":true}},{"login":"untrusted-user","permissions":{"push":false}}]\n'
    elif [[ "$endpoint" == */pulls/*/commits* ]] && [ -n "${MOCK_GH_PULLS_COMMITS_FAIL:-}" ]; then
        echo "gh api: simulated pulls/commits failure" >&2
        exit 1
    elif [[ "$endpoint" == */pulls/*/commits* ]]; then
        # MOCK_PULLS_COMMITS_FILE: TSV of sha\tauthor_date per line.
        if [ -s "${MOCK_PULLS_COMMITS_FILE:-/dev/null}" ]; then
            commits_json=$(awk -F'\t' 'BEGIN{first=1; print "["}
{
    if (first) first=0; else print ",";
    printf "{\"sha\":\"%s\",\"commit\":{\"author\":{\"date\":\"%s\"}}}", $1, $2
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
    elif [[ "$endpoint" == */commits/* ]]; then
        # MOCK_COMMIT_FILES_DIR/<sha>.tsv: one filename per line.
        sha="${endpoint##*/commits/}"
        sha="${sha%%\?*}"
        files_file="${MOCK_COMMIT_FILES_DIR:-/dev/null}/$sha.tsv"
        if [ -s "$files_file" ]; then
            files_json=$(awk 'BEGIN{first=1; print "["}
{
    if (first) first=0; else print ",";
    printf "{\"filename\":\"%s\"}", $0
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
# from this so they stay safely inside the walker's WINDOW_DAYS=30 lookback
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

if grep -q '^| aggregator ' "$OUT_FILE"; then
    echo "FAIL scenario 2: aggregator row must be filtered out of rendered table"
    cat "$OUT_FILE"
    exit 1
fi
# But aggregator's loved_positive should still be persisted in the DB.
LOVED_AGG=$(sqlite3 "$DB_FILE" "SELECT loved_positive FROM specialist_runs WHERE specialist='aggregator' AND comment_id=1;")
if [ "$LOVED_AGG" != "1" ]; then
    echo "FAIL scenario 2: aggregator loved_positive not persisted (got '$LOVED_AGG')"
    exit 1
fi

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
[ "$ROW_COUNT" = "0" ] || { echo "FAIL scenario 6: marker-less review created rows ($ROW_COUNT)"; exit 1; }

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
[ "$LOVED" = "1" ] || { echo "FAIL scenario 7: srosro-props did not mark loved_positive (got '$LOVED')"; exit 1; }

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
[ "$CRIT" = "1" ] || { echo "FAIL scenario 8: srosro-critique did not mark critiqued (got '$CRIT')"; exit 1; }

# ---- scenario 9: re-running walker is idempotent (rows + flags unchanged) ----
echo "    scenario 9: re-walk on same input is idempotent..."
# Don't rm DB — reuse scenario 8's state, run again.
BEFORE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(critiqued) FROM specialist_runs;")
run_driver
AFTER=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(critiqued) FROM specialist_runs;")
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL scenario 9: re-walk changed state (before=$BEFORE after=$AFTER)"; exit 1; }

# ---- scenario 10: successful walk advances watermark to max review created_at ----
echo "    scenario 10: watermark advances to max review created_at on success..."
rm -f "$DB_FILE"
TS_FIRST=$(hours_ago 480)
TS_SECOND=$(hours_ago 456)  # 24h after TS_FIRST → 19 days ago
{ build_bot_review 1000 100 "$TS_FIRST" tests \
    '1. [blocking] [from: tests] missing test. Files: x.sh.'
  build_bot_review 1001 100 "$TS_SECOND" tests \
    '1. [blocking] [from: tests] another missing test. Files: y.sh.'; } \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
WM=$(sqlite3 "$DB_FILE" "SELECT last_walked_at FROM walks WHERE repo='test-org/bakeoff-probe';")
[ "$WM" = "$TS_SECOND" ] || { echo "FAIL scenario 10: watermark='$WM' (expected the later timestamp $TS_SECOND)"; exit 1; }

# ---- scenario 11: pulls/files failure HOLDS the watermark (does not advance) ----
echo "    scenario 11: pulls/files failure holds watermark (per-repo failure gating)..."
rm -f "$DB_FILE"
TS_SEED=$(hours_ago 480)
TS_NEW=$(hours_ago 240)  # 10 days ago — both safely in window, new > seed
# Seed a watermark via a successful initial run
build_bot_review 1100 110 "$TS_SEED" tests \
    '1. [blocking] [from: tests] foo. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
SEEDED_WM=$(sqlite3 "$DB_FILE" "SELECT last_walked_at FROM walks WHERE repo='test-org/bakeoff-probe';")

# Now run again with new comments + simulated pulls/files failure
build_bot_review 1101 111 "$TS_NEW" tests \
    '1. [blocking] [from: tests] bar. Files: y.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
echo "SENTINEL" > "$OUT_FILE"
MOCK_GH_PULLS_FILES_FAIL=1 bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1 && {
    echo "FAIL scenario 11: expected non-zero exit when pulls/files fails"
    exit 1
}
unset MOCK_GH_PULLS_FILES_FAIL
HELD_WM=$(sqlite3 "$DB_FILE" "SELECT last_walked_at FROM walks WHERE repo='test-org/bakeoff-probe';")
[ "$HELD_WM" = "$SEEDED_WM" ] || { echo "FAIL scenario 11: watermark advanced despite pulls/files failure (was '$SEEDED_WM' now '$HELD_WM')"; exit 1; }
grep -q "SENTINEL" "$OUT_FILE" || { echo "FAIL scenario 11: OUT_FILE was overwritten despite failure"; exit 1; }

# ---- scenario 12: max_severity tracks the worst severity per specialist ----
echo "    scenario 12: max_severity = blocking when specialist emits [blocking] + [medium] probes..."
rm -f "$DB_FILE"
build_bot_review 1200 120 "$(hours_ago 480)" tests \
    '1. [medium] [from: tests] one issue. Files: x.sh.\n2. [blocking] [from: tests] worse issue. Files: y.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
SEV=$(sqlite3 "$DB_FILE" "SELECT max_severity FROM specialist_runs WHERE specialist='tests';")
[ "$SEV" = "blocking" ] || { echo "FAIL scenario 12: max_severity='$SEV' (expected 'blocking')"; exit 1; }

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
[ "$A1" = "1|10|2" ] || { echo "FAIL scenario 13 first walk: '$A1'"; exit 1; }

# Second walk: PR no longer touches x.sh (force-push removed those changes).
# Applied should reset to 0; LOC should reset to 0.
printf 'unrelated.sh\t99\t0\n' > "$MOCK_PULLS_FILES_FILE"
run_driver
A2=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
[ "$A2" = "0|0|0" ] || { echo "FAIL scenario 13 rewalk: expected '0|0|0', got '$A2'"; exit 1; }

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE

# ---- scenario 14: late-arriving /srosro-props within OVERLAP_HOURS is still credited ----
echo "    scenario 14: late /srosro-props within OVERLAP_HOURS=24 still marks loved_positive..."
rm -f "$DB_FILE"

# First walk: seed a review at T1 (watermark advances to T1).
T1=$(hours_ago 480)
build_bot_review 1400 140 "$T1" tests '1. [blocking] [from: tests] foo. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
WM=$(sqlite3 "$DB_FILE" "SELECT last_walked_at FROM walks WHERE repo='test-org/bakeoff-probe';")
[ "$WM" = "$T1" ] || { echo "FAIL scenario 14 setup: watermark='$WM'"; exit 1; }

# Second walk: a previously-unseen earlier review at T1 - 12h plus its
# /srosro-props at T1 - 2h. Both are "behind the watermark" (created_at < T1)
# but within OVERLAP_HOURS=24 lookback. Without the overlap slack the walker
# would compute since=$T1 raw, the gh stub's since= filter would drop both,
# and the loved_positive flag would never get set. With OVERLAP=24h the walker
# computes since=T1 - 24h, both comments are returned, and the feedback at
# T1 - 2h attributes to the new review at T1 - 12h.
T_PRIOR=$(hours_ago 492)  # T1 - 12h
T_LATE=$(hours_ago 482)   # T1 - 2h (still > T_PRIOR)
{ build_bot_review 1400 140 "$T1" tests '1. [blocking] [from: tests] foo. Files: x.sh.'
  build_bot_review 1402 140 "$T_PRIOR" tests '1. [blocking] [from: tests] earlier finding. Files: x.sh.'
  build_feedback_comment 1401 140 "$T_LATE" '/srosro-props [from: tests] late but real'; } \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
LOVED=$(sqlite3 "$DB_FILE" "SELECT loved_positive FROM specialist_runs WHERE specialist='tests' AND comment_id=1402;")
[ "$LOVED" = "1" ] || { echo "FAIL scenario 14: late /srosro-props within overlap not credited (loved_positive='$LOVED')"; exit 1; }

# ---- scenario 15: max_severity=nit when specialist emits only [nit] probes ----
echo "    scenario 15: max_severity = nit when specialist emits only [nit] probes..."
rm -f "$DB_FILE"
build_bot_review 1500 150 "$(hours_ago 480)" tests \
    '1. [nit] [from: tests] minor naming. Files: x.sh.' \
    | jq -s '.' > "$MOCK_COMMENTS_FILE"
run_driver
SEV=$(sqlite3 "$DB_FILE" "SELECT max_severity FROM specialist_runs WHERE specialist='tests';")
[ "$SEV" = "nit" ] || { echo "FAIL scenario 15: max_severity='$SEV' (expected 'nit')"; exit 1; }

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
[ "$A1" = "1|10|2" ] || { echo "FAIL scenario 16 first walk: '$A1'"; exit 1; }

# Second walk: PR has zero files (force-push to empty diff). pulls/files
# returns []. With the empty-but-successful fix, clear_applied_for_review
# should still fire and reset applied/LOC to 0.
: > "$MOCK_PULLS_FILES_FILE"   # empty file → stub returns []
run_driver
A2=$(sqlite3 "$DB_FILE" "SELECT applied, applied_added, applied_removed FROM specialist_runs WHERE specialist='shape';")
[ "$A2" = "0|0|0" ] || { echo "FAIL scenario 16 rewalk with empty pulls/files: expected '0|0|0', got '$A2'"; exit 1; }

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE

# ---- scenario 17: cited path edited AFTER review → edited_after=1 ----
echo "    scenario 17: post-review commit touches cited path → edited_after=1..."
rm -f "$DB_FILE"
TS_REVIEW=$(hours_ago 20)
TS_COMMIT_AFTER=$(hours_ago 10)   # AFTER review
TS_COMMIT_BEFORE=$(hours_ago 30)  # BEFORE review

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
body = "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=tests,shape -->\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] Touched-later. Files: src/a.py. Edit: do x.\n2. [medium] [from: shape] [shape] Stale. Files: src/b.py. Edit: do y.\n\n_How to use: auto-reviews every new PR..._"
print(json.dumps([{"id": 70, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/40", "created_at": "${TS_REVIEW}", "user": {"login": "testbot"}, "body": body}]))
PYEOF

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
[ "$ROW" = "0" ] || { echo "FAIL scenario 18: pre-rewalk edited_after '$ROW' expected '0'"; exit 1; }

# Now the rewalk: post-review commit grew to touch src/a.py.
echo "src/a.py" > "$TMPDIR_SMOKE/commit-files-rewalk/sha-after.tsv"
run_driver
ROW=$(sqlite3 "$DB_FILE" "SELECT edited_after FROM specialist_runs WHERE specialist='tests' AND comment_id=70;")
[ "$ROW" = "1" ] || { echo "FAIL scenario 18: post-rewalk edited_after '$ROW' expected '1'"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE MOCK_COMMIT_FILES_DIR

# ---- scenario 19: coverage denominator from mixed marker/no-marker reviews ----
echo "    scenario 19: coverage counts substantive bot reviews — total vs with-marker..."
rm -f "$DB_FILE"
TS_R1=$(hours_ago 100)
TS_R2=$(hours_ago 90)
TS_R3=$(hours_ago 80)

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
marker_body = "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=tests -->\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] X. Files: src/a.py. Edit: do x.\n\n_How to use: auto-reviews every new PR..._"
no_marker_body = "${BOT_AUTO_POST_MARKER}\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] X.\n\n_How to use: auto-reviews every new PR..._"
ack_body = "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."
comments = [
    {"id": 80, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/50", "created_at": "${TS_R1}", "user": {"login": "testbot"}, "body": marker_body},
    {"id": 81, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/51", "created_at": "${TS_R2}", "user": {"login": "testbot"}, "body": no_marker_body},
    {"id": 82, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/52", "created_at": "${TS_R3}", "user": {"login": "testbot"}, "body": ack_body},
]
print(json.dumps(comments))
PYEOF
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

run_driver

COV=$(sqlite3 "$DB_FILE" "SELECT reviews_total_in_window || '|' || reviews_with_marker_in_window FROM walks WHERE repo='test-org/bakeoff-probe';")
# Expected: 2 substantive bot reviews (id 80 + 81; ACK 82 excluded because it lacks the "How to use" footer), 1 with marker.
[ "$COV" = "2|1" ] || { echo "FAIL scenario 19: coverage '$COV' expected '2|1'"; sqlite3 "$DB_FILE" "SELECT * FROM walks;"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE

# ---- scenario 20: rendered table shape — caption, severity cols, edited col, no aggregator ----
echo "    scenario 20: rendered table — honest caption, severity + edited cols, aggregator omitted..."
rm -f "$DB_FILE"
TS=$(hours_ago 50)

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
body = "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=tests,aggregator -->\n\n**Probes**\n\n1. [blocking] [from: tests] [tests] X. Files: src/a.py. Edit: do x.\n2. [open] [from: aggregator] **Q: foo?** — Q text.\n\n_How to use: auto-reviews every new PR..._"
print(json.dumps([{"id": 90, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/60", "created_at": "${TS}", "user": {"login": "testbot"}, "body": body}]))
PYEOF
export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'src/a.py\t1\t0\n' > "$MOCK_PULLS_FILES_FILE"
: > "$TMPDIR_SMOKE/commits.tsv"
export MOCK_PULLS_COMMITS_FILE="$TMPDIR_SMOKE/commits.tsv"

run_driver

# Header includes coverage caption.
grep -qE 'Based on [0-9]+ of [0-9]+' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing 'Based on N of M' caption"; cat "$OUT_FILE"; exit 1; }

# Header lists the new columns.
grep -qE '\| Blocking \|' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing Blocking column header"; cat "$OUT_FILE"; exit 1; }
grep -qE '\| Edited \|' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing Edited column header"; cat "$OUT_FILE"; exit 1; }
grep -qE '\| Cited \|' "$OUT_FILE" \
    || { echo "FAIL scenario 20: missing Cited column header"; cat "$OUT_FILE"; exit 1; }

# aggregator must not appear as a data row.
if grep -qE '^\| aggregator ' "$OUT_FILE"; then
    echo "FAIL scenario 20: aggregator row leaked into rendered table"
    cat "$OUT_FILE"
    exit 1
fi

# tests row contains the new bucket counts.
TESTS_ROW=$(grep -E '^\| tests ' "$OUT_FILE")
[ -n "$TESTS_ROW" ] || { echo "FAIL scenario 20: tests row missing"; cat "$OUT_FILE"; exit 1; }
# Probe was [blocking] → Blocking bucket should be 1.
echo "$TESTS_ROW" | grep -qE '\| 1 \|' \
    || { echo "FAIL scenario 20: tests row missing blocking=1: $TESTS_ROW"; exit 1; }

unset MOCK_PULLS_COMMITS_FILE

echo "PASS"
