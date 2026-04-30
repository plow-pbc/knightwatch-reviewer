#!/bin/bash
# Smoke test for learn-from-replies.sh.
#
# Focused on the regression-test gap knightwatch flagged on PR #14:
# the prior PR fixed the REPOS-after-config.env clobber bug in BOTH
# approve-from-replies.sh and learn-from-replies.sh, but only the
# approve script had test coverage. This smoke verifies that
# learn-from-replies actually honors `config.env`'s REPOS override
# instead of clobbering it with the hardcoded default list.
#
# Scope is narrow on purpose: we do NOT exercise the codex prompt or
# ACK posting paths (those would need codex/gh stubs and a live
# /srosro-memorize comment). Instead we run with empty comments, hit
# the early "no new requests" branch, and assert which repos got
# polled. Same shape as orchestrator-skip-smoke and
# approve-from-replies-smoke.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t learn-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export REPLIES_SEEN_FILE="$STATE_DIR/replies-seen.json"
export LOG_FILE="$STATE_DIR/learn.log"
mkdir -p "$STATE_DIR"
export BOT_USER="srosro"
export BOT_AUTO_POST_MARKER="<!-- knightwatch-reviewer:auto-post -->"
# CLAUDE_DIR is only read on the codex path (which we don't reach in
# these scenarios), but set it to a tmp path anyway so a regression
# that reaches the cat $CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md line
# fails loud instead of touching the real ~/.claude/.
export CLAUDE_DIR="$TMPDIR/claude"
mkdir -p "$CLAUDE_DIR"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

export STUB_PR_LIST_LOG="$STATE_DIR/gh-pr-list.log"
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
echo "[]" > "$MOCK_COMMENTS_FILE"

# Stub gh — same shape as approve-from-replies-smoke.sh's stub. Records
# pr-list calls so override scenarios can assert. Returns a PR only for
# the smoke's "test-org/probe-repo".
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    repo=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--repo" ]; then
            j=$((i+1))
            repo="${!j}"
            break
        fi
    done
    echo "PR_LIST repo=$repo" >> "${STUB_PR_LIST_LOG:-/dev/null}"
    if [ "$repo" = "test-org/probe-repo" ]; then
        # `gh pr list --json number --state all --limit 200` is the call.
        echo '[{"number":1}]'
    else
        echo '[]'
    fi
elif [ "$1" = "api" ]; then
    # MOCK_GH_API_FAIL=1 simulates an API outage on the comments fetch.
    # The script's pipefail-aware `gh api ... | jq` should surface this
    # as a pipeline failure, log it, and skip the PR.
    if [ -n "${MOCK_GH_API_FAIL:-}" ]; then
        echo "API down" >&2
        exit 1
    fi
    paginate=""
    endpoint=""
    for arg in "$@"; do
        case "$arg" in
            --paginate) paginate=1 ;;
            repos/*)    endpoint="$arg" ;;
        esac
    done
    if [[ "$endpoint" == */issues/*/comments* ]]; then
        # When --paginate is set AND a page-2 fixture exists, emit both
        # pages back-to-back. `gh api --paginate` produces N JSON arrays
        # concatenated; the script's `| jq -s 'add // []'` slurps and
        # merges. A regression to single-page-fetch would only see page 1
        # and the page-2 scenario in this file would fail.
        if [ -n "$paginate" ] && [ -s "${MOCK_COMMENTS_FILE_PAGE2:-/dev/null}" ]; then
            cat "$MOCK_COMMENTS_FILE"
            cat "$MOCK_COMMENTS_FILE_PAGE2"
        else
            cat "$MOCK_COMMENTS_FILE"
        fi
    elif [[ "$endpoint" == */collaborators/*/permission ]]; then
        echo "none"
    else
        echo "{}"
    fi
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Sandbox lib dir.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/auth.sh"          "$REVIEWER_LIB_DIR/auth.sh"
cp "$PROJECT_ROOT/lib/state-io.sh"      "$REVIEWER_LIB_DIR/state-io.sh"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"
cp "$PROJECT_ROOT/lib/gh-comments.sh"   "$REVIEWER_LIB_DIR/gh-comments.sh"

# REPOS override via config.env. test-org/probe-repo is NOT in the
# script's hardcoded default list (cncorp/plow, srosro/tkmx-client, ...),
# so honoring the override means polling probe-repo only; clobbering the
# override means polling the hardcoded list and missing the probe entirely.
cat > "$STATE_DIR/config.env" <<'CONF'
REPOS=("test-org/probe-repo")
CONF

run_learn() {
    : > "$STUB_PR_LIST_LOG"
    : > "$LOG_FILE"
    bash "$PROJECT_ROOT/learn-from-replies.sh" >/dev/null 2>&1 || true
}

# Scenario 1: empty comments + REPOS override honored.
echo "  scenario 1: empty comments — early exit, REPOS override observed..."
run_learn
grep -q "no new /srosro-memorize requests" "$LOG_FILE" || { echo "FAIL scenario 1: expected early-exit log line"; cat "$LOG_FILE"; exit 1; }
grep -q "PR_LIST repo=test-org/probe-repo" "$STUB_PR_LIST_LOG" || { echo "FAIL scenario 1: REPOS override not honored (expected to poll test-org/probe-repo)"; cat "$STUB_PR_LIST_LOG"; exit 1; }
if grep -q "PR_LIST repo=cncorp/plow" "$STUB_PR_LIST_LOG"; then
    echo "FAIL scenario 1 (REPOS-override regression): polled hardcoded cncorp/plow — config.env override was clobbered"
    cat "$STUB_PR_LIST_LOG"
    exit 1
fi

# Scenario 2: untrusted /srosro-memorize after a bot review → ignored,
# logged. Guards the trust gate that keeps drive-by commenters from
# mutating the shared mistakes list.
echo "  scenario 2: untrusted /srosro-memorize — ignored with log..."
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EARLIER_ISO=$(date -u -d "@$(($(date +%s) - 60))" +"%Y-%m-%dT%H:%M:%SZ")
# The script requires a prior comment from BOT_USER (srosro) to anchor
# "after a bot review" sequencing. Then a later comment from a non-
# trusted user containing /srosro-memorize.
printf '[{"id":900,"created_at":"%s","user":{"login":"srosro"},"body":"%s\\nbot review"},{"id":901,"created_at":"%s","user":{"login":"stranger"},"body":"/srosro-memorize don'"'"'t require imports cleanup"}]\n' "$EARLIER_ISO" "$BOT_AUTO_POST_MARKER" "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_learn
grep -q "/srosro-memorize from @stranger ignored (no push access)" "$LOG_FILE" || { echo "FAIL scenario 2: expected trust-gate ignore log for @stranger"; cat "$LOG_FILE"; exit 1; }
grep -q "no new /srosro-memorize requests" "$LOG_FILE" || { echo "FAIL scenario 2: untrusted request should not have been collected"; cat "$LOG_FILE"; exit 1; }

# Scenario 3: pagination — a /srosro-memorize comment lives on page 2 of
# the issue-comments response. With the fixed `gh api --paginate ... |
# jq -s 'add // []'` pipeline, the script sees both pages and the
# trust-gate ignore log fires for the page-2 commenter. With the old
# single-page fetch, the request is invisible and the script logs "no
# new requests" instead — this scenario fails on that regression.
echo "  scenario 3: /srosro-memorize on page 2 — pagination merges both pages..."
EARLIER_ISO=$(date -u -d "@$(($(date +%s) - 60))" +"%Y-%m-%dT%H:%M:%SZ")
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Page 1: bot's auto-post anchoring LAST_OUR_TS.
printf '[{"id":920,"created_at":"%s","user":{"login":"srosro"},"body":"%s\\nbot review"}]\n' "$EARLIER_ISO" "$BOT_AUTO_POST_MARKER" > "$MOCK_COMMENTS_FILE"
# Page 2: untrusted /srosro-memorize.
export MOCK_COMMENTS_FILE_PAGE2="$TMPDIR/comments-page2.json"
printf '[{"id":921,"created_at":"%s","user":{"login":"stranger"},"body":"/srosro-memorize page-two reply"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE_PAGE2"
run_learn
grep -q "/srosro-memorize from @stranger ignored (no push access)" "$LOG_FILE" || { echo "FAIL scenario 3 (single-page-fetch regression): expected page-2 /srosro-memorize to be observed and trust-gate-ignored"; cat "$LOG_FILE"; exit 1; }
unset MOCK_COMMENTS_FILE_PAGE2
rm -f "$TMPDIR/comments-page2.json"

# Scenario 4: gh api fetch failure — pipefail surfaces the failure, the
# script logs the boundary error and skips that PR. Without pipefail (or
# without the `|| { log; continue }` wrapper) the failed fetch would
# silently produce [] from jq and the run would look successful.
echo "  scenario 4: gh api comments fetch fails — log + skip (pipefail wins)..."
echo "[]" > "$MOCK_COMMENTS_FILE"
MOCK_GH_API_FAIL=1 run_learn
grep -q "comments fetch failed — skipping this PR for this tick" "$LOG_FILE" || { echo "FAIL scenario 4: expected fail-loud log line on gh api failure"; cat "$LOG_FILE"; exit 1; }

echo "  PASS (4 scenarios: REPOS-override-observed, untrusted-memorize-ignored, page-2-paginated, gh-api-failure-fail-loud)"
