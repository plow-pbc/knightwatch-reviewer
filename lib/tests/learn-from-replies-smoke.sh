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

export STUB_API_LOG="$STATE_DIR/gh-api.log"
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
echo "[]" > "$MOCK_COMMENTS_FILE"

# Stub gh — same shape as approve-from-replies-smoke.sh's stub. Records
# comments-endpoint calls (repo + since) so scenarios can assert which repos
# were walked and from which cursor.
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
elif [ "$1" = "api" ]; then
    # MOCK_GH_API_FAIL=1 simulates an API outage on the comments fetch.
    # The script's pipefail-aware `gh api ... | jq` should surface this
    # as a pipeline failure, log it, and skip the repo.
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
    if [[ "$endpoint" == */issues/comments\?since=* ]]; then
        echo "API ${endpoint}" >> "${STUB_API_LOG:-/dev/null}"
        # MOCK_GH_API_FAIL_REPO → only that repo's fetch fails.
        if [ -n "${MOCK_GH_API_FAIL_REPO:-}" ] && [[ "$endpoint" == "repos/$MOCK_GH_API_FAIL_REPO/"* ]]; then
            echo "API down" >&2
            exit 1
        fi
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
    : > "$STUB_API_LOG"
    : > "$LOG_FILE"
    # The author-trust verdict cache (#233) is stop-state: a warm entry answers
    # WITHOUT probing, so a scenario asserting a probe branch would exercise the
    # cache instead. Each scenario models an independent tick, so it starts cold.
    rm -f "$STATE_DIR/trust-cache.json" "$STATE_DIR/trust-cache.json.lock"
    bash "$PROJECT_ROOT/learn-from-replies.sh" >/dev/null 2>&1 || true
}

# comment ID LOGIN BODY CREATED → one repo-wide issue-comment object on PR #1.
comment() {
    jq -cn --argjson id "$1" --arg u "$2" --arg b "$3" --arg t "$4" \
        '{id: $id, user: {login: $u}, body: $b, created_at: $t, updated_at: $t,
          html_url: "https://github.com/test-org/probe-repo/pull/1#issuecomment-\($id)"}'
}
comments() { jq -cs . ; }

# Scenario 1: empty comments + REPOS override honored.
echo "  scenario 1: empty comments — early exit, REPOS override observed..."
run_learn
grep -q "no new /srosro-memorize requests" "$LOG_FILE" || { echo "FAIL scenario 1: expected early-exit log line"; cat "$LOG_FILE"; exit 1; }
grep -q "API repos/test-org/probe-repo/issues/comments" "$STUB_API_LOG" || { echo "FAIL scenario 1: REPOS override not honored (expected to poll test-org/probe-repo)"; cat "$STUB_API_LOG"; exit 1; }
if grep -q "API repos/cncorp/plow/" "$STUB_API_LOG"; then
    echo "FAIL scenario 1 (REPOS-override regression): polled hardcoded cncorp/plow — config.env override was clobbered"
    cat "$STUB_API_LOG"
    exit 1
fi

# Scenario 2: untrusted /srosro-memorize after a bot review → ignored,
# logged. Guards the trust gate that keeps drive-by commenters from
# mutating the shared mistakes list.
echo "  scenario 2: untrusted /srosro-memorize — ignored with log..."
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Portable epoch→ISO — `date -u -d "@<epoch>"` is GNU-only. python3 fixes both.
EARLIER_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(($(date +%s) - 60)), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
{ comment 900 srosro "$BOT_AUTO_POST_MARKER"$'\n'"bot review" "$EARLIER_ISO"
  comment 901 stranger "/srosro-memorize don't require imports cleanup" "$NOW_ISO"; } | comments > "$MOCK_COMMENTS_FILE"
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
comment 920 srosro "$BOT_AUTO_POST_MARKER"$'\n'"bot review" "$EARLIER_ISO" | comments > "$MOCK_COMMENTS_FILE"
export MOCK_COMMENTS_FILE_PAGE2="$TMPDIR/comments-page2.json"
comment 921 stranger "/srosro-memorize page-two reply" "$NOW_ISO" | comments > "$MOCK_COMMENTS_FILE_PAGE2"
run_learn
grep -q "/srosro-memorize from @stranger ignored (no push access)" "$LOG_FILE" || { echo "FAIL scenario 3 (single-page-fetch regression): expected page-2 /srosro-memorize to be observed and trust-gate-ignored"; cat "$LOG_FILE"; exit 1; }
unset MOCK_COMMENTS_FILE_PAGE2
rm -f "$TMPDIR/comments-page2.json"

# Scenario 4: gh api fetch failure — pipefail surfaces the failure, the
# script logs the boundary error and skips that repo. Without pipefail (or
# without the `|| { log; continue }` wrapper) the failed fetch would
# silently produce [] from jq and the run would look successful.
echo "  scenario 4: gh api comments fetch fails — log + skip (pipefail wins)..."
echo "[]" > "$MOCK_COMMENTS_FILE"
MOCK_GH_API_FAIL=1 run_learn
grep -q "test-org/probe-repo: comments fetch failed — API down" "$LOG_FILE" || { echo "FAIL scenario 4: expected fail-loud log line on gh api failure"; cat "$LOG_FILE"; exit 1; }
export STUB_ACK_LOG="$STATE_DIR/gh-ack.log"
TRUSTED_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TRUSTED_EARLIER=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp($(($(date +%s) - 120)), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
seed_two_requests() {
    : > "$STUB_ACK_LOG"
    echo '{}' > "$REPLIES_SEEN_FILE"
    rm -f "$STATE_DIR/gh-rate-limited-until"
    unset MOCK_COMMENTS_FILE_PAGE2
    { comment 929 srosro "$BOT_AUTO_POST_MARKER"$'\n'"bot review" "$TRUSTED_EARLIER"
      comment 930 trusteduser "/srosro-memorize first lesson" "$TRUSTED_NOW"
      comment 931 trusteduser "/srosro-memorize second lesson" "$TRUSTED_NOW"; } | comments > "$MOCK_COMMENTS_FILE"
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

echo "  scenario 7: updated guidance is committed from the live code-config checkout..."
CODE_CONFIG_FIXTURE="$HOME/services/code-config"
CODE_CONFIG_REMOTE="$TMPDIR/code-config-remote.git"
mkdir -p "$CODE_CONFIG_FIXTURE/claude"
git init --bare -q "$CODE_CONFIG_REMOTE"
git -C "$CODE_CONFIG_FIXTURE" init -q
printf 'initial mistakes\n' > "$CODE_CONFIG_FIXTURE/claude/COMMENT_REVIEW_MISTAKES.md"
printf 'operator-owned setting\n' > "$CODE_CONFIG_FIXTURE/claude/OPERATOR.md"
git -C "$CODE_CONFIG_FIXTURE" add claude/COMMENT_REVIEW_MISTAKES.md claude/OPERATOR.md
git -C "$CODE_CONFIG_FIXTURE" -c user.email=test@example.com -c user.name=test \
    commit -qm "seed guidance"
git -C "$CODE_CONFIG_FIXTURE" branch -M main
git -C "$CODE_CONFIG_FIXTURE" remote add origin "$CODE_CONFIG_REMOTE"
git -C "$CODE_CONFIG_FIXTURE" push -qu origin main
printf 'operator edit that must remain staged\n' > "$CODE_CONFIG_FIXTURE/claude/OPERATOR.md"
git -C "$CODE_CONFIG_FIXTURE" add claude/OPERATOR.md
# Take the remote offline for the update tick. The learner must commit only its
# target and leave the failed push pending for a later no-request tick.
mv "$CODE_CONFIG_REMOTE" "$CODE_CONFIG_REMOTE.offline"
seed_two_requests
CLAUDE_DIR="$CODE_CONFIG_FIXTURE/claude" \
MOCK_TRUSTED_USERS="trusteduser" MOCK_CODEX_ACKS="$ACKS_TWO" run_learn
[ "$(git -C "$CODE_CONFIG_FIXTURE" rev-list --count HEAD)" -eq 2 ] \
    || { echo "FAIL scenario 7: learner did not commit the updated guidance in code-config"; git -C "$CODE_CONFIG_FIXTURE" status --short; cat "$LOG_FILE"; exit 1; }
[ "$(git -C "$CODE_CONFIG_FIXTURE" show --pretty= --name-only HEAD)" = "claude/COMMENT_REVIEW_MISTAKES.md" ] \
    || { echo "FAIL scenario 7: learner committed the wrong code-config path"; git -C "$CODE_CONFIG_FIXTURE" show --stat --oneline HEAD; exit 1; }
[ "$(git -C "$CODE_CONFIG_FIXTURE" diff --cached --name-only)" = "claude/OPERATOR.md" ] \
    || { echo "FAIL scenario 7: learner swept or unstaged the operator's unrelated edit"; git -C "$CODE_CONFIG_FIXTURE" status --short; exit 1; }
[ "$(git -C "$CODE_CONFIG_FIXTURE" rev-list --count '@{upstream}'..HEAD)" -eq 1 ] \
    || { echo "FAIL scenario 7: failed push did not leave exactly one pending guidance commit"; git -C "$CODE_CONFIG_FIXTURE" log --oneline --decorate -3; exit 1; }
LEARNER_SHA=$(git -C "$CODE_CONFIG_FIXTURE" rev-parse HEAD)
jq -e --arg sha "$LEARNER_SHA" \
    '.pending == {sha: $sha, remote: "origin", ref: "refs/heads/main"}' \
    "$STATE_DIR/code-config-guidance-push.json" >/dev/null \
    || { echo "FAIL scenario 7: pending push was not stored through the JSON state seam"; cat "$STATE_DIR/code-config-guidance-push.json" 2>/dev/null || true; exit 1; }

echo "  scenario 8: a no-request tick retries the pending code-config push..."
mv "$CODE_CONFIG_REMOTE.offline" "$CODE_CONFIG_REMOTE"
# An operator commit lands locally after the learner commit but before its
# retry. The retry must publish the recorded learner SHA, never generic HEAD.
git -C "$CODE_CONFIG_FIXTURE" -c user.email=operator@example.com -c user.name=operator \
    commit -qm "local operator change"
run_learn
[ "$LEARNER_SHA" = "$(git --git-dir="$CODE_CONFIG_REMOTE" rev-parse refs/heads/main)" ] \
    || { echo "FAIL scenario 8: retry published generic HEAD instead of the recorded learner commit"; git -C "$CODE_CONFIG_FIXTURE" log --oneline --decorate -4; exit 1; }
[ "$(git -C "$CODE_CONFIG_FIXTURE" rev-parse HEAD)" != "$(git --git-dir="$CODE_CONFIG_REMOTE" rev-parse refs/heads/main)" ] \
    || { echo "FAIL scenario 8: operator's later local commit was published by the learner"; git -C "$CODE_CONFIG_FIXTURE" log --oneline --decorate -4; exit 1; }

echo "  scenario 9: operator's own request counts; bot footer and quote-reply do not..."
: > "$STUB_ACK_LOG"
echo '{}' > "$REPLIES_SEEN_FILE"
{ comment 940 srosro "$BOT_AUTO_POST_MARKER"$'\n'"review body"$'\n'"\`/srosro-memorize <feedback>\` — teach a lesson" "$TRUSTED_EARLIER"
  comment 941 trusteduser "> \`/srosro-memorize <feedback>\` — teach a lesson"$'\n\n'"agreed, thanks" "$TRUSTED_NOW"
  comment 942 srosro "/srosro-memorize operator lesson" "$TRUSTED_NOW"; } | comments > "$MOCK_COMMENTS_FILE"
MOCK_TRUSTED_USERS="srosro trusteduser" MOCK_CODEX_ACKS='<ACK key="test-org/probe-repo#1#942">noted</ACK>' run_learn
grep -q "memorize_requests=1 " "$LOG_FILE" \
    || { echo "FAIL scenario 9: expected exactly the operator's request (942) — bot footer or quote-reply leaked in, or the operator was skipped as the bot"; cat "$LOG_FILE"; exit 1; }
[ "$(jq -r 'keys | join(",")' "$REPLIES_SEEN_FILE")" = "test-org/probe-repo#1#942" ] \
    || { echo "FAIL scenario 9: wrong request learned"; cat "$REPLIES_SEEN_FILE"; exit 1; }

echo "  scenario 10: a failing repo holds only its own cursor; a clean walk advances it..."
CURSOR_FILE="$STATE_DIR/learn-cursor.json"
OLD_CURSOR="2026-01-01T00:00:00Z"
cp "$STATE_DIR/config.env" "$STATE_DIR/config.env.bak"
echo 'REPOS=("test-org/probe-repo" "test-org/broken-repo")' > "$STATE_DIR/config.env"
jq -n --arg s "$OLD_CURSOR" '{"test-org/probe-repo": $s, "test-org/broken-repo": $s}' > "$CURSOR_FILE"
echo "[]" > "$MOCK_COMMENTS_FILE"
MOCK_GH_API_FAIL_REPO="test-org/broken-repo" run_learn
[ "$(jq -r '."test-org/broken-repo"' "$CURSOR_FILE")" = "$OLD_CURSOR" ] \
    || { echo "FAIL scenario 10: cursor advanced past a window whose fetch failed — requests in it are never read"; cat "$CURSOR_FILE"; exit 1; }
[ "$(jq -r '."test-org/probe-repo"' "$CURSOR_FILE")" \> "$OLD_CURSOR" ] \
    || { echo "FAIL scenario 10: a broken sibling held a healthy repo's cursor — its window widens every tick"; cat "$CURSOR_FILE"; exit 1; }
run_learn
grep -q "API repos/test-org/broken-repo/issues/comments?since=$OLD_CURSOR" "$STUB_API_LOG" \
    || { echo "FAIL scenario 10: retry tick did not re-read the failed repo from its held cursor"; cat "$STUB_API_LOG"; exit 1; }
[ "$(jq -r '."test-org/broken-repo"' "$CURSOR_FILE")" \> "$OLD_CURSOR" ] \
    || { echo "FAIL scenario 10: cursor did not advance after a clean walk — every tick re-reads the same window"; cat "$CURSOR_FILE"; exit 1; }
mv "$STATE_DIR/config.env.bak" "$STATE_DIR/config.env"

echo "  PASS (10 scenarios: REPOS-override-observed, untrusted-memorize-ignored, page-2-paginated, gh-api-failure-fail-loud, acks-throttled-then-recovered-and-seen, pause-mid-batch-per-key-retention, code-config-guidance-committed, pending-push-retried, operator-request-counts-footer-and-quote-do-not, per-repo-cursor-held-on-failure-advanced-on-success)"
