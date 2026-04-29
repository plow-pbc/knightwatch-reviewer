#!/bin/bash
# Smoke test for approve-from-replies.sh.
#
# Stubs `gh` via PATH so neither the network nor real PR infrastructure
# is touched. Captures `gh pr review --approve` calls in a stub log so
# scenarios can assert on the EXACT side effects of the approve path.
#
# Covered scenarios:
#   1. No comments → no approve.
#   2. Trusted user posts /srosro-approve as the whole comment → exactly
#      one approve call with the bot marker in the body, seen state set.
#   3. Same comment on a second tick → no second approve (already-seen).
#   4. Bot's own auto-post that mentions /srosro-approve → no approve
#      (BOT_AUTO_POST_MARKER filter).
#   5. Untrusted user posts /srosro-approve → no approve, seen marked
#      so the next tick doesn't re-log it.
#   6. *[bot] commenter (e.g. copilot-swe-agent[bot]) → no approve,
#      seen marked.
#   7. Mid-sentence mention ("don't use /srosro-approve yet") from a
#      trusted user → no approve. Regression test: the earlier
#      `grep -qiF '/srosro-approve'` would have falsely triggered here.
#   8. Trusted user posts a multi-line comment with /srosro-approve at
#      the start of the second line → approve fires.
#   9. Trusted user posts /srosro-approve followed by an arg ("LGTM") →
#      approve fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t approve-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandbox state dir.
export STATE_DIR="$TMPDIR/state"
export APPROVES_SEEN_FILE="$STATE_DIR/approves-seen.json"
export LOG_FILE="$STATE_DIR/approve.log"
mkdir -p "$STATE_DIR"
export BOT_USER="srosro"
export BOT_AUTO_POST_MARKER="<!-- knightwatch-reviewer:auto-post -->"

# Sandbox HOME so the script's PATH prepend resolves to our stubs.
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

# Stubbed gh. Inputs:
#   MOCK_COMMENTS_FILE — JSON array of issue comments
#   MOCK_TRUSTED_USERS — space-separated logins with `write` permission
# Stub log: $TMPDIR/state/gh-actions.log records `pr review --approve` calls.
STUB_ACTIONS_LOG="$STATE_DIR/gh-actions.log"
export STUB_ACTIONS_LOG

cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    if [[ "$*" == *"cncorp/plow"* ]]; then
        echo '[{"number":1}]'
    else
        echo '[]'
    fi
elif [ "$1" = "pr" ] && [ "$2" = "review" ]; then
    # MOCK_FAIL_PR_REVIEW=1 simulates gh's exit-1 on transient errors,
    # PR author self-approve rejections, merged-PR rejections, etc.
    # When set, no APPROVE log line is written so count_approves() sees
    # the failure as zero successful approves.
    if [ -n "${MOCK_FAIL_PR_REVIEW:-}" ]; then
        exit 1
    fi
    # Capture the approve invocation. The script passes:
    #   gh pr review <pr_num> --repo <repo> --approve --body <body>
    pr_num="$3"
    repo=""
    body=""
    shift 3
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo)    repo="$2"; shift 2 ;;
            --body)    body="$2"; shift 2 ;;
            --approve) shift ;;
            *)         shift ;;
        esac
    done
    # Use a sentinel to keep the body single-line in the log.
    body_oneline=$(printf '%s' "$body" | tr '\n' '|')
    echo "APPROVE repo=$repo pr=$pr_num body=$body_oneline" >> "$STUB_ACTIONS_LOG"
elif [ "$1" = "api" ]; then
    # Walk args and pick out the endpoint (any arg that looks like
    # "repos/..."). The script invokes `gh api --paginate <endpoint>`
    # for comments and `gh api <endpoint> --jq <expr>` for permissions,
    # so neither $2 nor ${!#} is reliable across both shapes.
    endpoint=""
    for arg in "$@"; do
        case "$arg" in
            repos/*) endpoint="$arg" ;;
        esac
    done
    if [[ "$endpoint" == */issues/*/comments* ]]; then
        cat "$MOCK_COMMENTS_FILE"
    elif [[ "$endpoint" == */collaborators/*/permission ]]; then
        user="${endpoint##*/collaborators/}"
        user="${user%/permission}"
        for trusted in ${MOCK_TRUSTED_USERS:-}; do
            if [ "$user" = "$trusted" ]; then echo "write"; exit 0; fi
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

# Sandbox lib dir: real auth.sh + state-io.sh.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/auth.sh"     "$REVIEWER_LIB_DIR/auth.sh"
cp "$PROJECT_ROOT/lib/state-io.sh" "$REVIEWER_LIB_DIR/state-io.sh"

export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"

# Single-repo override so tests don't iterate the production REPOS list.
# approve-from-replies.sh sets REPOS to its hardcoded default first, then
# sources config.env so an operator override actually wins. Pin REPOS to
# just cncorp/plow — the only repo the gh stub returns a PR for.
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/config.env" <<'CONF'
REPOS=("cncorp/plow")
CONF

run_approve() {
    : > "$STUB_ACTIONS_LOG"   # reset action log
    : > "$LOG_FILE"           # reset script log
    bash "$PROJECT_ROOT/approve-from-replies.sh" >/dev/null 2>&1 || true
}

count_approves() {
    local n
    n=$(grep -c '^APPROVE ' "$STUB_ACTIONS_LOG" 2>/dev/null) || true
    echo "${n:-0}"
}

NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
export MOCK_TRUSTED_USERS="srosro someuser"

# Scenario 1: no comments
echo "  scenario 1: empty comments — no approve..."
echo "[]" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 approves, got $n"; cat "$LOG_FILE"; exit 1; }

# Scenario 2: trusted user posts /srosro-approve as the whole comment
echo "  scenario 2: trusted /srosro-approve — exactly 1 approve, marker body, seen marked..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1001,"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-approve"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 1 ] || { echo "FAIL scenario 2: expected 1 approve, got $n"; cat "$STUB_ACTIONS_LOG"; cat "$LOG_FILE"; exit 1; }
grep -qF "$BOT_AUTO_POST_MARKER" "$STUB_ACTIONS_LOG" || { echo "FAIL scenario 2: approve body missing BOT_AUTO_POST_MARKER"; cat "$STUB_ACTIONS_LOG"; exit 1; }
[ -n "$(jq -r '."cncorp/plow#1#1001" // empty' "$APPROVES_SEEN_FILE")" ] || { echo "FAIL scenario 2: seen state not marked"; cat "$APPROVES_SEEN_FILE"; exit 1; }

# Scenario 3: same comment on a second tick — already-seen, no approve
echo "  scenario 3: re-running with same comment — no second approve..."
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 3: expected 0 approves on rerun, got $n"; cat "$STUB_ACTIONS_LOG"; exit 1; }

# Scenario 4: bot's own auto-post mentioning /srosro-approve — marker filter
echo "  scenario 4: bot auto-post with marker — no approve (self-trigger filter)..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1002,"created_at":"%s","user":{"login":"srosro"},"body":"%s\\nApproved on @someuser'"'"'s /srosro-approve request."}]\n' "$NOW_ISO" "$BOT_AUTO_POST_MARKER" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 approves on bot post, got $n"; cat "$STUB_ACTIONS_LOG"; exit 1; }

# Scenario 5: untrusted user — no approve, seen marked
echo "  scenario 5: untrusted /srosro-approve — no approve, seen marked..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1003,"created_at":"%s","user":{"login":"stranger"},"body":"/srosro-approve please"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_TRUSTED_USERS="srosro" run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 5: expected 0 approves from untrusted user, got $n"; cat "$STUB_ACTIONS_LOG"; exit 1; }
[ -n "$(jq -r '."cncorp/plow#1#1003" // empty' "$APPROVES_SEEN_FILE")" ] || { echo "FAIL scenario 5: untrusted seen state not marked"; cat "$APPROVES_SEEN_FILE"; exit 1; }

# Scenario 6: *[bot] commenter — no approve, seen marked
echo "  scenario 6: *[bot] commenter — no approve, seen marked..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1004,"created_at":"%s","user":{"login":"copilot-swe-agent[bot]"},"body":"/srosro-approve"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 6: expected 0 approves from [bot], got $n"; cat "$STUB_ACTIONS_LOG"; exit 1; }
[ -n "$(jq -r '."cncorp/plow#1#1004" // empty' "$APPROVES_SEEN_FILE")" ] || { echo "FAIL scenario 6: [bot] seen state not marked"; cat "$APPROVES_SEEN_FILE"; exit 1; }

# Scenario 7: mid-sentence mention — no approve (regression for is_approve_request)
echo "  scenario 7: mid-sentence /srosro-approve mention — no approve (regression)..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1005,"created_at":"%s","user":{"login":"someuser"},"body":"don'"'"'t use /srosro-approve yet, the smoke test is still red"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 7 (substring-match regression): expected 0 approves, got $n"; cat "$STUB_ACTIONS_LOG"; exit 1; }

# Scenario 8: command on the second line of a multi-line comment — approve fires
echo "  scenario 8: /srosro-approve at start of second line — approve fires..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1006,"created_at":"%s","user":{"login":"someuser"},"body":"LGTM all green\\n/srosro-approve"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 1 ] || { echo "FAIL scenario 8: expected 1 approve, got $n"; cat "$STUB_ACTIONS_LOG"; cat "$LOG_FILE"; exit 1; }

# Scenario 9: command followed by trailing arg — approve fires
echo "  scenario 9: /srosro-approve with trailing arg — approve fires..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1007,"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-approve LGTM"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_approve
n=$(count_approves)
[ "$n" -eq 1 ] || { echo "FAIL scenario 9: expected 1 approve, got $n"; cat "$STUB_ACTIONS_LOG"; cat "$LOG_FILE"; exit 1; }

# Scenario 10: gh pr review --approve fails (PR author self-approve rejected,
# transient API error, etc.) → no successful approve, but the comment IS
# marked seen so the next tick doesn't retry the same request forever.
# Without this, a stuck failure would spam every tick.
echo "  scenario 10: gh pr review --approve fails — log + mark seen + don't retry on rerun..."
echo '{}' > "$APPROVES_SEEN_FILE"
printf '[{"id":1010,"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-approve"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_FAIL_PR_REVIEW=1 run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 10: expected 0 successful approves on failure, got $n"; cat "$STUB_ACTIONS_LOG"; cat "$LOG_FILE"; exit 1; }
[ -n "$(jq -r '."cncorp/plow#1#1010" // empty' "$APPROVES_SEEN_FILE")" ] || { echo "FAIL scenario 10: seen state not marked after failure (would retry on every tick)"; cat "$APPROVES_SEEN_FILE"; cat "$LOG_FILE"; exit 1; }
# Rerun without the fail flag — must NOT retry the previously-failed
# request. (If marking-seen-on-failure regresses, this rerun would now
# succeed and we'd see 1 approve.)
run_approve
n=$(count_approves)
[ "$n" -eq 0 ] || { echo "FAIL scenario 10: rerun retried after failure; expected 0 approves, got $n (mark-seen-on-failure regression)"; cat "$STUB_ACTIONS_LOG"; exit 1; }

echo "  PASS (10 scenarios: empty, trusted-approve, already-seen, bot-self-marker, untrusted-skip, [bot]-skip, mid-sentence-no-match, second-line-match, trailing-arg-match, gh-failure-marked-seen)"
