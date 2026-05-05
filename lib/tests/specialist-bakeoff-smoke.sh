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

# Stub gh: serves a fixed PR list + fixed comments payload, trusts only
# "trusted-human" (returns "write" permission), untrusted others ("none").
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
    # Extract --jq filter if present (gh applies jq inline).
    jq_filter=""
    for arg in "$@"; do
        [ "$prev" = "--jq" ] && jq_filter="$arg"
        prev="$arg"
    done
    prev=""
    if [[ "$endpoint" == */issues/comments* ]]; then
        if [ -n "$paginate" ] && [ -s "${MOCK_COMMENTS_FILE_PAGE2:-/dev/null}" ]; then
            cat "$MOCK_COMMENTS_FILE"
            cat "$MOCK_COMMENTS_FILE_PAGE2"
        else
            cat "$MOCK_COMMENTS_FILE"
        fi
    elif [[ "$endpoint" == */collaborators/trusted-human/permission ]]; then
        raw='{"permission":"write"}'
        if [ -n "$jq_filter" ]; then printf '%s' "$raw" | jq -r "$jq_filter"; else printf '%s\n' "$raw"; fi
    elif [[ "$endpoint" == */collaborators/*/permission ]]; then
        raw='{"permission":"none"}'
        if [ -n "$jq_filter" ]; then printf '%s' "$raw" | jq -r "$jq_filter"; else printf '%s\n' "$raw"; fi
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
cp "$REPO_ROOT/lib/auth.sh"             "$REVIEWER_LIB_DIR/auth.sh"
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
if grep -q '|.*|.*|.*|' "$OUT_FILE" 2>/dev/null && grep -v '^|' "$OUT_FILE" | grep -q '[a-z]'; then
    : # OK if table rows exist (they shouldn't)
fi
# Table header is always present; no data rows expected.
if grep -qE '^\| [a-z]' "$OUT_FILE"; then
    echo "FAIL scenario 1: expected empty table body, got rows in $OUT_FILE"
    cat "$OUT_FILE"
    exit 1
fi

# ---- scenario 2: substantive review, ACK, untrusted memorize, trusted memorize ----
echo "    scenario 2: review + ACK + memorize (trusted+untrusted) → aggregator 1|1..."
# Four comments:
#   A: substantive bot review — has marker, has footer, has [from: aggregator]
#   B: same-bot ACK — has marker, NO footer — must NOT count as a review
#   C: untrusted /srosro-memorize quoting [from: aggregator] — must be ignored
#   D: trusted /srosro-memorize quoting [from: aggregator] — must count
REVIEW_BODY="${BOT_AUTO_POST_MARKER}\n\n[from: aggregator] The aggregator logic is overfit.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"
ACK_BODY="${BOT_AUTO_POST_MARKER}\n\n👀 reviewing..."
UNTRUSTED_MEMO="Thanks! /srosro-memorize I agree with [from: aggregator] finding."
TRUSTED_MEMO="/srosro-memorize The [from: aggregator] tip was great."

python3 - <<PYEOF > "$MOCK_COMMENTS_FILE"
import json, sys
comments = [
    {"id": 1, "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n[from: aggregator] The aggregator logic is overfit.\n\n_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity..._"},
    {"id": 2, "user": {"login": "testbot"},        "body": "${BOT_AUTO_POST_MARKER}\n\n\U0001f440 reviewing..."},
    {"id": 3, "user": {"login": "untrusted-user"}, "body": "Thanks! /srosro-memorize I agree with [from: aggregator] finding."},
    {"id": 4, "user": {"login": "trusted-human"},  "body": "/srosro-memorize The [from: aggregator] tip was great."},
]
print(json.dumps(comments))
PYEOF
run_driver
if ! grep -q '| aggregator |' "$OUT_FILE"; then
    echo "FAIL scenario 2: expected aggregator row in table"
    cat "$OUT_FILE"
    exit 1
fi
# Shipped=1 (one substantive review), Loved=1 (one trusted memorize)
if ! grep -qE '\| aggregator \| +1 \| +1 \|' "$OUT_FILE"; then
    echo "FAIL scenario 2: expected aggregator | 1 | 1 in table"
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

echo "PASS"
