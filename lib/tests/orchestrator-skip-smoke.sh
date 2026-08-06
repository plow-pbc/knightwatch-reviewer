#!/usr/bin/env bash
# Smoke test for review.sh's same-SHA dispatch decision.
#
# Covers the trigger model:
#   1. No new comments → no worker dispatched.
#   2. Bare @<bot> mention since last review → no worker dispatched
#      (mentions are not triggers — only the slash commands are).
#   3. /srosro-review comment since last review → worker dispatched with
#      FORCE_WHOLE_PR=true (the worker uses `gh pr diff` for the full PR
#      diff regardless of base SHA, so there's always something to review).
#   4. Bot's own auto-post containing /srosro-review → no dispatch
#      (self-trigger filter via the BOT_AUTO_POST_MARKER).
#   5. /srosro-review by BOT_USER without the marker → 1 dispatch
#      (single-account regression: human running the bot must be able to
#      trigger reviews on their own account).
#   6. /srosro-review from a commenter without push access → 1 dispatch
#      (the trigger itself is honored), but no trigger-comment.md is
#      staged for the worker (trust gate keeps drive-by prose off the
#      auto-approve path).
#   7. /srosro-update-review on an unchanged SHA → no dispatch (skipped
#      to avoid empty-diff aborts; the trigger stays open until commits
#      land and a future tick picks it up).
#   7e. /srosro-update-review whose head only LOOKS unchanged (a push
#      landed after the enumeration snapshot) → 1 dispatch, no decline.
#      The live-head re-fetch is what keeps the skip decision honest.
#  13. /srosro-update-review on PAGE 2 of the issue-comments endpoint
#      → 1 dispatch. Stub emits page 2 only when --paginate is in args,
#      so a regression that drops --paginate from lib/gh-comments.sh
#      would silently lose the trigger and fail the dispatch assertion.
#      This is the original user-facing bug the PR exists to fence.
#
# Stubs `gh` via PATH and the worker via REVIEWER_LIB_DIR so neither the
# network nor real PR infrastructure is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t orch-skip-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandbox state dir — every path the orchestrator writes to is here.
export STATE_DIR="$TMPDIR/state"
export STATE_FILE="$STATE_DIR/state.json"
export LOG_FILE="$STATE_DIR/orchestrator.log"
export COMMENT_FETCH_LOG="$STATE_DIR/comment-fetch.log"
export COMMENT_POST_LOG="$STATE_DIR/comment-post.log"
export REPOS_DIR="$STATE_DIR/repos"
export WORKDIRS_DIR="$STATE_DIR/workdirs"
mkdir -p "$STATE_DIR" "$REPOS_DIR" "$WORKDIRS_DIR"
echo "{}" > "$STATE_FILE"
export BOT_USER="srosro"

# Sandboxed repos.conf — review.sh fails loud now if no tracked repos
# are defined. The gh stub below returns a PR for "cncorp/plow" only,
# so the test must declare exactly that repo as tracked.
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("cncorp/plow")
declare -A KID_PATHS=()
CONF

# Sandbox HOME and prepend its bin dir to PATH so the stubbed `gh`
# resolves. Production no longer prepends $HOME/.local/bin to PATH
# (writable-PATH attack vector — d42946b / R26 F#1); the smoke handles
# it itself with a deliberate test-owned PATH export.
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# Prepend the stub bin to PATH for every child this smoke spawns. Most
# scenarios spawn `bash review.sh`, which does its own
# `export PATH="$HOME/.local/bin:..."` first thing — but scenario 10
# spawns `bash holder.sh` and inline subshells that source locking.sh
# directly (bypassing review.sh), so they need the stubs reachable
# through the inherited PATH alone. Linux production never sees this
# path anyway (real gh / timeout / flock all live in /usr/bin).
export PATH="$HOME/.local/bin:$PATH"

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
    # Parse --repo arg by name. Substring matching on $* would
    # incorrectly fire for both "cncorp/plow" and "cncorp/plow-content"
    # (or any future cncorp/plow-* tracked repo) and double the
    # dispatch count under scenarios that expect exactly 1.
    repo=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--repo" ]; then
            j=$((i+1))
            repo="${!j}"
            break
        fi
    done
    if [ "$repo" = "cncorp/plow" ]; then
        # updatedAt defaults to a fresh, unique value so it never matches a
        # watermark a prior scenario's idle-skip wrote — existing scenarios
        # are thus unaffected by the gate. The idle-skip scenarios override
        # MOCK_PR_UPDATED_AT to a fixed value to exercise the gate.
        upd="${MOCK_PR_UPDATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ).$RANDOM}"
        echo "[{\"number\":1,\"title\":\"Test PR\",\"headRefName\":\"feat/test\",\"headRefOid\":\"abc123\",\"updatedAt\":\"$upd\"}]"
    else
        echo '[]'
    fi
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    # Live head re-fetch (--json headRefOid), used to re-check an apparently-
    # unchanged head before declining a trigger. Defaults to the enumerated
    # SHA (snapshot still current); scenario 7e overrides it to simulate a
    # push that landed after the enumeration snapshot.
    echo "${MOCK_LIVE_HEAD_SHA:-abc123}"
elif [ "$1" = "api" ]; then
    # One pass over argv collects everything the stub branches on: the endpoint
    # (any positional, so flags like --paginate/--jq don't need stub edits), the
    # HTTP method, and a `-f body=…` payload. A POST and a GET to the same
    # issues/<n>/comments URL are distinguished by method, not URL shape.
    url=""; method="GET"; body=""
    for arg in "$@"; do
        case "$arg" in
            repos/*) [ -n "$url" ] || url="$arg" ;;   # first match, as `break` did
            POST) method="POST" ;;                    # the only verb this stub branches on
            body=*) body="${arg#body=}" ;;
        esac
    done
    if [[ "$url" == */issues/*/comments* ]]; then
        if [ "$method" = "POST" ]; then
            # The orchestrator's "already reviewed" decline. Record the body,
            # then echo a comment object back.
            [ -n "${COMMENT_POST_LOG:-}" ] && echo "POST $body" >> "$COMMENT_POST_LOG"
            # Opt-in POST failure (same shape as MOCK_PERMISSION_RC) so the
            # decline's failure path — log the real cause and STILL watermark,
            # since a failed POST is not retried this round (scenario 7d) — is
            # exercised rather than assumed.
            if [ -n "${MOCK_POST_RC:-}" ]; then
                echo "gh: HTTP 403: simulated-abuse-limit" >&2
                exit "$MOCK_POST_RC"
            fi
            echo '{"id":1}'
            exit 0
        fi
        # Count comment-fetches so the idle-skip scenarios can assert the
        # gate avoided the core gh call entirely.
        [ -n "${COMMENT_FETCH_LOG:-}" ] && echo "FETCH $url" >> "$COMMENT_FETCH_LOG"
        # Pagination-aware mode: when MOCK_COMMENTS_PAGE1_FILE is set,
        # emit page 1 always and emit page 2 ONLY if --paginate is in
        # args AND MOCK_COMMENTS_PAGE2_FILE is set. Lets scenario 13
        # fence the original bug — review.sh dropping --paginate from
        # the helper would lose any trigger past page 1. Legacy
        # single-file mode (MOCK_COMMENTS_FILE) is what every earlier
        # scenario uses; pagination doesn't matter there.
        if [ -n "${MOCK_COMMENTS_PAGE1_FILE:-}" ]; then
            cat "$MOCK_COMMENTS_PAGE1_FILE"
            if [ -n "${MOCK_COMMENTS_PAGE2_FILE:-}" ]; then
                for arg in "$@"; do
                    if [ "$arg" = "--paginate" ]; then
                        cat "$MOCK_COMMENTS_PAGE2_FILE"
                        break
                    fi
                done
            fi
        else
            cat "$MOCK_COMMENTS_FILE"
        fi
    elif [[ "$url" == */pulls/*/commits* ]]; then
        # Old date so cooldown is bypassed if it ever runs. None of these
        # scenarios should reach the cooldown branch (all are same-SHA;
        # the skip happens before cooldown), but stub it anyway so a
        # regression that leaks through doesn't hang on a missing stub.
        echo "2020-01-01T00:00:00Z"
    elif [[ "$url" == */collaborators/*/permission ]]; then
        # Opt-in: simulate a 403 rate-limit on the permission check → an
        # INDETERMINATE trust result (rc=2). Default unset → normal path below.
        if [ -n "${MOCK_PERMISSION_RC:-}" ]; then
            echo "gh: HTTP 403: API rate limit exceeded (simulated)" >&2
            exit "$MOCK_PERMISSION_RC"
        fi
        # Extract the username segment between "collaborators/" and "/permission".
        user="${url##*/collaborators/}"
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

# Stub `flock` and `timeout` ONLY when missing — review.sh's fan-out uses
# `timeout -k ...` and lib/locking.sh uses `flock -n FD`, both real production
# deps. On Linux the `command -v` gates inside the helpers find /usr/bin/* and
# skip the stubs, so `just test` keeps proving the real wiring. On macOS dev the
# shared worker-smoke-helpers stubs fill the gap with matching semantics: flock
# via python3 fcntl.flock(2), timeout via bash with `-k` group-kill. Shared so
# the shim contract can't drift between this smoke and just-test-flock-smoke.
# shellcheck source=lib/tests/worker-smoke-helpers.sh
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"
write_worker_flock_stub_if_missing "$HOME/.local/bin"
write_worker_timeout_stub_if_missing "$HOME/.local/bin"

# Sandbox lib dir: real state-io.sh + auth.sh, stub worker that logs the
# dispatch (including the trigger-comment file path so trust-gate
# scenarios can assert presence/absence) instead of running a review.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/bootstrap.sh"     "$REVIEWER_LIB_DIR/bootstrap.sh"  # sources the core below
cp "$PROJECT_ROOT/lib/state-io.sh"      "$REVIEWER_LIB_DIR/state-io.sh"
cp "$PROJECT_ROOT/lib/auth.sh"          "$REVIEWER_LIB_DIR/auth.sh"
cp "$PROJECT_ROOT/lib/gh-retry.sh"      "$REVIEWER_LIB_DIR/gh-retry.sh"   # auth.sh sources it
cp "$PROJECT_ROOT/lib/locking.sh"       "$REVIEWER_LIB_DIR/locking.sh"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"
cp "$PROJECT_ROOT/lib/gh-comments.sh"   "$REVIEWER_LIB_DIR/gh-comments.sh"
cp "$PROJECT_ROOT/lib/run-dir.sh"       "$REVIEWER_LIB_DIR/run-dir.sh"
cp "$PROJECT_ROOT/lib/pr-enumerate.sh"  "$REVIEWER_LIB_DIR/pr-enumerate.sh"
cp "$PROJECT_ROOT/lib/queue.sh"         "$REVIEWER_LIB_DIR/queue.sh"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<'WORKER'
#!/bin/bash
# Args from review.sh: REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# TRIGGER_COMMENT_FILE comes through as an env var.
echo "WORKER_DISPATCHED repo=$1 pr=$2 sha=$3 force_whole=$6 trigger_file=${TRIGGER_COMMENT_FILE:-} dispatcher_tick=${DISPATCHER_TICK_AT:-}" >> "$LOG_FILE"
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

. "$REVIEWER_LIB_DIR/state-io.sh"

# Seed runs/ with an author-visible run for this PR. The orchestrator's
# dispatch gate (KNOWN_SHA via latest_author_visible_review_sha) and
# slash-command cutoff (started_at via
# latest_author_visible_review_started_at) read exclusively from runs/
# — state.json was retired entirely in PR #38. Most scenarios want
# "we already reviewed abc123" → seed a posted run with
# reviewed_sha=abc123.
seed_run() {
    local slug="$1" pr="$2" ts="$3" sha="$4" verdict="${5:-COMMENT}"
    local started_at="${6:-2026-04-29T14:00:00Z}"
    local rd="$STATE_DIR/runs/${slug}__${pr}__${ts}__${sha:0:7}"
    mkdir -p "$rd/agents/aggregator"
    printf '## prior review\n\nVERDICT: %s\n' "$verdict" > "$rd/agents/aggregator/output.md"
    # started_at is what review.sh's slash-command cutoff now reads (via
    # latest_author_visible_review_started_at). posted_at + reviewed_sha
    # remain for KNOWN_SHA + author-visible filtering. All three live in
    # the SAME meta.json so a regression that re-routes any of the three
    # back to state.json shows up here.
    printf '{"status":"completed","posted_at":"2026-04-29T15:00:00Z","started_at":"%s","reviewed_sha":"%s"}' "$started_at" "$sha" > "$rd/meta.json"
    echo "$rd"
}
clear_seeded_runs() {
    rm -rf "$STATE_DIR/runs"
    mkdir -p "$STATE_DIR/runs"
}
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null

# --- Worker self-termination contract (static check) ----------------------
# Detached workers are bounded only by their `timeout` wraps, which must
# escalate to SIGKILL (`timeout -k`) or a SIGTERM-ignoring tree outlives its
# ceiling and accumulates in the unit cgroup — the cascade the deleted
# /unstick-kwr recipe used to clear by hand. Scenario 12b exercises the
# dispatcher wrap end-to-end; just-test-flock-smoke scenario 4 covers the
# inner `just test` wrap's -k (run_just_test). The SIGTERM-cleanup trap
# can't be cheaply wedged in a smoke, so it's fenced statically here.
grep -q "trap 'exit 143' TERM" "$PROJECT_ROOT/lib/review-one-pr.sh" || {
    echo "FAIL setup: lib/review-one-pr.sh missing the SIGTERM trap — a timeout-killed worker won't run the EXIT cleanup and leaves the 👀 placeholder dangling"
    exit 1
}

# --- TMPDIR fence (single-source-of-truth) --------------------------------
# pr-reviewer.service combines PrivateTmp=yes (sandbox) with
# KillMode=process (workers detach). When the orchestrator returns, the
# unit-private /tmp gets torn down a few seconds later — any detached
# worker doing `mktemp` in /tmp lands in a dead mount namespace and the
# call fails with `No such file or directory`. The fix lives at a single
# seam: tracked-repos.sh pins TMPDIR=$STATE_DIR/tmp unconditionally,
# AFTER it sources config.env. Every entrypoint (review.sh,
# lib/review-one-pr.sh, the -from-replies / -poller / -refresh siblings)
# sources tracked-repos.sh and inherits the pin for free, with no
# order-sensitive copy in each script. This grep fences a regression
# that drops the pin from the loader OR moves it before config.env's
# source — either reintroduces the unit-private /tmp failure mode.
LOADER="$PROJECT_ROOT/lib/tracked-repos.sh"
grep -qF 'export TMPDIR="$STATE_DIR/tmp"' "$LOADER" || {
    echo "FAIL setup: lib/tracked-repos.sh is missing the unconditional \$STATE_DIR/tmp TMPDIR pin — fallback chains or per-script copies let an inherited or config.env-set TMPDIR re-route mktemp into the unit-private /tmp"
    exit 1
}
# Ordering check: the pin must follow the config.env source (otherwise
# config.env's TMPDIR shadows the pin and detached workers regress).
loader_pin_line=$(grep -nF 'export TMPDIR="$STATE_DIR/tmp"' "$LOADER" | head -1 | cut -d: -f1)
loader_cfg_line=$(grep -nF '. "$CONFIG_ENV_FILE"' "$LOADER" | head -1 | cut -d: -f1)
if [ -z "$loader_cfg_line" ] || [ -z "$loader_pin_line" ] || [ "$loader_pin_line" -le "$loader_cfg_line" ]; then
    echo "FAIL setup: lib/tracked-repos.sh — TMPDIR pin must come AFTER the config.env source (got pin@${loader_pin_line:-MISSING}, config.env@${loader_cfg_line:-MISSING})"
    exit 1
fi

export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
# Default trust set for the existing scenarios: srosro is the bot operator
# and "someuser" is the realistic external collaborator shape. Scenarios
# that need to test the untrusted path override this just before
# run_orchestrator.
export MOCK_TRUSTED_USERS="$BOT_USER someuser"

run_orchestrator() {
    : > "$LOG_FILE"   # reset
    : > "$COMMENT_FETCH_LOG"
    : > "$COMMENT_POST_LOG"
    # Each scenario models an independent tick, so stop-state must not leak
    # between them: a scenario whose stub 403s with rate-limit wording correctly
    # stamps the shared pause, which would then make every later scenario's
    # dispatcher stop claiming before reaching the gate under test.
    rm -f "$(gh_pause_file)"
    # Fail loud on a malformed comments fixture. An unparseable one makes
    # fetch_issue_comments fail, so the PR is dropped BEFORE any gate under
    # test — every assertion then passes vacuously. The trap is one printf
    # away: `\n` inside a body expands to a real newline, which is an illegal
    # unescaped control character in JSON (needs `\\n`).
    local f
    for f in "${MOCK_COMMENTS_FILE:-}" "${MOCK_COMMENTS_PAGE1_FILE:-}" "${MOCK_COMMENTS_PAGE2_FILE:-}"; do
        [ -n "$f" ] && [ -f "$f" ] || continue
        jq -e . "$f" >/dev/null 2>&1 || { echo "FATAL: malformed comments fixture $f"; cat "$f"; exit 1; }
    done
    # ENUMERATE_SECS=0 forces a queue refresh every invocation (the floor is
    # always elapsed), so each scenario re-enumerates and re-evaluates its own
    # MOCK_COMMENTS from scratch rather than consuming a prior scenario's queue.
    ENUMERATE_SECS=0 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true
}

assert_decline_posts() {
    local expected="$1" label="$2" n
    n=$(grep -c 'already-reviewed' "$COMMENT_POST_LOG" || true)
    [ "$n" -eq "$expected" ] && return
    echo "FAIL $label: expected $expected decline POST(s), got $n"
    echo "--- posts ---"; cat "$COMMENT_POST_LOG"
    exit 1
}

# One already-reviewed-head suppression case: a fresh /update-review trigger + a
# prior decline by <author> at <created_at>, asserting the round's decline count.
# The matcher keys on bot authorship + exact header, so those two are the only
# axes that matter — pass "$BOT_USER" for the bot cases so the identity reads off
# the call site. `\\n` not `\n` keeps the body valid JSON (run_orchestrator
# fixture-checks it); the markers are literal (the test shell doesn't export those).
assert_decline_suppression_case() {
    local author="$1" created_at="$2" expected="$3" label="$4"
    printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-update-review"},{"created_at":"%s","user":{"login":"%s"},"body":"<!-- knightwatch-reviewer:auto-post -->\\n<!-- knightwatch-reviewer:already-reviewed -->\\ndecline"}]\n' \
        "$NOW_ISO" "$created_at" "$author" > "$MOCK_COMMENTS_FILE"
    run_orchestrator
    assert_decline_posts "$expected" "$label"
}

count_comment_fetches() {
    local n
    n=$(grep -c '^FETCH ' "$COMMENT_FETCH_LOG" 2>/dev/null || true)
    echo "${n:-0}"
}

count_dispatches() {
    # Workers fan out via `timeout ... worker.sh ... &` in review.sh
    # and write WORKER_DISPATCHED lines asynchronously after the
    # orchestrator has already exited. A synchronous grep beats the
    # write on fast machines, producing flaky 0-counts on dispatch
    # scenarios. Read the orchestrator's own promise (its
    # synchronously-logged "Fan-out: dispatched N worker(s)" line) and
    # poll until N writes show up — capped so 0-dispatch scenarios stay
    # fast (orchestrator promised 0 → return 0 immediately, no wait).
    local promised actual
    promised=$(grep -oE 'dispatched [0-9]+ worker' "$LOG_FILE" 2>/dev/null \
                  | grep -oE '[0-9]+' | tail -1)
    promised="${promised:-0}"
    if [ "$promised" -eq 0 ]; then
        echo 0
        return
    fi
    for _ in $(seq 1 50); do   # up to ~5s
        actual=$(grep -c '^WORKER_DISPATCHED ' "$LOG_FILE" 2>/dev/null || true)
        actual="${actual:-0}"
        [ "$actual" -ge "$promised" ] && break
        sleep 0.1
    done
    echo "$actual"
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
# Pins the FORCE_REVIEW gate on scenario 7's skip log: the no-trigger skip is
# the common case (every quiet already-reviewed PR, every tick), so it must
# stay silent or the log drowns.
if grep -q 'nothing to diff' "$LOG_FILE"; then
    echo "FAIL scenario 1 (skip-log gating): no-trigger skip must not log 'nothing to diff'"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
# Same gate, PR-visible side: a quiet already-reviewed PR must never be
# commented on. This is the assertion that keeps the bot from becoming noisy
# on every tracked repo.
assert_decline_posts 0 "scenario 1 (decline gating)"

# Scenario 2: same SHA, bare @<bot> mention → no dispatch. @-mentions are
# not triggers in the new model — only /srosro-review and
# /srosro-update-review are. This guards against a regression that
# accidentally re-introduces an @-mention trigger.
echo "  scenario 2: same SHA + bare @-mention (mentions are not triggers)..."
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"hey @srosro can you take another look?"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 2 (mentions-are-not-triggers regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 3: same SHA, /srosro-review → 1 dispatch with FORCE_WHOLE_PR=true.
# /srosro-review must still work even on an unchanged SHA; the worker uses
# gh pr diff for the full PR diff regardless of base SHA, so there's
# always something to review.
echo "  scenario 3: same SHA + /srosro-review comment..."
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
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
if ! grep -qF "trigger_file=$STATE_DIR/tmp/pr-review-trigger" "$LOG_FILE"; then
    echo "FAIL scenario 3: expected trigger_file=\$STATE_DIR/tmp/pr-review-trigger.* in dispatch (someuser is in MOCK_TRUSTED_USERS) — anchors the bugfix path so a regression to /tmp fails here"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 4 (bot self-trigger filter): same SHA, comment whose body
# carries the auto-post marker → no dispatch. The bot's own posted review
# comments prepend `<!-- knightwatch-reviewer:auto-post -->` to the body
# AND the usage footer always names the slash commands literally; the
# orchestrator excludes any comment containing that marker so a successful
# review doesn't re-trigger itself on the next tick.
echo "  scenario 4: same SHA + auto-post marker in body (self-trigger filter)..."
printf '[{"created_at":"%s","user":{"login":"%s"},"body":"<!-- knightwatch-reviewer:auto-post -->\\n/srosro-review"}]\n' "$NOW_ISO" "$BOT_USER" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 4 (self-trigger filter regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 5 (single-account regression): same SHA, comment authored by
# BOT_USER (the bot's own GH identity) with a /srosro-review body but NO
# marker → 1 dispatch. This is the case the earlier `.user.login != $user`
# filter (e1d91a0) silently broke: in single-account deployments the
# human running the bot posts as BOT_USER, and a user-based filter drops
# their legitimate slash commands along with the bot's auto-posts. The
# content-marker filter must let unmarked comments through regardless of
# author.
echo "  scenario 5: same SHA + /srosro-review by BOT_USER without marker (single-account)..."
printf '[{"created_at":"%s","user":{"login":"%s"},"body":"/srosro-review"}]\n' "$NOW_ISO" "$BOT_USER" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 5 (single-account regression): expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 5: expected force_whole=true in dispatch"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -qF "trigger_file=$STATE_DIR/tmp/pr-review-trigger" "$LOG_FILE"; then
    echo "FAIL scenario 5: expected trigger_file=\$STATE_DIR/tmp/pr-review-trigger.* in dispatch (BOT_USER is in MOCK_TRUSTED_USERS) — anchors the bugfix path"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 5b: same SHA + BOT_USER /srosro-review carrying the auto-trigger
# marker (the re-request poller's self-identifying trigger). srosro is trusted
# (as in scenario 5), so the trust gate would stage framing — but review.sh's
# marker-strip blanks the body first, so the dispatch still happens (whole-PR)
# with NO trigger_file. This isolates the marker-strip from the trust gate: the
# poller's "auto-posted" attribution must never reach trigger-comment.md.
echo "  scenario 5b: same SHA + BOT_USER /srosro-review WITH auto-trigger marker → dispatch, no trigger_file..."
printf '[{"created_at":"%s","user":{"login":"%s"},"body":"/srosro-review\\n\\n<sub>auto-posted by the review bot.</sub><!-- knightwatch-reviewer:auto-trigger -->"}]\n' "$NOW_ISO" "$BOT_USER" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 5b: expected 1 dispatch (the auto-trigger marker must NOT suppress dispatch), got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 5b: expected force_whole=true in dispatch"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if grep -qF "trigger_file=$STATE_DIR/tmp/pr-review-trigger" "$LOG_FILE"; then
    echo "FAIL scenario 5b: the auto-trigger note was staged as trigger-comment.md framing (review.sh marker-strip regressed)"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 6 (trigger-comment trust gate): same SHA, /srosro-review from a
# commenter without push access → the trigger still dispatches a worker
# (so poll-pr-actions's re-request trigger and external requesters keep working), but the
# orchestrator does NOT stage `.codex-scratch/trigger-comment.md`. The
# bot's trigger-comment plumbing weights the comment body heavily on the
# pipeline that ends in `gh pr review --approve`, so a drive-by
# commenter's prose is kept off that path. Stranger is deliberately
# omitted from MOCK_TRUSTED_USERS for this scenario.
echo "  scenario 6: same SHA + /srosro-review from untrusted commenter (trigger-comment trust gate)..."
MOCK_TRUSTED_USERS="srosro" \
    printf '[{"created_at":"%s","user":{"login":"stranger"},"body":"/srosro-review please"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
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
if grep -qE 'trigger_file=[^[:space:]]+' "$LOG_FILE"; then
    echo "FAIL scenario 6 (trust gate regression): expected trigger_file empty for untrusted commenter, but a path was staged"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 6b (indeterminate-trigger-defer): same SHA, /srosro-review from a
# commenter whose permission check returns 403 (rate-limited account → rc=2
# indeterminate). Unlike the untrusted case above (which still dispatches), the
# dispatcher must DEFER — no dispatch, and no same-SHA idle watermark — so the
# unconsumed trigger retries next tick once the throttle clears. Fences
# review.sh's trigger-defer branch.
echo "  scenario 6b: same SHA + /srosro-review under indeterminate trust (403) → defer, no dispatch, no watermark..."
rm -f "$STATE_DIR/seen-updated/cncorp_plow__1"   # clear any residue so the assertion is decisive
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_PERMISSION_RC=1 run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 6b: expected 0 dispatches under indeterminate trust (defer), got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q "trust check deferred" "$LOG_FILE"; then
    echo "FAIL scenario 6b: expected 'trust check deferred' log line on the deferred trigger"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if [ -f "$STATE_DIR/seen-updated/cncorp_plow__1" ]; then
    echo "FAIL scenario 6b: idle watermark written on a deferred trigger — must stay unconsumed for next-tick retry"
    exit 1
fi

# Scenario 7: same SHA, /srosro-update-review → no dispatch. Incremental
# triggers on an unchanged SHA hit the empty-diff abort path, so we skip
# at the orchestrator instead of burning a worker. The trigger stays open
# until commits land. The longer command must NOT also satisfy the
# /srosro-review (whole-PR) substring check.
#
# Plus: after the skip, no trigger-comment tempfile may remain in
# $STATE_DIR/tmp. someuser is in MOCK_TRUSTED_USERS, so a regression that
# materializes the file BEFORE the skip check would leak a stale tempfile
# the worker never cleans up (no worker runs). PrivateTmp's tear-down
# used to mask this leak in production; with tempfiles routed to the
# durable $STATE_DIR/tmp, the leak is real and must be fenced.
echo "  scenario 7: same SHA + /srosro-update-review (skipped on unchanged SHA)..."
rm -f "$STATE_DIR/tmp/pr-review-trigger".*  # clear residue from earlier scenarios
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-update-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 7 (incremental same-SHA skip regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
leaked=$(find "$STATE_DIR/tmp" -maxdepth 1 -name 'pr-review-trigger.*' -type f 2>/dev/null)
if [ -n "$leaked" ]; then
    echo "FAIL scenario 7 (skip-path tempfile leak): pre-skip mktemp leaked a trigger file under \$STATE_DIR/tmp:"
    echo "$leaked"
    exit 1
fi
# The skip must say so: a swallowed trigger that leaves no trace is
# indistinguishable from an enumeration failure when an operator later asks
# "why didn't we get another review?". Exactly one line per evaluation — the
# seen-updated watermark, not a per-tick reset, is what bounds it in prod.
n=$(grep -c 'nothing to diff' "$LOG_FILE" || true)   # || true: grep -c exits 1 on a zero count
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 7 (silent skip): expected exactly 1 'nothing to diff' log line, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
# …and the requester gets told on the PR too. The log only reaches an operator
# with shell access to the reviewer host; the thing that POSTED the trigger is
# usually an agent on the PR, for which a silent skip is a dead end.
assert_decline_posts 1 "scenario 7 (decline not posted)"

# Scenario 7b: the decline is posted at most ONCE per review round — the
# re-post loop fence. Posting bumps the PR's updatedAt past the watermark, so
# the next tick re-evaluates and finds the SAME still-unconsumed trigger; without
# the suppression check that yields one comment per tick, forever. Feed the prior
# decline back as an existing comment (what the real thread would carry) and
# require silence. Guards the one failure mode that would be visible to every
# repo the bot watches.
echo "  scenario 7b: decline posted at most once per round (re-post loop fence)..."
# A bot-authored decline from this same round suppresses the re-post — the loop
# fence. Posting bumps updatedAt past the watermark, so the next tick finds the
# SAME unconsumed trigger; without suppression that's one comment per tick,
# forever — the one failure mode visible to every repo the bot watches.
assert_decline_suppression_case "$BOT_USER" "$NOW_ISO" 0 "scenario 7b (decline re-post loop)"
# Positive control — must stay attached to the run above, whose only assertion is
# negative. run_orchestrator truncates $LOG_FILE, so any run inserted between the
# two describes the WRONG invocation and silently re-opens the vacuity gap:
# anything dropping the PR before the decline gate (idle-skip watermark, trust
# defer, an enumeration change) would satisfy the negative for the wrong reason.
n=$(grep -c 'nothing to diff' "$LOG_FILE" || true)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 7b (never reached the gate): expected 1 'nothing to diff' log line, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
# The skip itself must still happen — suppressing the comment must not
# accidentally turn the round into a dispatch.
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 7b: expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
# …but only a BOT-authored decline suppresses. A non-bot commenter pasting the
# marker must NOT mute the notification (authorship + exact-header, not a bare
# substring). The expected-1 assertion is itself the positive control.
assert_decline_suppression_case someuser "$NOW_ISO" 1 "scenario 7b (marker spoofed by a non-bot commenter)"

# Scenario 7c: the OTHER half of the idempotency contract — suppression is
# scoped to the current review round, not the PR's lifetime. A decline that
# predates the last review's cutoff must NOT suppress a fresh one, or dropping
# the `.created_at > $since` clause would silently mute the bot for the rest of
# the PR's life. That regression is an ABSENCE of a comment, which every
# assertion in 7b still passes through.
echo "  scenario 7c: a decline older than the last review re-arms (suppression is per-round)..."
assert_decline_suppression_case "$BOT_USER" "2020-01-01T00:00:00Z" 1 "scenario 7c (suppression never re-arms)"

# Scenario 7d: a FAILED decline POST logs its real cause and stays watermarked.
# Both halves are deliberate. The cause must survive (not /dev/null) or a
# locked/archived PR fails behind an opaque message forever. The watermark must
# still be written, or a PERMANENT failure re-POSTs every tick on every affected
# PR — feeding the secondary rate limit the idle-skip exists to prevent. The
# trigger stays unconsumed, so the next real PR event retries.
echo "  scenario 7d: a failed decline POST logs its cause and stays watermarked (no unbounded retry)..."
rm -f "$STATE_DIR/seen-updated/cncorp_plow__1"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-update-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_POST_RC=1 run_orchestrator
if ! grep -q 'simulated-abuse-limit' "$LOG_FILE"; then
    echo "FAIL scenario 7d (opaque failure): the POST's stderr cause must reach the log, not /dev/null"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if [ ! -f "$STATE_DIR/seen-updated/cncorp_plow__1" ]; then
    echo "FAIL scenario 7d (unbounded retry): watermark withheld after a failed decline POST — a permanent failure would re-POST every tick"
    exit 1
fi

# Scenario 7e: the enumerated head is STALE — a push landed between the
# GraphQL snapshot and this PR's turn in the loop, so a fresh trigger would
# otherwise be judged against a superseded SHA. The requester then gets a
# "your push isn't there" decline seconds after pushing, and the review they
# asked for waits for the next tick (observed live: head moved 85s before the
# decline fired). Re-fetching the live head must flip the decision: dispatch,
# no decline.
echo "  scenario 7e: stale enumerated head + /srosro-update-review → dispatch, no decline..."
rm -f "$STATE_DIR/seen-updated/cncorp_plow__1"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-update-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
MOCK_LIVE_HEAD_SHA=def456 run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 7e (stale-head decline): expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
assert_decline_posts 0 "scenario 7e (declined against a superseded head)"
# …and the worker must be handed the LIVE head, not the superseded one. The
# worker re-reads HEAD after checkout, so this pins the spec contract rather
# than the review itself: a refactor that suppresses the decline without
# adopting LIVE_SHA names the run dir with a superseded SHA and ships a spec
# that no longer reflects the head the dispatch decision was made on.
if ! grep -q 'WORKER_DISPATCHED .* sha=def456' "$LOG_FILE"; then
    echo "FAIL scenario 7e (stale spec): worker dispatched with the enumerated SHA, not the live head"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 8: same SHA, /srosro-approve → no dispatch. Approve requests
# are handled out-of-band by poll-pr-actions.sh, not by the review
# orchestrator. The orchestrator's substring filter looks for
# /srosro-review and /srosro-update-review; /srosro-approve must not
# match either. Guards against a future filter change that accidentally
# triggers a re-review on every approve request.
echo "  scenario 8: same SHA + /srosro-approve (handled by poll-pr-actions, not orchestrator)..."
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-approve looks good"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 8 (approve-as-review regression): expected 0 dispatches, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 9: orchestrator returns quickly even when a worker is still
# running. Pre-detach behavior had the orchestrator `wait` for every
# forked worker before exiting, so a slow worker (15–20 min in
# production) blocked the next 2-min timer firing and made
# /srosro-update-review pickup unboundedly slow. With the post-fan-out
# `wait` loop removed, the orchestrator must dispatch the worker and
# return promptly, regardless of worker runtime.
echo "  scenario 9: slow worker — orchestrator returns within 5s, worker keeps running..."
# Replace the worker stub with one that sleeps "indefinitely" (long
# enough that the orchestrator's `wait` would block the test if it
# regressed). The stub writes its own PID so the test can kill the
# exact process at cleanup time — `pkill -f "sleep 60"` is too broad
# (would match unrelated `sleep 60` processes on a shared CI box).
WORKER_MARKER="$TMPDIR/worker-started.flag"
WORKER_PID_FILE="$TMPDIR/worker.pid"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<WORKER
#!/bin/bash
echo "WORKER_DISPATCHED repo=\$1 pr=\$2 sha=\$3 force_whole=\$6 trigger_file=\${TRIGGER_COMMENT_FILE:-}" >> "$LOG_FILE"
echo \$\$ > "$WORKER_PID_FILE"
touch "$WORKER_MARKER"
exec sleep 60   # exec preserves PID so reap_worker hits the actual sleeper, not the wrapper shell
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

reap_worker() {
    [ -f "$WORKER_PID_FILE" ] || return 0
    local pid; pid=$(cat "$WORKER_PID_FILE")
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}

printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"

# Time the orchestrator. If it returns in <5s the wait was correctly
# dropped; if it sits at 60s the regression is back.
: > "$LOG_FILE"
START=$(date +%s)
ENUMERATE_SECS=0 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
ORCH_PID=$!
# Cap the test at 10s so a regression doesn't hang CI for a full minute.
TIMEOUT=10
ELAPSED=0
while kill -0 "$ORCH_PID" 2>/dev/null; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        kill "$ORCH_PID" 2>/dev/null
        echo "FAIL scenario 9 (wait-loop regression): orchestrator did not return within ${TIMEOUT}s — likely waiting on the slow worker"
        echo "--- log ---"; cat "$LOG_FILE"
        # Reap the still-running worker so the trap's rm -rf can run.
        pkill -P "$ORCH_PID" 2>/dev/null || true
        reap_worker
        exit 1
    fi
done
END=$(date +%s)
ORCH_ELAPSED=$((END - START))

[ "$ORCH_ELAPSED" -lt 5 ] || { reap_worker; echo "FAIL scenario 9: orchestrator took ${ORCH_ELAPSED}s, expected <5s"; cat "$LOG_FILE"; exit 1; }

# Sanity: the worker actually got dispatched.
[ -f "$WORKER_MARKER" ] || { reap_worker; echo "FAIL scenario 9: worker never started — orchestrator may have errored before fan-out"; cat "$LOG_FILE"; exit 1; }

# Liveness: scenario 9 claims "worker keeps running." Verify the worker
# PID is actually still alive AFTER the orchestrator exited. Catches a
# regression where (e.g.) cgroup-kill on orchestrator exit would leave
# WORKER_MARKER touched but the sleep dead.
WORKER_PID=$(cat "$WORKER_PID_FILE")
[ -n "$WORKER_PID" ] && kill -0 "$WORKER_PID" 2>/dev/null || { reap_worker; echo "FAIL scenario 9 (worker-died-with-orchestrator regression): worker PID '$WORKER_PID' is no longer alive after orchestrator exit"; exit 1; }

# Reap the sleeping worker so the test exits cleanly.
reap_worker

# Scenario 10: per-PR flock provides mutual exclusion across separate
# review-one-pr.sh invocations. Calls acquire_pr_lock() (the same
# function lib/review-one-pr.sh sources from lib/locking.sh) so a
# regression that moves the lock dir back to /tmp would have to break
# the helper too. Behavior + structural assertions together: the
# second concurrent acquirer must lose, AND the lock file path must
# be under $STATE_DIR/locks/, never /tmp.
echo "  scenario 10: per-PR flock — second concurrent acquire loses on contention, lock path under \$STATE_DIR..."

LOCK_TEST_STATE_DIR="$TMPDIR/lock-test-state"
mkdir -p "$LOCK_TEST_STATE_DIR"

HOLDER_MARKER="$TMPDIR/holder-acquired.flag"
HOLDER_RELEASE="$TMPDIR/holder-release.flag"
cat > "$TMPDIR/holder.sh" <<HOLDER
#!/usr/bin/env bash
. "$REVIEWER_LIB_DIR/locking.sh"
if ! acquire_pr_lock "$LOCK_TEST_STATE_DIR" "test_repo__1"; then
    echo "HOLDER_FAILED_TO_ACQUIRE" >&2
    exit 1
fi
echo "got_lock pid=\$\$ file=\$PR_LOCK_FILE" > "$HOLDER_MARKER"
for i in \$(seq 1 100); do
    [ -f "$HOLDER_RELEASE" ] && exit 0
    sleep 0.1
done
exit 0
HOLDER
chmod +x "$TMPDIR/holder.sh"

bash "$TMPDIR/holder.sh" >"$TMPDIR/holder.log" 2>&1 &
HOLDER_PID=$!
for _ in $(seq 1 50); do
    [ -f "$HOLDER_MARKER" ] && break
    sleep 0.1
done
[ -f "$HOLDER_MARKER" ] || {
    kill "$HOLDER_PID" 2>/dev/null
    echo "FAIL scenario 10: holder never acquired the lock"
    echo "--- holder.log ---"; cat "$TMPDIR/holder.log"
    echo "--- holder.sh ---"; cat "$TMPDIR/holder.sh"
    exit 1
}

if ( . "$REVIEWER_LIB_DIR/locking.sh" && acquire_pr_lock "$LOCK_TEST_STATE_DIR" "test_repo__1" ); then
    touch "$HOLDER_RELEASE"; wait "$HOLDER_PID" 2>/dev/null
    echo "FAIL scenario 10 (lock-isolation regression): contender acquired lock while holder still held it"
    cat "$HOLDER_MARKER"; exit 1
fi

HOLDER_LOCK_FILE=$(grep -o 'file=[^ ]*' "$HOLDER_MARKER" | sed 's/^file=//')
if [[ "$HOLDER_LOCK_FILE" != "$LOCK_TEST_STATE_DIR/locks/test_repo__1" ]]; then
    touch "$HOLDER_RELEASE"; wait "$HOLDER_PID" 2>/dev/null
    echo "FAIL scenario 10 (lock-path regression): expected $LOCK_TEST_STATE_DIR/locks/test_repo__1 but got '$HOLDER_LOCK_FILE'"
    exit 1
fi

touch "$HOLDER_RELEASE"
wait "$HOLDER_PID" 2>/dev/null
( . "$REVIEWER_LIB_DIR/locking.sh" && acquire_pr_lock "$LOCK_TEST_STATE_DIR" "test_repo__1" ) || { echo "FAIL scenario 10: post-release acquire failed; lock may be stuck"; exit 1; }

# Scenario 11: review.sh fails LOUD if the worker script is missing
# or not executable. With detached fan-out, `bash worker &` returns 0
# regardless of whether the worker actually started, so an accidental
# `chmod -x` or a missing symlink would silently produce "dispatched N
# worker(s)" while no review ran. The pre-fan-out executable check
# catches that class.
echo "  scenario 11: missing/non-executable worker — orchestrator fails loud, no dispatch..."
chmod -x "$REVIEWER_LIB_DIR/review-one-pr.sh"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
: > "$LOG_FILE"
if ENUMERATE_SECS=0 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1; then
    chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"
    echo "FAIL scenario 11 (silent-dispatch-failure regression): review.sh exited 0 with a non-executable worker"
    cat "$LOG_FILE"; exit 1
fi
grep -q "FATAL: $REVIEWER_LIB_DIR/review-one-pr.sh missing or not executable" "$LOG_FILE" || { chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"; echo "FAIL scenario 11: expected FATAL log line about missing worker"; cat "$LOG_FILE"; exit 1; }
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"   # restore for any later scenario

# Scenario 12: per-worker WORKER_TIMEOUT bounds wedged-worker risk. With
# detached workers, the service-level TimeoutStartSec=90min no longer caps
# worker runtime — a hung Codex/test phase could hold the per-PR flock
# indefinitely. review.sh wraps each worker with `timeout -k "$WORKER_KILL_AFTER"`,
# so the ceiling escalates SIGTERM → SIGKILL. This drives a worker that IGNORES
# SIGTERM (the real wedge — a bare SIGTERM leaves it running, the cascade the
# deleted /unstick recipe used to clear by hand) and asserts the kill-after
# SIGKILL reaps it. Also fences the operator-facing "per-worker timeout" log.
echo "  scenario 12: WORKER_TIMEOUT — SIGTERM-ignoring worker is SIGKILLed via --kill-after..."
WEDGED_PID_FILE="$TMPDIR/wedged-worker.pid"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<TWORKER
#!/bin/bash
trap '' TERM   # ignore SIGTERM — only SIGKILL (via -k) can stop us
echo \$\$ > "$WEDGED_PID_FILE"
while :; do sleep 1; done   # outlives WORKER_TIMEOUT
TWORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
: > "$LOG_FILE"
WORKER_TIMEOUT=1s WORKER_KILL_AFTER=1s ENUMERATE_SECS=0 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
ORCH12_PID=$!
wait "$ORCH12_PID" 2>/dev/null || true

# Wait up to 6s for the SIGKILL escalation (1s timeout + 1s kill-after + slack).
for _ in $(seq 1 60); do
    [ -f "$WEDGED_PID_FILE" ] || { sleep 0.1; continue; }
    WEDGED_PID=$(cat "$WEDGED_PID_FILE")
    kill -0 "$WEDGED_PID" 2>/dev/null || break   # dead = -k SIGKILL landed
    sleep 0.1
done
WEDGED_PID=$(cat "$WEDGED_PID_FILE" 2>/dev/null || echo "")
if [ -n "$WEDGED_PID" ] && kill -0 "$WEDGED_PID" 2>/dev/null; then
    kill -KILL "$WEDGED_PID" 2>/dev/null || true
    echo "FAIL scenario 12 (no --kill-after regression): SIGTERM-ignoring worker PID $WEDGED_PID still alive ~6s after WORKER_TIMEOUT=1s + kill-after should have SIGKILLed it"
    exit 1
fi

# Operator-facing: the fan-out log line must surface the cap in force this tick.
grep -q "per-worker timeout 1s" "$LOG_FILE" || { echo "FAIL scenario 12: expected 'per-worker timeout 1s' in fan-out log line"; cat "$LOG_FILE"; exit 1; }

# Scenario 13: page-2 trigger fence. The original bug this PR exists to
# fix: review.sh's pre-DRY fetch was a single-page `gh api`, so any
# /srosro-update-review past page 1 (~30 comments) was silently
# dropped — review.sh saw no trigger and the orchestrator never
# dispatched a re-review. The gh stub here emits page 2 ONLY when
# --paginate is in args, so a regression that drops --paginate from
# lib/gh-comments.sh would make the trigger invisible and fail the
# dispatch assertion. Uses a different KNOWN_SHA so the changed-SHA
# branch handles dispatch (incremental triggers on an unchanged SHA
# are deliberately skipped — scenario 7 covers that path).
echo "  scenario 13: /srosro-update-review on page 2 of comments — page-2 pagination fence..."

# Restore a vanilla worker stub — scenarios 11 (chmod -x), 12 (sleep
# under timeout) left it in non-default state.
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<'WORKER'
#!/bin/bash
echo "WORKER_DISPATCHED repo=$1 pr=$2 sha=$3 force_whole=$6 trigger_file=${TRIGGER_COMMENT_FILE:-} dispatcher_tick=${DISPATCHER_TICK_AT:-}" >> "$LOG_FILE"
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

# Re-seed runs/ to report old_sha_999 so the dispatch gate sees a SHA
# different from the gh stub's headRefOid (abc123). started_at on the
# seeded run defaults to 2026-04-29T14:00:00Z (well in the past), so
# MOCK_COMMENTS_PAGE*_FILE timestamps written as "now" satisfy
# `created_at > started_at` for the slash-cutoff filter.
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "old_sha_999" "COMMENT" >/dev/null

PAGE1="$TMPDIR/page1.json"
PAGE2="$TMPDIR/page2.json"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"unrelated comment"}]\n' "$NOW_ISO" > "$PAGE1"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-update-review"}]\n' "$NOW_ISO" > "$PAGE2"
export MOCK_COMMENTS_PAGE1_FILE="$PAGE1"
export MOCK_COMMENTS_PAGE2_FILE="$PAGE2"
unset MOCK_COMMENTS_FILE   # force the pagination-aware branch in the stub

run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 13 (page-2 pagination regression): expected 1 dispatch on page-2 /srosro-update-review, got $n — review.sh likely dropped --paginate from the helper and lost the trigger"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if grep -q 'force_whole=true' "$LOG_FILE"; then
    echo "FAIL scenario 13: expected force_whole=false (incremental trigger), got force_whole=true"
    cat "$LOG_FILE"; exit 1
fi

# Scenario 14: TMPDIR pin survives both inherited TMPDIR and a config.env
# override. The structural greps at suite setup check the loader has the
# pin AND that it follows the config.env source — but those are textual.
# This scenario verifies the pin is effective end-to-end: dispatched
# trigger files must land under $STATE_DIR/tmp even when both the
# environment and config.env try to redirect TMPDIR.
echo "  scenario 14: TMPDIR pin overrides both inherited TMPDIR and config.env (post-load behavioral fence)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
rm -f "$STATE_DIR/tmp/pr-review-trigger".*
echo 'export TMPDIR="/tmp/should-not-be-honored-via-config-env"' > "$STATE_DIR/config.env"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
: > "$LOG_FILE"
TMPDIR="/tmp/should-not-be-honored-via-inheritance" ENUMERATE_SECS=0 \
    bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true
rm -f "$STATE_DIR/config.env"
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 14: expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -qF "trigger_file=$STATE_DIR/tmp/pr-review-trigger" "$LOG_FILE"; then
    echo "FAIL scenario 14 (post-load TMPDIR placement regression): expected trigger_file=\$STATE_DIR/tmp/pr-review-trigger.* but got something else — config.env or inherited TMPDIR shadowed the pin, likely because the pin in lib/tracked-repos.sh now sits BEFORE the config.env source"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 15 (infinite-dispatch-loop fence): orchestrator's KNOWN_SHA
# read sources from runs/<id>/meta.json — the only source of truth since
# state.json was retired in PR #38. Pre-retirement, a `gh pr comment`
# success + state_set failure would leave state.json carrying an OLDER
# SHA. On the next tick the orchestrator would dispatch again ("we last
# reviewed OLDER_SHA != HEAD"), the worker (also reading runs/) would
# see HEAD already reviewed and abort on empty diff, and the cycle
# would repeat every tick. Reading runs/ at the gate closes that loop.
#
# Fence: runs/ says HEAD (abc123 — the gh stub's headRefOid) is
# already reviewed. No /srosro-* trigger comments. Expect 0 dispatches.
# A regression that re-routes the gate to a stale state.json reader
# would dispatch here.
echo "  scenario 15: runs/ shows HEAD reviewed → no dispatch (infinite-loop fence)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
clear_seeded_runs
# runs/ correctly reports the actually-reviewed SHA (HEAD = abc123).
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
echo "[]" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 15 (infinite-dispatch-loop regression): expected 0 dispatches when runs/ shows HEAD already reviewed, got $n — orchestrator likely re-introduced a state.json read at the KNOWN_SHA gate"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 16 (changed-SHA dispatch from runs/): runs/ reports OLDER_SHA,
# HEAD is abc123 — orchestrator must dispatch when runs/ says we
# reviewed an older SHA than the current HEAD. The SHA delta alone
# drives dispatch (no /srosro-* trigger comments needed). Cooldown is
# bypassed because the gh stub returns a 2020-era commit date for
# /pulls/<n>/commits.
echo "  scenario 16: runs/ shows OLDER_SHA (HEAD differs) → 1 dispatch..."
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "older_sha_999" "COMMENT" >/dev/null
echo "[]" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 16 (runs/-sourced SHA gate): expected 1 dispatch when runs/ shows older SHA than HEAD, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 17 (slash-cutoff sourced from runs/started_at): the
# slash-command cutoff ("is this /srosro-review newer than the last
# review?") reads runs/<id>/meta.json.started_at, not a separate
# state.json. An OLD /srosro-review comment posted BEFORE runs/'s
# started_at must not requalify and force a whole-PR re-review. This
# scenario also fences the round-11 write-side fix: meta.json.started_at
# is stamped from REVIEW_START_TS (the captured variable), so the
# orchestrator's cutoff and the worker's "since when" are pinned to a
# single instant — no sub-second clock-skew window where a /review
# trigger could fall.
#
# Setup: runs/ started_at = 30 minutes ago. /srosro-review comment
# posted 1 hour ago — BEFORE the stamp. Cutoff filters it out → 0
# dispatches. A regression that keys the cutoff off any time later
# than started_at (e.g. posted_at, or a fresh `date` call) would
# silently re-qualify the OLD comment and dispatch.
echo "  scenario 17: OLD /srosro-review predates runs/.started_at → no dispatch (slash-cutoff fence)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
clear_seeded_runs
# runs/: started_at = 30 minutes ago (ISO 8601). GNU date — the only
# format spec this codebase targets.
# `date -u -d @<epoch>` is GNU-only (BSD has -r instead). Use python3
# for portable epoch→ISO conversion — same pattern as
# lib/tests/divergent-clock-smoke.sh:67.
epoch_to_iso() {
    python3 -c "import datetime; print(datetime.datetime.fromtimestamp(int('$1'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}
RECENT_STARTED_AT=$(epoch_to_iso "$(($(date +%s) - 1800))")
seed_run "cncorp_plow" "1" "20260429T143000000Z" "abc123" "COMMENT" "$RECENT_STARTED_AT" >/dev/null
# Comment posted 1 hour ago — BEFORE runs/'s started_at (30m ago).
OLD_COMMENT_AT=$(epoch_to_iso "$(($(date +%s) - 3600))")
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$OLD_COMMENT_AT" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 17 (slash-cutoff regression): expected 0 dispatches when comment predates runs/.started_at, got $n — review.sh's cutoff is keying off something later than meta.json.started_at"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 18: structural fences — review.sh wires
# latest_author_visible_review_started_at, and NO production code path
# (review.sh, lib/review-one-pr.sh) calls state_get/state_set or
# touches state.json. State.json was retired entirely in PR #38; this
# guard fails loud if a regression re-introduces any state.json read or
# write at a runtime-decision seam.
echo "  scenario 18: review.sh wires latest_author_visible_review_started_at + no state.json residue in production (static gate)..."
if ! grep -q 'latest_author_visible_review_started_at' "$PROJECT_ROOT/review.sh"; then
    echo "FAIL scenario 18: review.sh no longer references latest_author_visible_review_started_at — slash-cutoff has been re-routed off runs/, reopens 4th-leak race"
    exit 1
fi
# state_get / state_set are deleted; any production CALL site re-introducing
# them reopens the BCR class that drove rounds 7-12. The grep skips lines
# that start with `#` so historical comments referencing the retired
# helpers don't false-positive — only actual call sites trip the fence.
for f in "$PROJECT_ROOT/review.sh" "$PROJECT_ROOT/lib/review-one-pr.sh"; do
    if grep -vE '^[[:space:]]*#' "$f" | grep -qE '\bstate_(get|set)\b'; then
        echo "FAIL scenario 18 (state.json retirement regression): $f re-introduced state_get / state_set — runtime decisions are back on the legacy state.json cache that PR #38 retired"
        grep -nE '\bstate_(get|set)\b' "$f" | grep -vE ':[[:space:]]*#'
        exit 1
    fi
done

# Scenario 19: review.sh passes DISPATCHER_TICK_AT env var to the worker.
# The worker stamps meta.json.started_at from this value so the next
# tick's "created_at > started_at" cutoff doesn't slip past a comment
# posted in the gap between dispatcher and worker init. ISO-shape match
# is sufficient — the value is `date -u +...` at the top of the per-PR
# loop, so its actual contents are runtime-dependent.
echo "  scenario 19: review.sh passes DISPATCHER_TICK_AT env var to the worker..."
clear_seeded_runs
MOCK_TRUSTED_USERS="srosro,someuser" \
    seed_run "cncorp_plow" "1" "20260429T143000000Z" "abc123" "COMMENT" >/dev/null
printf '[{"created_at":"2026-04-30T16:00:00Z","user":{"login":"someuser"},"body":"/srosro-review"}]\n' > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 19 (setup): expected 1 dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -qE 'dispatcher_tick=20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z' "$LOG_FILE"; then
    echo "FAIL scenario 19 (slash-cutoff regression): expected dispatcher_tick=<ISO8601> in WORKER_DISPATCHED, got:"
    grep 'WORKER_DISPATCHED' "$LOG_FILE" || true
    echo "review.sh must pass DISPATCHER_TICK_AT (captured per-PR before fetch + dispatch) to the worker so meta.json.started_at is stamped from the dispatcher's tick-fetch time, not the worker's process-entry time."
    exit 1
fi

# Scenario 20: idle-skip gate — an already-reviewed PR whose head we've
# reviewed AND whose updatedAt is unchanged since we last evaluated it must
# NOT trigger a comment-fetch. This is the fix for the per-tick comment-fetch
# storm that tripped GitHub's secondary rate limit: a watermark equal to the
# enumerated updatedAt + a matching head means nothing changed, so the gate
# skips before the core gh call.
echo "  scenario 20: reviewed head + unchanged updatedAt → comment-fetch skipped (idle-skip gate)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
# Seed the watermark in the SHARED STATE_DIR while pointing LOCAL_STATE_DIR at
# a distinct empty dir — so a regression that reads the cache from the
# per-container LOCAL_STATE_DIR would miss the watermark, fail to skip, and
# trip the fetch assertion below. Fences the shared-seam contract.
mkdir -p "$STATE_DIR/seen-updated"
printf '%s' "2026-05-20T00:00:00Z" > "$STATE_DIR/seen-updated/cncorp_plow__1"
export LOCAL_STATE_DIR="$TMPDIR/local-distinct-20"; mkdir -p "$LOCAL_STATE_DIR"
echo "[]" > "$MOCK_COMMENTS_FILE"
export MOCK_PR_UPDATED_AT="2026-05-20T00:00:00Z"   # equals the watermark
run_orchestrator
unset MOCK_PR_UPDATED_AT LOCAL_STATE_DIR
fetches=$(count_comment_fetches)
if [ "$fetches" -ne 0 ]; then
    echo "FAIL scenario 20 (idle-skip gate): expected 0 comment-fetches when head reviewed + updatedAt unchanged, got $fetches"
    echo "--- comment-fetch log ---"; cat "$COMMENT_FETCH_LOG"
    exit 1
fi
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 20: expected 0 dispatches on idle-skip, got $n"; cat "$LOG_FILE"; exit 1
fi

# Scenario 21: gate must NOT over-skip — when updatedAt has moved (a new
# comment or commit bumps it), the comment-fetch must still happen so a
# /srosro-* trigger isn't silently lost. Stale watermark + newer enumerated
# updatedAt → fetch.
echo "  scenario 21: reviewed head + CHANGED updatedAt → comment-fetch happens (no over-skip)..."
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
printf '%s' "2026-05-20T00:00:00Z" > "$STATE_DIR/seen-updated/cncorp_plow__1"   # stale
echo "[]" > "$MOCK_COMMENTS_FILE"
export MOCK_PR_UPDATED_AT="2026-05-21T00:00:00Z"   # newer than the watermark
run_orchestrator
unset MOCK_PR_UPDATED_AT
fetches=$(count_comment_fetches)
if [ "$fetches" -lt 1 ]; then
    echo "FAIL scenario 21 (gate over-skip regression): expected >=1 comment-fetch when updatedAt changed, got $fetches — a moved updatedAt must defeat the idle-skip so triggers aren't lost"
    echo "--- comment-fetch log ---"; cat "$COMMENT_FETCH_LOG"
    exit 1
fi

# Scenario 22: in-flight guard — a PR whose review is running is NOT enumerated
# (the plow-pbc/plow#1102 double-enumeration race; see refresh_queue's in-flight
# guard for the why). Stand in for the in-flight review by holding the PR's
# per-PR flock in THIS test process across the first run_orchestrator: review.sh
# runs as a child, so its acquire_pr_lock is denied by ordinary cross-process
# flock (no separate holder needed). No seeded run + empty comments = the
# KNOWN_SHA-empty first-review case that skips the cooldown; assert 0 dispatch +
# defer log, then release the lock and assert it dispatches (deferred, not starved).
echo "  scenario 22: PR with a review in flight (held per-PR flock) → not enumerated (defer), 0 dispatch..."
clear_seeded_runs
rm -f "$STATE_DIR/seen-updated/cncorp_plow__1"
. "$REVIEWER_LIB_DIR/locking.sh"
acquire_pr_lock "$STATE_DIR" "cncorp_plow__1" || { echo "FAIL scenario 22: could not hold the in-flight lock"; exit 1; }

echo "[]" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    release_pr_lock
    echo "FAIL scenario 22 (in-flight double-enumeration): expected 0 dispatches for a PR whose review is in flight, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi
if ! grep -q "review in flight — deferring enumeration" "$LOG_FILE"; then
    release_pr_lock
    echo "FAIL scenario 22: expected the in-flight defer log — a different skip fired, so this isn't fencing the in-flight guard"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Release the in-flight lock; the deferred PR must now enumerate + dispatch (not starved).
release_pr_lock
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 1 ]; then
    echo "FAIL scenario 22 (starvation regression): after the in-flight review finished, the deferred PR must enumerate + dispatch, got $n"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

echo "  PASS (27 scenarios: no-comments, bare-mention, /srosro-review, marker-self-filter, single-account, untrusted-trigger-comment, indeterminate-trigger-defer, /srosro-update-review-same-sha, decline-posted-once-per-round, decline-re-arms-after-a-review, failed-decline-watermarked-no-retry-storm, stale-enumerated-head-dispatches, /srosro-approve-not-a-review, slow-worker-fast-exit-and-liveness, lock-contention-on-shared-state-dir, missing-worker-fail-loud, worker-timeout-enforced, page-2-trigger-pagination-fence, post-load-tmpdir-placement-fence, runs/-sourced-skip, runs/-sourced-dispatch, slash-cutoff-from-runs, no-state-json-residue, dispatcher-tick-at-passthrough, idle-skip-unchanged-updatedat, idle-skip-changed-updatedat-fetches, inflight-not-double-enumerated)"
