#!/bin/bash
# Smoke test for review.sh's same-SHA dispatch decision.
#
# Locks in the regression for the bug fixed by "Orchestrator: skip
# @-mention re-reviews when SHA is unchanged." Three scenarios, all on a
# PR whose head SHA matches what was last reviewed:
#
#   1. No new comments → no worker dispatched (pre-existing behavior)
#   2. Bare @<bot> mention since last review → no worker dispatched
#      (the bug fix; pre-fix this would have spawned a worker that
#      aborts on empty incremental diff)
#   3. /review comment since last review → worker dispatched with
#      FORCE_WHOLE_PR=true (preserved behavior, since the worker uses
#      `gh pr diff` for the full PR diff regardless of base SHA)
#
# Stubs `gh` via PATH and the worker via REVIEWER_LIB_DIR so neither
# the network nor real PR infrastructure is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t orch-skip-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandbox state dir — every path the orchestrator writes to is here.
export STATE_DIR="$TMPDIR/state"
export STATE_FILE="$STATE_DIR/state.json"
export LOG_FILE="$STATE_DIR/review.log"
export REPOS_DIR="$STATE_DIR/repos"
export WORKDIRS_DIR="$STATE_DIR/workdirs"
mkdir -p "$STATE_DIR" "$REPOS_DIR" "$WORKDIRS_DIR"
echo "{}" > "$STATE_FILE"
export BOT_USER="srosro"

# Sandbox HOME. review.sh's first action is `export PATH="$HOME/.local/bin:
# $HOME/.npm-global/bin:$PATH"`, so to make our stubbed `gh` actually
# resolve we have to either (a) put the stub at $HOME/.local/bin/gh under
# a fake HOME, or (b) accept that the real gh in the user's $HOME wins.
# Option (a). We point HOME at a fresh dir, then drop the stub into the
# .local/bin/ slot review.sh prepends.
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

# Stub `gh`. The orchestrator calls:
#   gh pr list --repo <repo> --json number,title,headRefName,headRefOid
#   gh api repos/<owner>/<repo>/issues/<num>/comments
#   gh api repos/<owner>/<repo>/pulls/<num>/commits --jq ...
#   gh api repos/<owner>/<repo>/collaborators/<user>/permission --jq .permission
# Scenarios drive trust answers via $MOCK_TRUSTED_USERS (space-separated
# usernames the stub treats as having `write` access; everything else
# returns `none`).
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    if [[ "$*" == *"cncorp/plow"* ]]; then
        echo '[{"number":1,"title":"Test PR","headRefName":"feat/test","headRefOid":"abc123"}]'
    else
        echo '[]'
    fi
elif [ "$1" = "api" ]; then
    if [[ "$2" == */issues/*/comments* ]]; then
        cat "$MOCK_COMMENTS_FILE"
    elif [[ "$2" == */pulls/*/commits* ]]; then
        # Old date so cooldown is bypassed if it ever runs. None of these
        # scenarios should reach the cooldown branch (all are same-SHA;
        # the skip happens before cooldown), but stub it anyway so a
        # regression that leaks through doesn't hang on a missing stub.
        echo "2020-01-01T00:00:00Z"
    elif [[ "$2" == */collaborators/*/permission ]]; then
        # Extract the username segment between "collaborators/" and "/permission".
        user="${2##*/collaborators/}"
        user="${user%/permission}"
        for trusted in ${MOCK_TRUSTED_USERS:-}; do
            if [ "$user" = "$trusted" ]; then
                echo "write"; exit 0
            fi
        done
        echo "none"
    else
        echo "{}"
    fi
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Sandbox lib dir: real state-io.sh + auth.sh, stub worker that logs the
# dispatch (including the trigger-comment file path so trust-gate
# scenarios can assert presence/absence) instead of running a review.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/state-io.sh" "$REVIEWER_LIB_DIR/state-io.sh"
cp "$PROJECT_ROOT/lib/auth.sh"     "$REVIEWER_LIB_DIR/auth.sh"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<'WORKER'
#!/bin/bash
# Args from review.sh: REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# TRIGGER_COMMENT_FILE comes through as an env var.
echo "WORKER_DISPATCHED repo=$1 pr=$2 sha=$3 force_whole=$6 trigger_file=${TRIGGER_COMMENT_FILE:-}" >> "$LOG_FILE"
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

# Pre-stamp state: cncorp/plow#1 was reviewed at SHA abc123 (matches the
# headRefOid the gh stub returns). reviewed_at is set to "1 hour ago"
# so $MOCK_COMMENTS_FILE timestamps written as "now" are after it.
. "$REVIEWER_LIB_DIR/state-io.sh"
state_set "cncorp/plow#1" "abc123" false "prior review body" "$(($(date +%s) - 3600))"

export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
# Default trust set for the existing scenarios: srosro is the bot operator
# and "someuser" is the realistic external collaborator shape. Scenarios
# that need to test the untrusted path override this just before
# run_orchestrator.
export MOCK_TRUSTED_USERS="srosro someuser"

run_orchestrator() {
    : > "$LOG_FILE"   # reset
    bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true
}

count_dispatches() {
    local n
    n=$(grep -c '^WORKER_DISPATCHED ' "$LOG_FILE" 2>/dev/null) || true
    echo "${n:-0}"
}

# Scenario 1: same SHA, no comments → no dispatch
echo "  scenario 1: same SHA, no recent comments..."
echo "[]" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 1: expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 2 (the bug fix): same SHA, bare @<bot> mention → no dispatch.
# Pre-fix, this would have set FORCE_REVIEW=true, bypassed the
# unchanged-SHA skip, spawned a worker, and the worker would have
# aborted on `git diff KNOWN_SHA..HEAD` returning empty.
echo "  scenario 2: same SHA + bare @-mention (the bug fix)..."
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"hey @srosro can you take another look?"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 2 (bug-fix regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 3: same SHA, /review → 1 dispatch with FORCE_WHOLE_PR=true.
# /review must still work; the worker uses gh pr diff for the full PR
# diff regardless of base SHA, so there's always something to review.
echo "  scenario 3: same SHA + /review comment..."
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 3: expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 3: expected force_whole=true in dispatch"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'trigger_file=/tmp/pr-review-trigger' "$LOG_FILE"; then
    echo "FAIL scenario 3: expected trigger_file=/tmp/... in dispatch (someuser is in MOCK_TRUSTED_USERS)"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 4 (bot self-trigger filter): same SHA, comment whose body
# carries the auto-post marker → no dispatch. The bot's own posted review
# comments prepend `<!-- knightwatch-reviewer:auto-post -->` to the body;
# the orchestrator excludes any comment containing that marker so a
# successful review doesn't re-trigger itself when the bot's
# inferred-intent line matches the @<bot>-mention regex on the next tick.
# Exercises the WHOLE_MENTION path so the same-SHA skip can't mask the
# filter: pre-fix this would have produced WHOLE_MENTION=1 →
# FORCE_WHOLE_PR=true → dispatch.
echo "  scenario 4: same SHA + auto-post marker in body (self-trigger filter)..."
printf '[{"created_at":"%s","user":{"login":"srosro"},"body":"<!-- knightwatch-reviewer:auto-post -->\\n/review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 4 (self-trigger filter regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 5 (single-account regression): same SHA, comment authored by
# BOT_USER (the bot's own GH identity) with a /review body but NO marker
# → 1 dispatch. This is the case the earlier `.user.login != $user`
# filter (e1d91a0) silently broke: in single-account deployments the
# human running the bot posts as BOT_USER, and a user-based filter drops
# their legitimate /review along with the bot's auto-posts. The
# content-marker filter must let unmarked comments through regardless of
# author.
echo "  scenario 5: same SHA + /review by BOT_USER without marker (single-account /review)..."
printf '[{"created_at":"%s","user":{"login":"srosro"},"body":"/review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 5 (single-account /review regression): expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 5: expected force_whole=true in dispatch"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'trigger_file=/tmp/pr-review-trigger' "$LOG_FILE"; then
    echo "FAIL scenario 5: expected trigger_file=/tmp/... in dispatch (srosro is in MOCK_TRUSTED_USERS)"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 6 (trigger-comment trust gate): same SHA, /review from a
# commenter without push access → the trigger still dispatches a worker
# (so re-request-poller and external requesters keep working), but the
# orchestrator does NOT stage `.codex-scratch/trigger-comment.md`. The
# bot's trigger-comment plumbing weights the comment body heavily on the
# pipeline that ends in `gh pr review --approve`, so a drive-by
# commenter's prose is kept off that path. Stranger is deliberately
# omitted from MOCK_TRUSTED_USERS for this scenario.
echo "  scenario 6: same SHA + /review from untrusted commenter (trigger-comment trust gate)..."
MOCK_TRUSTED_USERS="srosro" \
    printf '[{"created_at":"%s","user":{"login":"stranger"},"body":"/review please"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_TRUSTED_USERS="srosro" run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 6: expected 1 dispatch (review still triggered), got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 6: expected force_whole=true in dispatch"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if grep -q 'trigger_file=/tmp/pr-review-trigger' "$LOG_FILE"; then
    echo "FAIL scenario 6 (trust gate regression): expected trigger_file empty for untrusted commenter, but a tmp path was staged"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

echo "  PASS (6 scenarios: no-comments, bare-mention, /review, marker-self-filter, single-account-/review, untrusted-trigger-comment)"
