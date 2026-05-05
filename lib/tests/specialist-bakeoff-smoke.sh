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
    for arg in "$@"; do
        case "$arg" in
            --paginate) paginate=1 ;;
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

# Single tracked repo.
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("test-org/bakeoff-probe")
CONF

run_driver() {
    bash "$REPO_ROOT/specialist-bakeoff.sh" >/dev/null 2>&1
}

# ---- scenario 1: no comments → empty table ----
echo "    scenario 1: no comments → empty table body..."
run_driver
# Table header is always present; no data rows expected.
if grep -qE '^\| [a-z]' "$OUT_FILE"; then
    echo "FAIL scenario 1: expected empty table body, got rows in $OUT_FILE"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 2: substantive review, ACK, untrusted memorize, trusted memorize ----
echo "    scenario 2: review + ACK + memorize (trusted+untrusted) → aggregator 1|1..."
# Four comments split across two pages — load-bearing comment D is on page 2:
#   A: substantive bot review — has marker, has footer, has [from: aggregator]
#   B: same-bot ACK — has marker, NO footer — must NOT count as a review
#   C: untrusted /srosro-memorize quoting [from: aggregator] — must be ignored
#   D: (PAGE 2) trusted /srosro-memorize quoting [from: aggregator] — must count
# A regression that drops --paginate would still produce Loved=0 (page-2
# trusted memorize never reaches extract_memorize_attributions), so the
# aggregator | 1 | 1 assertion below is the load-bearing pagination check.

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 1, "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n**Probes**\n\n1. [blocking] [from: aggregator] The aggregator logic is overfit.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
    {"id": 2, "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."},
    {"id": 3, "user": {"login": "untrusted-user"}, "body": "Thanks! /srosro-memorize I agree with [from: aggregator] finding."},
]
print(json.dumps(comments))
PYEOF

export MOCK_COMMENTS_FILE_PAGE2="$TMPDIR_SMOKE/comments-page2.json"
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE_PAGE2"
import json
comments = [
    {"id": 4, "user": {"login": "trusted-human"},  "body": "/srosro-memorize The [from: aggregator] tip was great."},
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
# Shipped=1 (one substantive review), Loved=1 (one trusted memorize from page 2).
# If --paginate were dropped, the page-2 trusted memorize would never reach
# extract_memorize_attributions and Loved would be 0 — this is the load-bearing
# pagination assertion.
if ! grep -qE '\| aggregator \| +1 \| +1 \|' "$OUT_FILE"; then
    echo "FAIL scenario 2: expected aggregator | 1 | 1 in table (page-2 memorize not merged)"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 3: spoof — non-bot user posts marker → must NOT count ----
echo "    scenario 3: spoof marker from non-bot user → not counted..."
python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json
comments = [
    {"id": 10, "user": {"login": "evil-actor"}, "body": "${BOT_AUTO_POST_MARKER}\n\n[from: aggregator] fake review.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
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

echo "PASS"
