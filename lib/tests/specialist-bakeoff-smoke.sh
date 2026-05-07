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
        if [ -n "$paginate" ] && [ -s "${MOCK_COMMENTS_FILE_PAGE2:-/dev/null}" ]; then
            cat "$MOCK_COMMENTS_FILE"
            cat "$MOCK_COMMENTS_FILE_PAGE2"
        else
            cat "$MOCK_COMMENTS_FILE"
        fi
    elif [[ "$endpoint" == */collaborators* ]]; then
        printf '[{"login":"trusted-human","permissions":{"push":true}},{"login":"untrusted-user","permissions":{"push":false}}]\n'
    elif [[ "$endpoint" == */pulls/*/files* ]]; then
        # Driver feeds the touched-files set via MOCK_PULLS_FILES_FILE.
        # Each line is a path. Real `gh` runs --jq server-side; we mirror
        # by piping through jq when --jq was passed.
        if [ -s "${MOCK_PULLS_FILES_FILE:-/dev/null}" ]; then
            files_json=$(jq -nR '[inputs | {filename: .}]' < "$MOCK_PULLS_FILES_FILE")
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

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 1, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "2026-04-15T12:00:00Z", "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=aggregator,tests,security,shape -->\n\n**Probes**\n\n1. [blocking] [from: aggregator] The aggregator logic is overfit.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
    {"id": 2, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "2026-04-15T12:01:00Z", "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."},
    {"id": 3, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "2026-04-15T12:30:00Z", "user": {"login": "untrusted-user"}, "body": "Thanks! /srosro-memorize I agree with [from: aggregator] finding."},
]
print(json.dumps(comments))
PYEOF

export MOCK_COMMENTS_FILE_PAGE2="$TMPDIR_SMOKE/comments-page2.json"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE_PAGE2"
import json
comments = [
    {"id": 4, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/20", "created_at": "2026-04-15T13:00:00Z", "user": {"login": "trusted-human"},  "body": "/srosro-memorize The [from: aggregator] tip was great."},
]
print(json.dumps(comments))
PYEOF

run_driver
unset MOCK_COMMENTS_FILE_PAGE2
rm -f "$TMPDIR_SMOKE/comments-page2.json"

if ! grep -q '| aggregator |' "$OUT_FILE"; then
    echo "FAIL scenario 2: expected aggregator row in table"
    cat "$OUT_FILE"
    exit 1
fi
# 7-col table: | spec | Reviews | Shipped | Applied | Loved | Critiqued | Loved/Shipped |
# Reviews=1 (one row in store for aggregator), Shipped=1 (probe attributed),
# Applied=0 (no Files: clause), Loved=1 (page-2 trusted memorize), Critiqued=0.
# If --paginate were dropped, the page-2 trusted memorize would never reach
# extract_memorize_attributions and Loved would be 0 — this is the load-bearing
# pagination assertion.
if ! grep -qE '\| aggregator \| +1 \| +1 \| +0 \| +1 \| +0 \| +1\.00 \|' "$OUT_FILE"; then
    echo "FAIL scenario 2: expected aggregator | 1 | 1 | 0 | 1 | 0 | 1.00 in table"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 3: spoof — non-bot user posts marker → must NOT count ----
echo "    scenario 3: spoof marker from non-bot user → not counted..."
rm -f "$DB_FILE"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 10, "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/30", "created_at": "2026-04-15T12:00:00Z", "user": {"login": "evil-actor"}, "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=aggregator,tests,security,shape -->\n\n**Probes**\n\n1. [blocking] [from: aggregator] fake review — would count under count_attributions if bot-user selector regressed.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
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

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
body = (
    "<!-- knightwatch-reviewer:auto-post -->\n"
    "<!-- knightwatch-bakeoff: specialists=shape,tests -->\n\n"
    "**Probes**\n\n"
    "1. [blocking] [from: shape] [shape] Foo. Files: x.sh. Edit: y.\n\n"
    "_How to use: auto-reviews every new PR..._"
)
print(json.dumps([{
    "id": 100,
    "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/42",
    "created_at": "2026-04-15T12:00:00Z",
    "user": {"login": "testbot"},
    "body": body,
}]))
PYEOF

export MOCK_PULLS_FILES_FILE="$TMPDIR_SMOKE/pulls-files.txt"
printf 'x.sh\n' > "$MOCK_PULLS_FILES_FILE"

run_driver

rm -f "$MOCK_PULLS_FILES_FILE"
unset MOCK_PULLS_FILES_FILE

if ! grep -qE '\| shape \| +1 \| +1 \| +1 \| +0 \| +0 \| +0\.00 \|' "$OUT_FILE"; then
    echo "FAIL scenario 5: expected shape | 1 | 1 | 1 | 0 | 0 | 0.00 in table"
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
    "created_at": "2026-04-15T12:00:00Z",
    "user": {"login": "testbot"},
    "body": "${BOT_AUTO_POST_MARKER}\n\n**Probes**\n\n1. [blocking] [from: tests] missing test. Files: x.sh.\n\n_How to use: auto-reviews every new PR..._"
}]))
PYEOF
run_driver
ROW_COUNT=$(sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM specialist_runs;")
[ "$ROW_COUNT" = "0" ] || { echo "FAIL scenario 6: marker-less review created rows ($ROW_COUNT)"; exit 1; }

# ---- scenario 7: trusted /kw-props after substantive review → loved_positive=1 ----
echo "    scenario 7: trusted /kw-props after substantive review → loved_positive=1..."
rm -f "$DB_FILE"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
print(json.dumps([
    {
        "id": 700,
        "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/70",
        "created_at": "2026-04-15T12:00:00Z",
        "user": {"login": "testbot"},
        "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=tests,shape -->\n\n**Probes**\n\n1. [blocking] [from: tests] missing test. Files: x.sh.\n\n_How to use: auto-reviews every new PR..._"
    },
    {
        "id": 701,
        "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/70",
        "created_at": "2026-04-15T13:00:00Z",
        "user": {"login": "trusted-human"},
        "body": "/kw-props [from: tests] solid catch"
    }
]))
PYEOF
run_driver
LOVED=$(sqlite3 "$DB_FILE" "SELECT loved_positive FROM specialist_runs WHERE specialist='tests';")
[ "$LOVED" = "1" ] || { echo "FAIL scenario 7: kw-props did not mark loved_positive (got '$LOVED')"; exit 1; }

# ---- scenario 8: trusted /kw-critique after substantive review → loved_negative=1 ----
echo "    scenario 8: trusted /kw-critique after substantive review → loved_negative=1..."
rm -f "$DB_FILE"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
print(json.dumps([
    {
        "id": 800,
        "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/80",
        "created_at": "2026-04-15T12:00:00Z",
        "user": {"login": "testbot"},
        "body": "${BOT_AUTO_POST_MARKER}\n<!-- knightwatch-bakeoff: specialists=shape,tests -->\n\n**Probes**\n\n1. [blocking] [from: shape] cycle. Files: x.sh.\n\n_How to use: auto-reviews every new PR..._"
    },
    {
        "id": 801,
        "issue_url": "https://api.github.com/repos/srosro/test-repo/issues/80",
        "created_at": "2026-04-15T13:00:00Z",
        "user": {"login": "trusted-human"},
        "body": "/kw-critique [from: shape] misread"
    }
]))
PYEOF
run_driver
CRIT=$(sqlite3 "$DB_FILE" "SELECT loved_negative FROM specialist_runs WHERE specialist='shape';")
[ "$CRIT" = "1" ] || { echo "FAIL scenario 8: kw-critique did not mark loved_negative (got '$CRIT')"; exit 1; }

# ---- scenario 9: re-running walker is idempotent (rows + flags unchanged) ----
echo "    scenario 9: re-walk on same input is idempotent..."
# Don't rm DB — reuse scenario 8's state, run again.
BEFORE=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(loved_negative) FROM specialist_runs;")
run_driver
AFTER=$(sqlite3 "$DB_FILE" "SELECT COUNT(*), SUM(loved_negative) FROM specialist_runs;")
[ "$BEFORE" = "$AFTER" ] || { echo "FAIL scenario 9: re-walk changed state (before=$BEFORE after=$AFTER)"; exit 1; }

echo "PASS"
