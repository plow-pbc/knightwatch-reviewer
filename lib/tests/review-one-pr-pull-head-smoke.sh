#!/usr/bin/env bash
# Smoke for lib/review-one-pr.sh — fences the rule that the worker MUST
# NOT post a "👀 reviewing" placeholder before the canonical
# `git fetch +refs/pull/N/head:...` has succeeded.
#
# GitHub doesn't publish refs/pull/N/head atomically with PR creation
# (refs/pull/N/merge appears immediately, but /head can lag for several
# minutes — observed on plow-pbc/watchmepivot#20: 17+ minutes). When
# the worker posts the placeholder before the fetch and the fetch then
# fails, the EXIT trap rewrites the placeholder to "review aborted",
# and the orchestrator re-dispatches every 2-min tick (PRs with no
# successful prior review skip the stability cooldown), producing a
# comment-spam loop. Posting the placeholder ONLY after a successful
# fetch breaks the loop without giving up the immediate-feedback UX
# (the canonical fetch is single-digit seconds in steady state).
#
# Two scenarios — same set of GitHub side-effect assertions, but with
# refs/pull/N/head present vs absent in the upstream bare repo:
#   head_missing — base ref pushed, refs/pull/N/head NOT pushed. The
#                  worker's `git fetch +refs/pull/N/head:...` should
#                  fail, exit 0 cleanly, and post NEITHER a placeholder
#                  NOR an abort PATCH.
#   head_present — base ref AND refs/pull/N/head pushed. The worker
#                  should reach the placeholder post, then abort
#                  downstream (no codex on PATH, etc.) — we only
#                  assert the placeholder POST happened, proving the
#                  fetch-success path didn't regress.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"

TMPDIR_ROOT=$(mktemp -d -t review-one-pr-pull-head-XXXXXX)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass_msg() { echo "PASS: $*"; PASS=$((PASS+1)); }

# write_gh_stub <stub_path> <gh_call_log>
#
# Records every gh invocation so the smoke can assert which API calls
# happened. Stubs `gh pr view ... --json baseRefName,...` with a fixture
# matching the worker's downstream parse contract; everything else
# (`gh api repos/.../issues/N/comments` POST, `gh api .../issues/comments/<id>`
# PATCH, `gh repo clone`, etc.) returns a synthetic success — we don't
# stub the canonical-fetch git commands; the worker runs against a real
# bare-repo upstream so the head-ref-missing condition is the actual
# `git fetch` failure mode this smoke fences.
write_gh_stub() {
    local stub_path="$1" gh_call_log="$2"
    cat > "$stub_path" <<STUB
#!/bin/bash
echo "\$@" >> "$gh_call_log"

# gh pr view N --repo <repo> --json baseRefName,title,body,author,closingIssuesReferences
if [ "\$1" = "pr" ] && [ "\$2" = "view" ]; then
    printf '{"baseRefName":"main","title":"Test PR","body":"","author":{"login":"test-user"},"closingIssuesReferences":{"nodes":[]}}\n'
    exit 0
fi

# gh api repos/.../issues/N/comments --method POST → placeholder POST
# (returns a fake comment id so the worker captures it as
# EYES_COMMENT_ID and continues).
if [ "\$1" = "api" ] && [[ "\$2" == *"/issues/"*"/comments" ]]; then
    printf '12345\n'
    exit 0
fi

# Anything else (gh repo clone, gh pr comment, gh api PATCH, etc.) →
# silent success.
exit 0
STUB
    chmod +x "$stub_path"
}

# setup_bare_upstream <push_pull_head: yes|no> <bare_path>
#
# Builds a real bare repo with `main` + a feature branch + (optionally)
# `refs/pull/99/head`. Returns the head SHA of the feature branch via
# stdout so the caller can pass it to the worker as PR_SHA.
setup_bare_upstream() {
    local push_pull_head="$1" bare_path="$2"
    local working
    working=$(mktemp -d -t bare-working-XXXXXX)

    git init -q --bare -b main "$bare_path"
    git clone -q "$bare_path" "$working"
    (
        cd "$working"
        git config user.email t@t
        git config user.name t
        git config commit.gpgsign false
        echo "base" > README.md
        git add README.md
        git commit -qm "init"
        git push -q origin main
        git checkout -qb feat/test
        echo "feature" > feature.txt
        git add feature.txt
        git commit -qm "feature"
        git push -q origin feat/test
    )
    if [ "$push_pull_head" = "yes" ]; then
        git -C "$working" push -q origin feat/test:refs/pull/99/head
    fi
    git -C "$working" rev-parse HEAD
    rm -rf "$working"
}

run_scenario() {
    local scenario_name="$1" push_pull_head="$2"
    local scenario_dir="$TMPDIR_ROOT/$scenario_name"
    mkdir -p "$scenario_dir/state" "$scenario_dir/state/repos" \
             "$scenario_dir/state/workdirs" "$scenario_dir/state/canonical-locks" \
             "$scenario_dir/state/locks" "$scenario_dir/home/.local/bin" \
             "$scenario_dir/home/.pr-reviewer/prompts"

    local gh_call_log="$scenario_dir/gh-calls.log"
    : > "$gh_call_log"

    write_gh_stub "$scenario_dir/home/.local/bin/gh" "$gh_call_log"
    write_worker_flock_stub_if_missing "$scenario_dir/home/.local/bin"

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

    write_probe_repos_conf "$STATE_DIR/repos.conf"

    # Real bare upstream + canonical clone. The bare repo may or may
    # not have refs/pull/99/head pushed — that's the variable under
    # test, since the worker's canonical fetch is what's now gating
    # the placeholder post.
    local bare="$scenario_dir/bare.git"
    local pr_sha
    pr_sha=$(setup_bare_upstream "$push_pull_head" "$bare")
    git clone -q "$bare" "$REPOS_DIR/test-org_probe-repo"

    local worker_log="$scenario_dir/worker.log"
    set +e
    TRIGGER_COMMENT_FILE="" timeout 30 bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        "test-org/probe-repo" 99 "$pr_sha" \
        "feat/test" "Test PR" "false" \
        > "$worker_log" 2>&1
    local worker_exit=$?
    set -e

    case "$push_pull_head" in
        no)
            # Worker should exit 0 cleanly — head fetch fails, no
            # placeholder, no trap rewrite.
            if [ "$worker_exit" -ne 0 ]; then
                fail_msg "[$scenario_name] worker exited $worker_exit, expected 0"
                echo "--- worker.log ---" >&2
                cat "$worker_log" >&2 || true
            else
                pass_msg "[$scenario_name] worker exited 0"
            fi
            # The placeholder POST hits `gh api repos/.../issues/N/comments`.
            if grep -qE 'api repos/[^ ]+/issues/[0-9]+/comments' "$gh_call_log"; then
                fail_msg "[$scenario_name] placeholder POST was called (expected no-op — placeholder must wait for head fetch)"
                echo "--- gh-calls.log ---" >&2
                cat "$gh_call_log" >&2 || true
            else
                pass_msg "[$scenario_name] no placeholder POST"
            fi
            # The abort patch hits `gh api repos/.../issues/comments/<id>`.
            if grep -qE 'api repos/[^ ]+/issues/comments/' "$gh_call_log"; then
                fail_msg "[$scenario_name] abort PATCH was called (expected no-op)"
            else
                pass_msg "[$scenario_name] no abort PATCH"
            fi
            local run_log
            run_log=$(find "$STATE_DIR/runs" -name run.log 2>/dev/null | head -1)
            if [ -n "$run_log" ] && grep -q "refs/pull/99/head fetch failed" "$run_log"; then
                pass_msg "[$scenario_name] run.log records 'refs/pull/99/head fetch failed' with git stderr"
            else
                fail_msg "[$scenario_name] run.log missing fetch-failure log line (looked at: ${run_log:-<none>})"
                [ -n "$run_log" ] && { echo "--- run.log ---" >&2; cat "$run_log" >&2 || true; }
            fi
            ;;
        yes)
            # Worker may abort downstream (no codex, etc.) — we only
            # assert the placeholder POST happened, proving the
            # fetch-success path didn't regress.
            if grep -qE 'api repos/[^ ]+/issues/[0-9]+/comments' "$gh_call_log"; then
                pass_msg "[$scenario_name] placeholder POST was called (fetch-success path posts placeholder)"
            else
                fail_msg "[$scenario_name] placeholder POST was NOT called (fetch-success path regressed)"
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
