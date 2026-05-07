#!/usr/bin/env bash
# Smoke for lib/review-one-pr.sh — fences the refs/pull/N/head precheck
# that runs BEFORE the "👀 reviewing" placeholder post.
#
# GitHub doesn't publish refs/pull/N/head atomically with PR creation
# (refs/pull/N/merge appears immediately, but /head can lag for several
# minutes — observed on plow-pbc/watchmepivot#20: 17+ minutes). Without
# the precheck, the worker would post a placeholder, fail the canonical
# `git fetch refs/pull/N/head:...` later, and the EXIT trap would
# rewrite the placeholder to "review aborted". The orchestrator would
# then re-dispatch every 2-minute tick (PRs with no successful prior
# review skip the stability cooldown), producing a comment-spam loop.
#
# Two scenarios:
#   head_missing — gh api .../refs/pull/N/head returns 404. Assert
#                  worker exits without posting any placeholder or
#                  abort comment, and run.log records the precheck
#                  wording (regression-fences the message so a future
#                  edit doesn't drift it back to "(PR closed?)").
#   head_present — gh api returns the head SHA. Assert worker proceeds
#                  far enough to post the placeholder (regression-fences
#                  the precheck blocking healthy PRs).
#
# Stubs `gh` (and `flock` if missing) via PATH so neither the network
# nor real PR infra is touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR_ROOT=$(mktemp -d -t review-one-pr-pull-head-XXXXXX)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass_msg() { echo "PASS: $*"; PASS=$((PASS+1)); }

# write_gh_stub <stub_path> <head_ref_present: yes|no> <gh_call_log>
write_gh_stub() {
    local stub_path="$1" head_ref_present="$2" gh_call_log="$3"
    cat > "$stub_path" <<STUB
#!/bin/bash
# Record every invocation (one line per call) so the smoke can assert
# which API calls did or didn't happen.
echo "\$@" >> "$gh_call_log"

# gh pr view N --repo <repo> --json baseRefName,title,body,author,closingIssuesReferences
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    printf '{"baseRefName":"main","title":"Test PR","body":"","author":{"login":"test-user"},"closingIssuesReferences":{"nodes":[]}}\n'
    exit 0
fi

# gh api repos/<owner>/<repo>/git/refs/pull/<num>/head — the precheck
# under test. 404 simulates "head ref not yet propagated"; SHA-bearing
# JSON simulates the healthy case.
if [ "\$1" = "api" ] && [[ "\$2" == *"/git/refs/pull/"*"/head" ]]; then
    if [ "$head_ref_present" = "yes" ]; then
        printf '{"object":{"sha":"deadbeefcafebabe1234567890abcdef12345678"}}\n'
        exit 0
    else
        printf '{"message":"Not Found","status":"404"}\n' >&2
        exit 1
    fi
fi

# gh api repos/.../issues/N/comments --method POST — the placeholder
# post. Return a fake comment id so the worker captures it as
# EYES_COMMENT_ID and continues into the canonical clone path.
if [ "\$1" = "api" ] && [[ "\$2" == *"/issues/"*"/comments" ]]; then
    printf '12345\n'
    exit 0
fi

# Anything else (gh repo clone, gh pr comment, etc.) — silent success.
exit 0
STUB
    chmod +x "$stub_path"
}

# Production uses util-linux flock(1). On macOS dev hosts brew's flock
# is excluded; mirror PR #49's orchestrator-skip-smoke.sh shim using
# python3 fcntl so the per-PR lock acquisition exercises the same OFD
# semantics on both platforms.
write_flock_stub_if_missing() {
    local bindir="$1"
    if command -v flock >/dev/null 2>&1; then
        return 0
    fi
    cat > "$bindir/flock" <<'STUB'
#!/usr/bin/env bash
nonblock=0
case "$1" in
    -n) nonblock=1; shift ;;
esac
fd="$1"
exec python3 - "$fd" "$nonblock" <<'PY'
import fcntl, sys
fd = int(sys.argv[1])
nonblock = sys.argv[2] == "1"
flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblock else 0)
try:
    fcntl.flock(fd, flags)
except BlockingIOError:
    sys.exit(1)
PY
STUB
    chmod +x "$bindir/flock"
}

run_scenario() {
    local scenario_name="$1" head_ref_present="$2"
    local scenario_dir="$TMPDIR_ROOT/$scenario_name"
    mkdir -p "$scenario_dir/state" "$scenario_dir/state/repos" \
             "$scenario_dir/state/workdirs" "$scenario_dir/state/canonical-locks" \
             "$scenario_dir/state/locks" "$scenario_dir/home/.local/bin" \
             "$scenario_dir/home/.pr-reviewer/prompts"

    local gh_call_log="$scenario_dir/gh-calls.log"
    : > "$gh_call_log"

    write_gh_stub "$scenario_dir/home/.local/bin/gh" "$head_ref_present" "$gh_call_log"
    write_flock_stub_if_missing "$scenario_dir/home/.local/bin"

    # Sandbox env. Mirrors lib/tests/review-one-pr-sha-flow-smoke.sh.
    export STATE_DIR="$scenario_dir/state"
    export REPOS_DIR="$STATE_DIR/repos"
    export WORKDIRS_DIR="$STATE_DIR/workdirs"
    export CANONICAL_LOCKS_DIR="$STATE_DIR/canonical-locks"
    export PR_REVIEW_LOCK_DIR="$STATE_DIR/locks"
    export HOME="$scenario_dir/home"
    export PATH="$HOME/.local/bin:$PATH"
    export BOT_USER="srosro"
    export REVIEWER_LIB_DIR="$PROJECT_ROOT/lib"

    # repos.conf — tracked-repos.sh fail-fast loud if missing.
    cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("test-org/probe-repo")
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
CONF

    # Run the worker. Timeout guards against logic bugs that would
    # otherwise hang the smoke.
    local worker_log="$scenario_dir/worker.log"
    set +e
    TRIGGER_COMMENT_FILE="" timeout 30 bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        "test-org/probe-repo" 99 "deadbeefcafebabe1234567890abcdef12345678" \
        "feat/test" "Test PR" "false" \
        > "$worker_log" 2>&1
    local worker_exit=$?
    set -e

    case "$head_ref_present" in
        no)
            if [ "$worker_exit" -ne 0 ]; then
                fail_msg "[$scenario_name] worker exited $worker_exit, expected 0"
                echo "--- worker.log ---" >&2
                cat "$worker_log" >&2 || true
            else
                pass_msg "[$scenario_name] worker exited 0"
            fi
            # The placeholder is posted via `gh api repos/.../issues/N/comments
            # --method POST` — match on the path fragment.
            if grep -qE 'api repos/[^ ]+/issues/[0-9]+/comments' "$gh_call_log"; then
                fail_msg "[$scenario_name] placeholder POST was called (expected no-op)"
                echo "--- gh-calls.log ---" >&2
                cat "$gh_call_log" >&2 || true
            else
                pass_msg "[$scenario_name] no placeholder POST"
            fi
            # The abort patch hits `gh api repos/.../issues/comments/<id>
            # --method PATCH` — different URL shape from the POST above.
            if grep -qE 'api repos/[^ ]+/issues/comments/' "$gh_call_log"; then
                fail_msg "[$scenario_name] abort PATCH was called (expected no-op)"
            else
                pass_msg "[$scenario_name] no abort PATCH"
            fi
            local run_log
            run_log=$(find "$STATE_DIR/runs" -name run.log 2>/dev/null | head -1)
            if [ -n "$run_log" ] && grep -q "not yet published by GitHub" "$run_log"; then
                pass_msg "[$scenario_name] run.log records 'not yet published by GitHub'"
            else
                fail_msg "[$scenario_name] run.log missing precheck wording (looked at: ${run_log:-<none>})"
                [ -n "$run_log" ] && { echo "--- run.log ---" >&2; cat "$run_log" >&2 || true; }
            fi
            ;;
        yes)
            # Worker may abort downstream (no canonical clone, no codex,
            # etc.) — we only assert the placeholder POST happened,
            # proving the precheck didn't block a healthy PR.
            if grep -qE 'api repos/[^ ]+/issues/[0-9]+/comments' "$gh_call_log"; then
                pass_msg "[$scenario_name] placeholder POST was called (precheck did not block)"
            else
                fail_msg "[$scenario_name] placeholder POST was NOT called (precheck wrongly blocked)"
                echo "--- worker.log ---" >&2
                cat "$worker_log" >&2 || true
                echo "--- gh-calls.log ---" >&2
                cat "$gh_call_log" >&2 || true
            fi
            ;;
    esac
}

run_scenario "head_missing" "no"
run_scenario "head_present" "yes"

echo ""
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
