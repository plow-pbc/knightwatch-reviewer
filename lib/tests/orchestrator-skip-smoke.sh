#!/bin/bash
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
        echo '[{"number":1,"title":"Test PR","headRefName":"feat/test","headRefOid":"abc123"}]'
    else
        echo '[]'
    fi
elif [ "$1" = "api" ]; then
    # The endpoint URL can land at any positional arg — `gh api URL` and
    # `gh api --paginate URL` both reach the orchestrator. Walk all args
    # and match by URL shape rather than position, so adding flags
    # (--paginate, --jq, --method) doesn't require stub edits.
    url=""
    for arg in "$@"; do
        case "$arg" in
            repos/*) url="$arg"; break ;;
        esac
    done
    if [[ "$url" == */issues/*/comments* ]]; then
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

# Sandbox lib dir: real state-io.sh + auth.sh, stub worker that logs the
# dispatch (including the trigger-comment file path so trust-gate
# scenarios can assert presence/absence) instead of running a review.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/state-io.sh"      "$REVIEWER_LIB_DIR/state-io.sh"
cp "$PROJECT_ROOT/lib/auth.sh"          "$REVIEWER_LIB_DIR/auth.sh"
cp "$PROJECT_ROOT/lib/locking.sh"       "$REVIEWER_LIB_DIR/locking.sh"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"
cp "$PROJECT_ROOT/lib/gh-comments.sh"   "$REVIEWER_LIB_DIR/gh-comments.sh"
cp "$PROJECT_ROOT/lib/run-dir.sh"       "$REVIEWER_LIB_DIR/run-dir.sh"
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
# state.json stays around as a cache for legacy callers (reviewed_at is
# still read here for the comment-since window).
. "$REVIEWER_LIB_DIR/state-io.sh"
state_set "cncorp/plow#1" "abc123" false "prior review body" "$(($(date +%s) - 3600))"

# Seed runs/ with an author-visible run for this PR. The orchestrator's
# dispatch gate now reads KNOWN_SHA from runs/ (via
# latest_author_visible_review_sha), not state.json — closing the
# infinite-dispatch loop where a `gh pr comment` success + state_set
# failure used to leave state.json stale and re-dispatch forever. Most
# scenarios want "we already reviewed abc123" → seed a posted run with
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

# --- Systemd contract static check (fails the suite at setup) -------------
# Detached-worker correctness depends on KillMode=process in the service
# unit — it's the directive that lets workers survive when the
# orchestrator (oneshot ExecStart) exits. We can't execute systemd
# inside a bash smoke, but we CAN assert the directive is in the unit
# file. A regression that drops it would silently break detached-worker
# survival in production; this catches it at the suite gate before any
# scenario runs.
grep -q '^KillMode=process$' "$PROJECT_ROOT/systemd/pr-reviewer.service" || {
    echo "FAIL setup: systemd/pr-reviewer.service is missing 'KillMode=process' — detached workers won't survive orchestrator exit in production"
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
loader_cfg_line=$(grep -nF '. "${STATE_DIR}/config.env"' "$LOADER" | head -1 | cut -d: -f1)
if [ -z "$loader_cfg_line" ] || [ -z "$loader_pin_line" ] || [ "$loader_pin_line" -le "$loader_cfg_line" ]; then
    echo "FAIL setup: lib/tracked-repos.sh — TMPDIR pin must come AFTER the config.env source (got pin@${loader_pin_line:-MISSING}, config.env@${loader_cfg_line:-MISSING})"
    exit 1
fi

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
printf '[{"created_at":"%s","user":{"login":"srosro"},"body":"<!-- knightwatch-reviewer:auto-post -->\\n/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
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
printf '[{"created_at":"%s","user":{"login":"srosro"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
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
    echo "FAIL scenario 5: expected trigger_file=\$STATE_DIR/tmp/pr-review-trigger.* in dispatch (srosro is in MOCK_TRUSTED_USERS) — anchors the bugfix path"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 6 (trigger-comment trust gate): same SHA, /srosro-review from a
# commenter without push access → the trigger still dispatches a worker
# (so re-request-poller and external requesters keep working), but the
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

# Scenario 8: same SHA, /srosro-approve → no dispatch. Approve requests
# are handled out-of-band by approve-from-replies.sh, not by the review
# orchestrator. The orchestrator's substring filter looks for
# /srosro-review and /srosro-update-review; /srosro-approve must not
# match either. Guards against a future filter change that accidentally
# triggers a re-review on every approve request.
echo "  scenario 8: same SHA + /srosro-approve (handled by approve-from-replies, not orchestrator)..."
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
bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
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
#!/bin/bash
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
[ -f "$HOLDER_MARKER" ] || { kill "$HOLDER_PID" 2>/dev/null; echo "FAIL scenario 10: holder never acquired the lock"; cat "$TMPDIR/holder.log"; exit 1; }

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
if bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1; then
    chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"
    echo "FAIL scenario 11 (silent-dispatch-failure regression): review.sh exited 0 with a non-executable worker"
    cat "$LOG_FILE"; exit 1
fi
grep -q "FATAL: $REVIEWER_LIB_DIR/review-one-pr.sh missing or not executable" "$LOG_FILE" || { chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"; echo "FAIL scenario 11: expected FATAL log line about missing worker"; cat "$LOG_FILE"; exit 1; }
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"   # restore for any later scenario

# Scenario 12: per-worker WORKER_TIMEOUT bounds wedged-codex risk.
# With detached workers, the service-level TimeoutStartSec=90min no
# longer caps worker runtime — a hung Codex phase could hold the per-PR
# flock indefinitely. WORKER_TIMEOUT (default 90m) wraps each worker
# spawn with `timeout` so the ceiling is preserved at the worker level.
# Smoke uses WORKER_TIMEOUT=2s + a worker that sleeps 10s, asserts the
# orchestrator killed it (worker PID dead within ~3s of dispatch).
echo "  scenario 12: WORKER_TIMEOUT — wedged worker is killed at the per-worker ceiling..."
WORKER_TIMEOUT_PID_FILE="$TMPDIR/timeout-worker.pid"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<TWORKER
#!/bin/bash
echo \$\$ > "$WORKER_TIMEOUT_PID_FILE"
exec sleep 10   # > WORKER_TIMEOUT=2s; the orchestrator's timeout(1) wrapper must SIGTERM us before this completes
TWORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
: > "$LOG_FILE"
WORKER_TIMEOUT=2s bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
ORCH12_PID=$!
wait "$ORCH12_PID" 2>/dev/null || true   # orchestrator returns fast; the timeout(1) child is what we care about

# Wait up to 5s for the worker to die under timeout(1).
for _ in $(seq 1 50); do
    [ -f "$WORKER_TIMEOUT_PID_FILE" ] || { sleep 0.1; continue; }
    WORKER_TPID=$(cat "$WORKER_TIMEOUT_PID_FILE")
    kill -0 "$WORKER_TPID" 2>/dev/null || break   # dead = timeout fired
    sleep 0.1
done
WORKER_TPID=$(cat "$WORKER_TIMEOUT_PID_FILE" 2>/dev/null || echo "")
if [ -n "$WORKER_TPID" ] && kill -0 "$WORKER_TPID" 2>/dev/null; then
    kill "$WORKER_TPID" 2>/dev/null || true
    echo "FAIL scenario 12 (no-worker-timeout regression): worker PID $WORKER_TPID still alive ~5s after WORKER_TIMEOUT=2s should have killed it"
    exit 1
fi

# Confirm the orchestrator's "Fan-out:" line includes the timeout
# value, so an operator tail-ing the journal can see what cap is in
# force this tick.
grep -q "per-worker timeout 2s" "$LOG_FILE" || { echo "FAIL scenario 12: expected 'per-worker timeout 2s' in fan-out log line"; cat "$LOG_FILE"; exit 1; }

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
echo "WORKER_DISPATCHED repo=$1 pr=$2 sha=$3 force_whole=$6 trigger_file=${TRIGGER_COMMENT_FILE:-}" >> "$LOG_FILE"
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

# Pre-stamp with a SHA that differs from the gh stub's headRefOid
# (abc123). reviewed_at far in the past so MOCK_COMMENTS_PAGE*_FILE
# timestamps written as "now" satisfy `created_at > reviewed_at`.
# Also re-seed runs/ to report old_sha_999 so the runs/-sourced gate
# matches state.json's view of "we last reviewed old_sha_999."
state_set "cncorp/plow#1" "old_sha_999" false "prior review body" "$(($(date +%s) - 7200))"
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
state_set "cncorp/plow#1" "abc123" false "prior review body" "$(($(date +%s) - 3600))"
clear_seeded_runs
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
rm -f "$STATE_DIR/tmp/pr-review-trigger".*
echo 'export TMPDIR="/tmp/should-not-be-honored-via-config-env"' > "$STATE_DIR/config.env"
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"
: > "$LOG_FILE"
TMPDIR="/tmp/should-not-be-honored-via-inheritance" \
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
# read sources from runs/ (meta.json), not state.json. The round-8 fix
# moved the WORKER's KNOWN_SHA to runs/. If the orchestrator is left
# reading state.json and a `gh pr comment` succeeds but state_set fails
# afterward, state.json keeps the OLDER SHA — and on the next tick the
# orchestrator dispatches again because state.json says "we last
# reviewed OLDER_SHA != HEAD". The worker then reads runs/ for ITS
# KNOWN_SHA, gets HEAD (correctly), computes git diff HEAD..HEAD, and
# aborts on empty diff. state.json stays unchanged. The cycle repeats
# every tick forever until a new commit lands or someone manually
# repairs state.json.
#
# Fence: state.json says OLDER_SHA, runs/ says HEAD (abc123 — the gh
# stub's headRefOid). No /srosro-* trigger comments. Expect 0 dispatches.
# Pre-fix this would have dispatched.
echo "  scenario 15: state.json stale (OLDER_SHA), runs/ shows HEAD reviewed → no dispatch (infinite-loop fence)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
state_set "cncorp/plow#1" "older_sha_stale" false "prior review body" "$(($(date +%s) - 3600))"
clear_seeded_runs
# runs/ correctly reports the actually-reviewed SHA (HEAD = abc123).
seed_run "cncorp_plow" "1" "20260429T100000000Z" "abc123" "COMMENT" >/dev/null
echo "[]" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 15 (infinite-dispatch-loop regression): expected 0 dispatches when runs/ shows HEAD already reviewed, got $n — orchestrator likely still consults state.json for KNOWN_SHA"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 16 (changed-SHA dispatch from runs/): runs/ reports OLDER_SHA,
# HEAD is abc123 — orchestrator must dispatch even when state.json is
# empty/missing, because runs/ is now the authoritative source. No
# /srosro-* trigger comments needed; the SHA delta alone drives dispatch.
# Cooldown is bypassed because the gh stub returns a 2020-era commit
# date for /pulls/<n>/commits.
echo "  scenario 16: state.json empty, runs/ shows OLDER_SHA (HEAD differs) → 1 dispatch..."
echo "{}" > "$STATE_FILE"
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

# Scenario 17 (slash-cutoff sourced from runs/): the round-10 fence for
# the 4th leak of the gh-success + state_set-failure race. Round 9 closed
# the orchestrator's KNOWN_SHA dispatch loop by reading runs/. But the
# slash-command cutoff ("is this /srosro-review newer than the last
# review?") still read state.json.reviewed_at — so the same race leaked:
# state.json carries an ANCIENT reviewed_at while runs/ has a recent
# started_at. An OLD /srosro-review comment (posted before runs/'s
# started_at, after state.json's stale reviewed_at) used to requalify on
# the cutoff and force a whole-PR re-review unnecessarily. Sourcing the
# cutoff from runs/.started_at closes it.
#
# Setup: state.json reviewed_at = 2 hours ago. runs/ started_at = 30
# minutes ago. /srosro-review comment posted 1 hour ago — between the
# two. Pre-fix: comment.created_at > state.json.reviewed_at → trigger
# fires → 1 dispatch (whole-PR). Post-fix: comment.created_at <
# runs/started_at → cutoff filters it out → 0 dispatches.
echo "  scenario 17: stale state.json reviewed_at + fresh runs/ started_at, OLD /srosro-review → no dispatch (4th-leak fence)..."
unset MOCK_COMMENTS_PAGE1_FILE MOCK_COMMENTS_PAGE2_FILE
export MOCK_COMMENTS_FILE="$TMPDIR/comments.json"
echo "{}" > "$STATE_FILE"
# state.json: ancient reviewed_at (2 hours ago).
state_set "cncorp/plow#1" "abc123" false "prior review body" "$(($(date +%s) - 7200))"
clear_seeded_runs
# runs/: started_at = 30 minutes ago (ISO 8601). Use a Linux date(1)
# format spec that's portable to GNU date (the only one this codebase
# targets).
RECENT_STARTED_AT=$(date -u -d "@$(($(date +%s) - 1800))" +"%Y-%m-%dT%H:%M:%SZ")
seed_run "cncorp_plow" "1" "20260429T143000000Z" "abc123" "COMMENT" "$RECENT_STARTED_AT" >/dev/null
# Comment posted 1 hour ago — AFTER state.json's stale reviewed_at
# (2h ago) but BEFORE runs/'s started_at (30m ago). Pre-fix this trips
# the cutoff (state.json view); post-fix it does not (runs/ view).
OLD_COMMENT_AT=$(date -u -d "@$(($(date +%s) - 3600))" +"%Y-%m-%dT%H:%M:%SZ")
printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$OLD_COMMENT_AT" > "$MOCK_COMMENTS_FILE"
run_orchestrator
n=$(count_dispatches)
if [ "$n" -ne 0 ]; then
    echo "FAIL scenario 17 (slash-cutoff-from-state.json regression): expected 0 dispatches when comment predates runs/.started_at, got $n — review.sh's cutoff is still reading state.json.reviewed_at instead of runs/.started_at"
    echo "--- log ---"; cat "$LOG_FILE"
    exit 1
fi

# Scenario 18: structural fence — review.sh must call
# latest_author_visible_review_started_at and must NOT re-introduce the
# state.json reviewed_at read at the cutoff seam. The behavioral fence
# above (scenario 17) is the primary check; this is a static guard so a
# regression that breaks the wiring shows up here even if someone
# accidentally weakens scenario 17's setup later.
echo "  scenario 18: review.sh wires latest_author_visible_review_started_at (static gate)..."
if ! grep -q 'latest_author_visible_review_started_at' "$PROJECT_ROOT/review.sh"; then
    echo "FAIL scenario 18: review.sh no longer references latest_author_visible_review_started_at — slash-cutoff has been re-routed off runs/, reopens 4th-leak race"
    exit 1
fi
if grep -qE 'state_get[[:space:]]+"\$PR_ID"[[:space:]]+"reviewed_at"' "$PROJECT_ROOT/review.sh"; then
    echo "FAIL scenario 18: review.sh re-introduced a state.json reviewed_at read — slash-cutoff regressed back to state.json source"
    exit 1
fi

echo "  PASS (18 scenarios: no-comments, bare-mention, /srosro-review, marker-self-filter, single-account, untrusted-trigger-comment, /srosro-update-review-same-sha, /srosro-approve-not-a-review, slow-worker-fast-exit-and-liveness, lock-contention-on-shared-state-dir, missing-worker-fail-loud, worker-timeout-enforced, page-2-trigger-pagination-fence, post-load-tmpdir-placement-fence, runs/-sourced-skip-when-state-stale, runs/-sourced-dispatch-when-head-differs, slash-cutoff-from-runs-when-state-stale, static-wiring-gate)"
