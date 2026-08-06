#!/usr/bin/env bash
# Smoke test for learn-from-replies.sh.
#
# Focused on the regression-test gap knightwatch flagged on PR #14:
# the prior PR fixed the REPOS-after-config.env clobber bug in BOTH
# the approve poller (now poll-pr-actions.sh) and learn-from-replies.sh, but only
# the approve script had test coverage. This smoke verifies that
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
# Production no longer prepends $HOME/.local/bin to PATH (writable-PATH
# attack vector — d42946b / R26 F#1). Smoke prepends here so its gh
# stub resolves.
export PATH="$HOME/.local/bin:$PATH"

export STUB_PR_LIST_LOG="$STATE_DIR/gh-pr-list.log"
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
echo "[]" > "$MOCK_COMMENTS_FILE"

# Stub gh — same shape as approve-from-replies-smoke.sh's stub. Records
# pr-list calls so override scenarios can assert. Returns a PR only for
# the smoke's "test-org/probe-repo".
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
    # MOCK_ACK_RATE_LIMITED=1 → the first ACK post 403s with rate-limit wording,
    # so gh_retry stamps the shared pause and the ACK loop must stop there.
    if [ -n "${MOCK_ACK_RATE_LIMITED:-}" ] && [ ! -s "${STUB_ACK_LOG:-/dev/null}" ]; then
        echo "ACK_ATTEMPT_THROTTLED" >> "${STUB_ACK_LOG:-/dev/null}"
        echo "gh: HTTP 403: API rate limit exceeded" >&2
        exit 1
    fi
    echo "ACK_POSTED $3" >> "${STUB_ACK_LOG:-/dev/null}"
    # MOCK_SIBLING_STAMPS_PAUSE → a sibling timer stamps the shared pause right
    # after this ACK lands, so the NEXT iteration hits the loop's pre-check break
    # rather than a failed post. Different code path, same retention contract.
    [ -n "${MOCK_SIBLING_STAMPS_PAUSE:-}" ] \
        && printf '%s\n' "$(( $(date +%s) + 300 ))" > "$STATE_DIR/gh-rate-limited-until"
    exit 0
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
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
        # Honor MOCK_TRUSTED_USERS so a scenario can actually reach the codex/ACK
        # path; unset (the default) keeps every prior scenario untrusted.
        u="${endpoint##*/collaborators/}"; u="${u%/permission}"
        for t in ${MOCK_TRUSTED_USERS:-}; do
            if [ "$u" = "$t" ]; then echo "write"; exit 0; fi
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

# Sandbox lib dir.

# --- codex stub (opt-in via MOCK_CODEX_ACKS) ----------------------------------
# The suite historically stopped before the codex/ACK path, which is exactly how
# an ordering bug shipped that marked NOTHING seen. This stub emits the shape the
# parser expects so ACK retention can be asserted behaviorally, not by layout.
cat > "$HOME/.local/bin/codex" <<'CODEXSTUB'
#!/bin/bash
cat >/dev/null   # drain the prompt on stdin
echo "codex"
echo "<COMMENT_REVIEW_MISTAKES>"
echo "- stub mistake line"
echo "</COMMENT_REVIEW_MISTAKES>"
if [ -n "${MOCK_CODEX_ACKS:-}" ]; then
    echo "<ACKS>"
    printf '%s\n' "$MOCK_CODEX_ACKS"
    echo "</ACKS>"
fi
echo "tokens used: 1"
CODEXSTUB
chmod +x "$HOME/.local/bin/codex"

export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/bootstrap.sh"     "$REVIEWER_LIB_DIR/bootstrap.sh"  # sources the core below
cp "$PROJECT_ROOT/lib/auth.sh"          "$REVIEWER_LIB_DIR/auth.sh"
cp "$PROJECT_ROOT/lib/gh-retry.sh"      "$REVIEWER_LIB_DIR/gh-retry.sh"   # auth.sh sources it
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
# Portable epoch→ISO — `date -u -d "@<epoch>"` is GNU-only. python3 fixes both.
EARLIER_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(($(date +%s) - 60)), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
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
# Portable epoch→ISO — `date -u -d "@<epoch>"` is GNU-only. python3 fixes both.
EARLIER_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(($(date +%s) - 60)), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
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
export STUB_ACK_LOG="$STATE_DIR/gh-ack.log"
TRUSTED_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TRUSTED_EARLIER=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(($(date +%s) - 120)), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
seed_two_requests() {
    : > "$STUB_ACK_LOG"
    echo '{}' > "$REPLIES_SEEN_FILE"
    rm -f "$STATE_DIR/gh-rate-limited-until"
    unset MOCK_COMMENTS_FILE_PAGE2
    # A bot auto-post must come FIRST and be older: the collector skips a repo
    # with no bot comment, and only counts requests newer than the bot's last one.
    printf '[{"id":929,"created_at":"%s","user":{"login":"srosro"},"body":"%s\\nbot review"},{"id":930,"created_at":"%s","user":{"login":"trusteduser"},"body":"/srosro-memorize first lesson"},{"id":931,"created_at":"%s","user":{"login":"trusteduser"},"body":"/srosro-memorize second lesson"}]\n' \
        "$TRUSTED_EARLIER" "$BOT_AUTO_POST_MARKER" "$TRUSTED_NOW" "$TRUSTED_NOW" > "$MOCK_COMMENTS_FILE"
}
ACKS_TWO='<ACK key="test-org/probe-repo#1#930">noted one</ACK>
<ACK key="test-org/probe-repo#1#931">noted two</ACK>'

echo "  scenario 5: first ACK throttled → neither key marked seen, retried next tick..."
seed_two_requests
MOCK_TRUSTED_USERS="trusteduser" MOCK_CODEX_ACKS="$ACKS_TWO" MOCK_ACK_RATE_LIMITED=1 run_learn
for k in 930 931; do
    [ -z "$(jq -r --arg k "test-org/probe-repo#1#$k" '.[$k] // empty' "$REPLIES_SEEN_FILE")" ] \
        || { echo "FAIL scenario 5: key $k marked seen despite the rate limit stopping its ACK — a trusted memorize request is silently dropped"; cat "$REPLIES_SEEN_FILE"; cat "$LOG_FILE"; exit 1; }
done
# Window cleared → the deferred requests go through, proving they were held not lost.
rm -f "$STATE_DIR/gh-rate-limited-until"
: > "$STUB_ACK_LOG"
MOCK_TRUSTED_USERS="trusteduser" MOCK_CODEX_ACKS="$ACKS_TWO" run_learn
posted=$(grep -c '^ACK_POSTED' "$STUB_ACK_LOG" 2>/dev/null || true); posted="${posted:-0}"
[ "$posted" -eq 2 ] || { echo "FAIL scenario 5: deferred ACKs did not post after the pause cleared (got $posted) — the requests were lost"; cat "$STUB_ACK_LOG"; cat "$LOG_FILE"; exit 1; }
# The recovery run IS the happy path, so it carries the marked-seen half too — a
# separate clean-path scenario asserted exactly this against the same two keys.
for k in 930 931; do
    [ -n "$(jq -r --arg k "test-org/probe-repo#1#$k" '.[$k] // empty' "$REPLIES_SEEN_FILE")" ] \
        || { echo "FAIL scenario 5: key $k not marked seen after its ACK posted — next tick re-runs codex and posts a duplicate ACK"; cat "$REPLIES_SEEN_FILE"; cat "$LOG_FILE"; exit 1; }
done
rm -f "$STATE_DIR/gh-rate-limited-until"

echo "  scenario 6: pause arrives between ACKs → posted key seen, un-posted key retained..."
seed_two_requests
MOCK_TRUSTED_USERS="trusteduser" MOCK_CODEX_ACKS="$ACKS_TWO" MOCK_SIBLING_STAMPS_PAUSE=1 run_learn
posted=$(grep -c '^ACK_POSTED' "$STUB_ACK_LOG" 2>/dev/null || true); posted="${posted:-0}"
[ "$posted" -eq 1 ] || { echo "FAIL scenario 6: expected the loop to stop after 1 ACK once the pause arrived, got $posted"; cat "$STUB_ACK_LOG"; cat "$LOG_FILE"; exit 1; }
[ -n "$(jq -r '."test-org/probe-repo#1#930" // empty' "$REPLIES_SEEN_FILE")" ] \
    || { echo "FAIL scenario 6: the ACK that DID post was not marked seen — next tick re-posts it as a duplicate"; cat "$REPLIES_SEEN_FILE"; exit 1; }
[ -z "$(jq -r '."test-org/probe-repo#1#931" // empty' "$REPLIES_SEEN_FILE")" ] \
    || { echo "FAIL scenario 6: the un-posted key was marked seen — that memorize request is silently dropped"; cat "$REPLIES_SEEN_FILE"; exit 1; }
rm -f "$STATE_DIR/gh-rate-limited-until"

echo "  PASS (6 scenarios: REPOS-override-observed, untrusted-memorize-ignored, page-2-paginated, gh-api-failure-fail-loud, acks-throttled-then-recovered-and-seen, pause-mid-batch-per-key-retention)"
