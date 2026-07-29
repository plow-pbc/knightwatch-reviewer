#!/usr/bin/env bash
# Sourceable helper for allocating a per-run dir. Lives outside
# review-one-pr.sh so the regression smoke can exercise the same
# function the worker calls (instead of testing a copy).
#
# Caller must already have LOG_FILE + PR_ID set up so log() works.

# Single source of truth for the ai-author HTML marker. Both
# review-one-pr.sh (which posts the body) and prepend_review_header
# (which allowlists the marker as a leading line) consume this var.
# Pre-PMF stance: the marker tells reading bots to weight load-bearing
# probes and prefer LOC-cuts over additions. Override via env var if a
# downstream consumer needs a different posture.
BOT_AI_AUTHOR_MARKER="${BOT_AI_AUTHOR_MARKER:-<!-- knightwatch-reviewer:ai-author note=load-bearing-probes operating-point=pre-pmf prefer=cut-loc-over-add -->}"

# allocate_run_dir RUN_DIR
#
# Creates RUN_DIR (and agents/, inputs/) as a unit, or fails loud:
#   - collision (RUN_DIR already exists): logs "collision", returns 1.
#     This converts the silent-overwrite hazard from same-second
#     RUN_ID retries into a loud worker abort. Strict no-overwrite
#     invariant — held regardless of timestamp granularity, holds
#     against any future change that could produce duplicate IDs.
#   - parent-create failure (typically EACCES / ENOSPC under
#     $STATE_DIR/runs): logs the path + returns 1.
#   - mkdir failure on RUN_DIR for any non-EEXIST reason: logs +
#     returns 1.
#   - success: returns 0 with RUN_DIR/{agents,inputs} created.
allocate_run_dir() {
    local run_dir="$1"
    if [ -e "$run_dir" ]; then
        log "$PR_ID: RUN_DIR collision: $run_dir already exists — aborting"
        return 1
    fi
    if ! mkdir -p "$(dirname "$run_dir")"; then
        log "$PR_ID: failed to create runs parent dir $(dirname "$run_dir") — aborting"
        return 1
    fi
    if ! mkdir "$run_dir"; then
        log "$PR_ID: failed to create $run_dir (not a collision: dir didn't exist before mkdir) — aborting"
        return 1
    fi
    if ! mkdir "$run_dir/agents" "$run_dir/inputs"; then
        # Roll back the half-created tree so post-mortem tooling doesn't
        # see a phantom run dir without the per-agent + inputs scaffolding
        # the rest of the worker assumes — keeps the "as a unit" contract.
        log "$PR_ID: failed to create $run_dir/{agents,inputs} subdirs — rolling back $run_dir, aborting"
        discard_empty_run_dir "$run_dir"
        return 1
    fi
}

# discard_empty_run_dir RUN_DIR
#   Inverse of allocate_run_dir. Undoes an allocation for a review that then
#   skipped cleanly — the worker allocated, logged one "Reviewing …" line, and
#   is exiting 0 without having produced anything. Without this, every such
#   tick abandons a runs/<id>/ forever (issue #189's residual half: #194 moved
#   the untrusted-author gate above allocation, but the post-fetch clean skips
#   can't move — they need the canonical fetch first).
#
#   Returns 0 when the dir is gone, 1 when anything was left behind. A 1 is the
#   SAFE outcome, not an error to escalate: it means the dir held real content,
#   so it survives and the (bounded) leak stays visible on disk.
#
#   Deliberately NOT `rm -rf`, and that is the whole point of the function:
#   `rmdir` REFUSES a non-empty dir, so the worst case is one file named
#   run.log plus empty directories. A wrong "the dir is empty" assumption
#   therefore leaves a review's artifacts intact and the anomaly visible,
#   instead of silently eating the only record of that run. Costs two lines
#   over `rm -rf "$run_dir"` and needs no path check to be safe — the
#   non-recursion IS the safety property. Don't "simplify" this to rm -rf.
#   An empty/garbage path is inert by construction (every rmdir fails, the
#   ls -A never equals "run.log"), so there is no arg guard to maintain.
#
#   Callers must not `log` into RUN_DIR after this returns 0 — the dir is gone.
#   Both worker call sites repoint LOG_FILE to the orchestrator log first.
discard_empty_run_dir() {
    local run_dir="${1:-}"
    rmdir "$run_dir/agents" "$run_dir/inputs" 2>/dev/null
    rmdir "$run_dir" 2>/dev/null && return 0
    # Still here, so the dir holds content. run.log is the one file THIS
    # function is entitled to remove (the allocation + the worker's first log
    # line are all a clean skip produces) — but only once it is provably the
    # sole remaining entry. Deleting it up front would strip a real review's
    # log while the rmdir correctly spared its artifacts, leaving output.md
    # and meta.json with no record of the run that wrote them.
    [ "$(ls -A "$run_dir" 2>/dev/null)" = "run.log" ] || return 1
    rm -f "$run_dir/run.log"
    rmdir "$run_dir" 2>/dev/null
}

# stage_prior_reviews STATE_DIR REPO_SLUG PR_NUM CURRENT_RUN_DIR
#
# Walks $STATE_DIR/runs/<repo-slug>__<pr>__* dirs in chronological order
# (sortable by RUN_TS) and concatenates each prior aggregator output to
# stdout, separated by `--- review at <ts> ---` headers. The current run
# is excluded explicitly. Run dirs from other PRs are filtered by the
# slug+pr glob. Run dirs without an aggregator output (aborted runs that
# never reached the aggregator phase) are skipped.
#
# Empty stdout when this is the first review on the PR. Caller checks
# `[ -n "$result" ]` and decides whether to write_scratch the result.
#
# Pure read-only walk; no side effects. Lives here so the smoke test in
# lib/tests/prior-reviews-smoke.sh exercises the same function the
# worker calls — a wrong glob, missing self-exclusion, or empty-file
# filter regression silently disables the aggregator's carry-forward
# (step 38) without tripping any other test.
# finalize_meta_json META_FILE FINISHED_AT STATUS GH_POSTED
#
# Atomically rewrites $META_FILE with finished_at + status, and repairs
# posted_at = $FINISHED_AT iff GH_POSTED == "true" AND existing posted_at
# is empty. Existing posted_at values are preserved (the early-stamp path
# in review-one-pr.sh sets posted_at right after gh succeeds; this
# function must not clobber that).
#
# Hermetic — no closures, all inputs are args. Caller handles logging on
# non-zero return so the smoke can drive the function without setting up
# log()/PR_ID/LOG_FILE state.
#
# Returns 0 on success; returns 1 on unusable input — a missing OR malformed
# $META_FILE — and on mv failure (cleaning up the .tmp file). Fail-loud by
# design: "stamp this run's meta" presupposes the run wrote one, so a caller
# that can legitimately have no meta (a pre-checkout abort) must pre-check
# existence itself — review-one-pr.sh's finalize_run does, mirroring how its
# sibling cleanup_eyes self-guards on EYES_COMMENT_ID. Smoke regression-fences
# the branches the worker depends on (see lib/tests/finalize-meta-smoke.sh).
finalize_meta_json() {
    local meta_file="$1" finished_at="$2" status="$3" gh_posted="$4"
    local tmp="${meta_file}.tmp"
    if ! jq --arg ts "$finished_at" --arg status "$status" --arg gh_posted "$gh_posted" \
            '. + {finished_at: $ts, status: $status} + (if ($gh_posted == "true") and ((.posted_at // "") == "") then {posted_at: $ts} else {} end)' \
            "$meta_file" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$meta_file"; then
        rm -f "$tmp"
        return 1
    fi
}

# compute_review_scope FORCE_WHOLE_PR KNOWN_SHA USED_FALLBACK
#
# Pure function. Maps the worker's per-run state (force-flag from the
# trigger comment, prior-reviewed SHA from state, fallback flag set when
# the prior SHA isn't in local history) to one of four scope strings:
#
#   "first"               — no KNOWN_SHA and not forced; first review on this PR
#   "whole"               — FORCE_WHOLE_PR=true (e.g. /srosro-review); takes
#                           precedence over KNOWN_SHA
#   "incremental:<sha>"   — KNOWN_SHA in local history; specialists see git diff
#                           KNOWN_SHA..HEAD, aggregator sees full-diff.patch
#   "fallback:<sha>"      — a clean incremental diff couldn't be taken
#                           (rebase/force-push evicted the prior SHA, OR the
#                           branch merged origin/<default-branch>) and the
#                           worker fell back to the full PR diff; the scope
#                           name calls this out so prepend_review_header +
#                           REVIEW_TASK both disclose it instead of framing
#                           it as incremental
#
# Single source of truth: REVIEW_TASK construction and the post-time
# scope-note injection both read from this so the banner ("📋 fallback
# re-review") and the prompts ("diff.patch is the FULL PR diff") cannot
# drift. Drift is the BCR class fenced by review-scope-smoke.sh.
compute_review_scope() {
    local force_whole_pr="$1" known_sha="$2" used_fallback="$3"
    if [ "$force_whole_pr" = "true" ]; then
        printf 'whole'
    elif [ -z "$known_sha" ]; then
        printf 'first'
    elif [ "$used_fallback" = "true" ]; then
        printf 'fallback:%s' "$known_sha"
    else
        printf 'incremental:%s' "$known_sha"
    fi
}

# format_review_scope SCOPE HEAD_SHA
#
# Maps the scope token (from compute_review_scope) to the human-readable
# fragment that goes into REVIEW_NOTES. Pure function. Returns 1 on
# unknown scope (fail-fast) — silently omitting the scope fragment would
# ship a header without disclosure of what was actually evaluated. The
# fallback case is wording-fenced separately from incremental so a
# regression that misframes fallback as incremental trips a smoke
# (recurring BCR class — see review-header-smoke.sh).
#
# HEAD_SHA is required on EVERY scope, and every fragment names it: the
# reviewed commit is the first thing a reader needs to know whether the
# review covers their latest push, and the head the worker checked out
# can differ from the one the orchestrator enumerated. Missing HEAD_SHA
# is fail-fast (return 1, stderr diagnostic) — a fragment that silently
# omits the reviewed SHA is exactly the ambiguity this disclosure
# exists to remove. The incremental fragment additionally cites the
# from-endpoint AND the exact git command that produced the diff —
# `git diff <from>..<to>` (two-dot, matching the worker's
# KID_INPUT_DIFF derivation) — so a reader can reproduce the review's
# diff locally with copy-paste.
format_review_scope() {
    local scope="$1" head_sha="${2:-}" sha from to
    if [ -z "$head_sha" ]; then
        printf 'format_review_scope: scope "%s" requires head_sha — internal invariant violated\n' "$scope" >&2
        return 1
    fi
    case "$scope" in
        first)
            printf '📋 First review of this PR — reviewed `%s`' "${head_sha:0:7}" ;;
        whole)
            printf '📋 Whole-PR re-review (`/%s-review`) — evaluated the full PR diff at `%s`' "${BOT_CMD_PREFIX:-srosro}" "${head_sha:0:7}" ;;
        incremental:*)
            sha="${scope#incremental:}"
            from="${sha:0:7}"
            to="${head_sha:0:7}"
            printf '📋 Re-review of changes from `%s` to `%s` (`git diff %s..%s`)' "$from" "$to" "$from" "$to" ;;
        fallback:*)
            sha="${scope#fallback:}"
            printf '📋 Re-review at `%s` — clean incremental unavailable for `%s` (rebase, force-push, or merge from base branch); evaluated full PR' "${head_sha:0:7}" "${sha:0:7}" ;;
        *)
            printf 'format_review_scope: unknown scope "%s" — internal invariant violated\n' "$scope" >&2
            return 1
            ;;
    esac
}

# run_just_test JUST_FILE REPO_DIR TEST_LOG TEST_TIMEOUT TEST_KILL_AFTER
#
# Runs `just test` under a timeout that escalates to SIGKILL, so a wedged or
# SIGTERM-ignoring test (the chat-postgres/pytest deadlock that motivated this)
# dies at the deadline instead of accumulating. Output → TEST_LOG. Returns
# `just`'s exit: 124 if it died on the timeout SIGTERM, 137 if `timeout -k` had
# to escalate to SIGKILL — classify_just_test_outcome maps both to TIMED OUT.
#
# `env -u LOG_FILE` scrubs LOG_FILE from the test subprocess: this repo's own
# lib/tests/test_pipeline.py calls pipeline.run_pipeline() under unittest
# discover and would otherwise inherit LOG_FILE and tee fixture chatter into
# the production orchestrator log. Cosmetic, but keeps post-mortem greps clean.
run_just_test() {
    local just_file="$1" repo_dir="$2" test_log="$3" test_timeout="$4" test_kill_after="$5"
    # Containerized deployment sets REVIEWER_TEST_USER to an unprivileged
    # account. PR-controlled `just test` is the most dangerous code the reviewer
    # runs, so drop to that user with an allowlisted env: it cannot read the
    # root-owned /root/.codex login (mode 600) or the reviewer's tokens (kept
    # out of the env passed in). Trusted-author live creds arrive as FILES in
    # repo_dir (the .env mirror in review-one-pr.sh), which the test user reads
    # from disk after the chown — never from the environment. The redirect to
    # $test_log is opened by this (root) shell before the privilege drop, so the
    # log stays root-owned and readable afterwards. The host/systemd path leaves
    # REVIEWER_TEST_USER unset and runs as the operator, unchanged.
    if [ -n "${REVIEWER_TEST_USER:-}" ]; then
        chown -R "$REVIEWER_TEST_USER" "$repo_dir"
        # Nested-dind shared dir. A reviewed repo's test stack (e.g. plow's
        # test-scenarios) may write a file the test runner shares with a stack
        # container via a host bind mount — but that mount is resolved by the
        # dind daemon's filesystem, not this reviewer's, so the path must live
        # on a volume mounted into BOTH at the same location (docker-compose.yml:
        # scenario-shared* → /scenario-shared). XDG_CACHE_HOME steers the recipe's
        # shared dir here (plow keys ONLY its bridge dir off it —
        # ${XDG_CACHE_HOME:-$HOME/.cache}/plow-scenario-shared, justfile:243); 1777
        # lets the unprivileged test user create its per-run subdir.
        # (SCENARIO_SHARED_DIR is a test seam; prod always uses the default.)
        local scenario_shared="${SCENARIO_SHARED_DIR:-/scenario-shared}"
        # Reset the bridge before EVERY run: the named volume persists
        # PR-written state, and a stale root-owned nested dir turns later runs'
        # mktemp into EACCES rendered as a generic test failure (issue #172 —
        # 66/66 false failures on one worker). Reap dind leftovers first (a
        # timed-out/died review leaves its stack running; dind serves only
        # this reviewer, so anything alive is an orphan that could race the
        # delete), then discard contents outright — a chown -R repair could be
        # steered via persisted hard links. Root keeps the 1777 volume root;
        # consumers recreate their dirs. The endpoint pin makes a misrouted
        # run (this code executed with a host daemon reachable, e.g. an
        # unstubbed test harness) refuse instead of rm -f'ing the wrong
        # daemon. Fail LOUD: the caller runs without `set -e`/`pipefail`.
        case "${DOCKER_HOST:-}" in "tcp://127.0.0.1:2375") ;; *)
            log "$PR_ID: FATAL — refusing dind reap: DOCKER_HOST='${DOCKER_HOST:-}' is not the dedicated dind endpoint (docker-compose.yml)"; exit 1;;
        esac
        local orphans
        # shellcheck disable=SC2086 — one container id per line, word-split intended
        orphans=$(docker ps -aq) && { [ -z "$orphans" ] || docker rm -fv $orphans >/dev/null; } \
            && mkdir -p "$scenario_shared" && find "$scenario_shared" -mindepth 1 -delete && chmod 1777 "$scenario_shared" \
            || { log "$PR_ID: FATAL — scenario-shared bridge reset failed (dind reap or bridge prep)"; exit 1; }
        local rc=0
        # Keep the uv/pip package caches OFF the dind-shared volume: point them at the
        # test user's own HOME via UV_CACHE_DIR/PIP_CACHE_DIR (both override
        # XDG_CACHE_HOME, which must stay /scenario-shared for plow's bridge above).
        # Without this the caches default to $XDG_CACHE_HOME/{uv,pip} on the persistent,
        # PR-influenceable shared volume — the source of both the stale-root-ownership
        # EACCES that spuriously failed tests AND the symlink/ownership races a
        # dind-side process could run against an in-place root repair. On HOME they're
        # created fresh, test-user-owned, on a path dind can't touch — no repair needed.
        timeout -k "$test_kill_after" "$test_timeout" \
            runuser -u "$REVIEWER_TEST_USER" -- \
            env -i PATH="$PATH" HOME="/home/$REVIEWER_TEST_USER" DOCKER_HOST="$DOCKER_HOST" \
                XDG_CACHE_HOME="$scenario_shared" \
                UV_CACHE_DIR="/home/$REVIEWER_TEST_USER/.cache/uv" \
                PIP_CACHE_DIR="/home/$REVIEWER_TEST_USER/.cache/pip" \
                just --justfile "$just_file" --working-directory "$repo_dir" test \
            > "$test_log" 2>&1 || rc=$?
        # The test ran as reviewer-test on a reviewer-test-owned tree; everything
        # after (git log/show, the .codex-scratch wipe + write_scratch) runs as
        # root. Reap any leftover reviewer-test procs (a test can `setsid` a
        # detached writer that outlives `just test`; pkill -u is UID-based so it
        # catches session-detached ones), restore ownership (else root git trips
        # the dubious-ownership guard), and strip group/other write bits so
        # nothing the test left behind (e.g. after a `chmod 777`) can race the
        # root scratch-staging path. Exit status is preserved for the classifier.
        # Bounded reap before root scratch staging: TERM, wait for exit, then
        # KILL (uncatchable) any that ignored it — a TERM-only best-effort would
        # leave a TERM-trapping writer alive to race the .codex-scratch wipe or
        # read root-staged inputs. pkill -u is UID-based, so it reaps even
        # setsid-detached procs.
        pkill -TERM -u "$REVIEWER_TEST_USER" 2>/dev/null || true
        for _ in $(seq 1 50); do pgrep -u "$REVIEWER_TEST_USER" >/dev/null 2>&1 || break; sleep 0.1; done
        pkill -KILL -u "$REVIEWER_TEST_USER" 2>/dev/null || true
        for _ in $(seq 1 20); do pgrep -u "$REVIEWER_TEST_USER" >/dev/null 2>&1 || break; sleep 0.1; done
        if pgrep -u "$REVIEWER_TEST_USER" >/dev/null 2>&1; then
            # A process surviving SIGKILL is a catastrophic integrity failure
            # (uninterruptible I/O, or a kernel/namespace bug). Fail fast — do NOT
            # proceed into root-owned scratch staging where a live writer could
            # race us. The worker's EXIT trap handles the placeholder + cleanup.
            log "$PR_ID: FATAL — reviewer-test process survived SIGKILL; aborting before root scratch staging"
            exit 1
        fi
        chown -R root:root "$repo_dir"
        chmod -R go-w "$repo_dir"
        return "$rc"
    else
        timeout -k "$test_kill_after" "$test_timeout" \
            env -u LOG_FILE just --justfile "$just_file" --working-directory "$repo_dir" test \
            > "$test_log" 2>&1
    fi
}

# timeout_duration_seconds DURATION
# Parse a GNU `timeout` duration ('90m', '30s', '1h', or bare seconds) to an
# integer seconds. Single parser shared by review.sh's worker-deadline math and
# cap_test_timeout below.
timeout_duration_seconds() {
    case "$1" in
        *s) printf '%s\n' "${1%s}" ;;
        *m) printf '%s\n' "$(( ${1%m} * 60 ))" ;;
        *h) printf '%s\n' "$(( ${1%h} * 3600 ))" ;;
        *)  printf '%s\n' "$1" ;;
    esac
}

# cap_test_timeout DEADLINE_EPOCH NOW RESERVE_SECS CONFIGURED
#
# Caps the inner `just test` window to the outer worker budget still left, so
# run_just_test's `timeout -k` reaps the test BEFORE the outer worker timeout
# fires. After a long same-repo flock wait the budget can be short; if the outer
# timeout landed first it would kill the worker (freeing the per-repo just-test
# lock) while the test's own process group kept running on shared Docker/port
# state — reopening the same-repo pileup the lock exists to prevent.
#
# RESERVE_SECS is the time to hold back before the deadline — the caller passes
# the inner kill-after PLUS a scheduling buffer, so the inner SIGKILL lands
# strictly before the outer SIGTERM rather than racing it on the same second.
# CONFIGURED is the normal ceiling as a GNU `timeout` duration ('30m'). Prints
# CONFIGURED verbatim when the full window fits (keeps the friendly form), the
# remaining budget as '<n>s' when it must be capped, or nothing when no window
# remains (caller skips the test). Pure — smoke-tested.
cap_test_timeout() {
    local deadline="$1" now="$2" reserve="$3" configured="$4"
    local budget=$(( deadline - now - reserve ))
    [ "$budget" -lt 1 ] && return 0
    local configured_secs
    configured_secs=$(timeout_duration_seconds "$configured")
    if [ "$budget" -ge "$configured_secs" ]; then
        printf '%s\n' "$configured"
    else
        printf '%ss\n' "$budget"
    fi
}

# classify_just_test_outcome TEST_EXIT TEST_LOG TEST_TIMEOUT
#
# Pure function. Maps `just test`'s (exit, stderr) to (TESTS_RAN,
# TEST_SUMMARY) tab-separated. The discriminator: `just` always
# appends `error: Recipe \`test\` failed on line N` to stderr when it
# actually ran a recipe (regardless of whether the command inside
# succeeded). It does NOT appear when `just` failed before invoking
# the recipe (no justfile, missing recipe, /tmp not writable, etc).
# So one signal handles every pre-recipe failure — no enumerated
# stderr-string list to expand for each new infra error.
#
# Outcomes:
#   - exit 0                              → ran, PASSED
#   - exit 124 / 137                      → ran, TIMED OUT (137 = `timeout -k`
#                                            SIGKILL'd a TERM-ignoring test)
#   - "Recipe failed" present + exit 127  → didn't run (recipe
#                                            invoked, but a command
#                                            inside — pytest, npm,
#                                            etc. — wasn't on PATH)
#   - "Recipe failed" present + other     → ran, FAILED (exit N)
#   - "Recipe failed" absent              → didn't run (just
#                                            pre-recipe failure: no
#                                            justfile / missing
#                                            recipe / sandbox blocked
#                                            /tmp / etc.)
#
# Hermetic — caller writes TEST_LOG; helper doesn't invoke `just`, so
# the smoke drives every branch with crafted (exit, log) pairs.
classify_just_test_outcome() {
    local test_exit="$1" test_log="$2" test_timeout="$3"
    case "$test_exit" in
        0)   printf 'true\tPASSED\n' ; return ;;
        # 124 = timeout sent SIGTERM and the test died; 137 = the test ignored
        # SIGTERM and `timeout -k` escalated to SIGKILL (128+9). Both mean the
        # test ran past TEST_TIMEOUT. (A bare OOM SIGKILL is also 137 — rare,
        # and "timed out" vs "failed" both read as non-passing to the author.)
        124|137) printf 'true\tTIMED OUT (>%s)\n' "$test_timeout" ; return ;;
    esac
    if [ -f "$test_log" ] && grep -q "^error: Recipe .* failed" "$test_log"; then
        if [ "$test_exit" -eq 127 ]; then
            printf 'false\tnot run (recipe ran but command-not-found inside, exit 127)\n'
        else
            printf 'true\tFAILED (exit %s)\n' "$test_exit"
        fi
    else
        printf 'false\tnot run (just pre-recipe failure: see test-results below)\n'
    fi
}

# format_tests_note TESTS_RAN TEST_SUMMARY
#
# Maps the (TESTS_RAN, TEST_SUMMARY) pair from classify_just_test_outcome
# into the deterministic header fragment. Symmetric with format_kid_note
# and the strict-typing note: every pre-check emits exactly one fragment
# describing its outcome, so a clean PR's header reads as "everything
# checked, all green" instead of collapsing to scope-only and leaving
# the reader guessing whether the checks ran at all.
#
# Pure function. Returns 1 on unrecognized inputs (fail-fast — silent
# fallback would publish a wrong outcome to the author).
format_tests_note() {
    local tests_ran="$1" summary="$2" convention_header="${3:-}"
    if [ "$tests_ran" = "false" ]; then
        # A convention repo (operator-defined via kwr-config) may declare its own
        # test gate instead of a root justfile — e.g. a SEED's `## Verification`/
        # `ref/verify.sh`. When the caller passes that convention's `test-header`
        # (only when there's no justfile), surface it so the public header states
        # the real gate instead of the generic "Tests not run", which would read
        # as a coverage gap. Convention-agnostic: the text comes from kwr-config.
        if [ -n "$convention_header" ]; then
            printf '🧪 %s' "$convention_header"
            return
        fi
        printf '🧪 Tests not run'
        return
    fi
    if [ "$tests_ran" != "true" ]; then
        printf 'format_tests_note: tests_ran must be "true"/"false", got "%s"\n' "$tests_ran" >&2
        return 1
    fi
    case "$summary" in
        PASSED)           printf '✅ Tests passed' ;;
        "TIMED OUT"*)     printf '🧪 Tests timed out (%s' "${summary#TIMED OUT (}" ;;
        "FAILED (exit "*) printf '🧪 Tests failed (exit %s' "${summary#FAILED (exit }" ;;
        *)
            printf 'format_tests_note: unrecognized TEST_SUMMARY for tests_ran=true: "%s"\n' "$summary" >&2
            return 1
            ;;
    esac
}

# format_kid_note KID_RAN
#
# Symmetric with format_tests_note: emits one fragment whether KID ran
# or was skipped, so the header surfaces the prior-art check on every
# review instead of going silent on the success path.
#
# "unavailable" (not "not run") on the false path: KID_RAN=false covers
# both operational states the worker compresses into one boolean — KID
# never invoked (no per-repo KID config / no .keepitdry / no diff input)
# AND invoked-but-errored (KID_EXIT != 0, KID_FLAG written). Either way,
# prior-art context did not inform the review; the public header reflects
# that without mis-stating the error path as a skip. Operator-facing
# diagnostics still go to the worker log + KID_FLAG.
format_kid_note() {
    local kid_ran="$1"
    case "$kid_ran" in
        true)  printf '✅ Prior-art (KID) checked' ;;
        false) printf '🔍 Prior-art (KID) unavailable' ;;
        *)
            printf 'format_kid_note: kid_ran must be "true"/"false", got "%s"\n' "$kid_ran" >&2
            return 1
            ;;
    esac
}

# format_specialist_timeouts NAMES_CSV
#
# One header fragment naming the angle(s) that timed out (codex parallel-
# tool-call deadlock) and were excluded from this review. Symmetric with
# format_tests_note / format_kid_note: the warning rides the same blockquote
# registry so a partial review is disclosed in the header instead of being
# aborted — aborting forced a full same-SHA re-review next tick, re-paying
# the whole specialist fan-out for the angles that already succeeded.
#
# Pure function. Empty NAMES_CSV is an invariant violation (the caller only
# invokes this when _wave_b_timeouts.txt is non-empty) — fail-fast.
format_specialist_timeouts() {
    local names="$1"
    if [ -z "$names" ]; then
        printf 'format_specialist_timeouts: empty names — internal invariant violated\n' >&2
        return 1
    fi
    printf '⏱️ Partial review — specialist(s) did not complete (timed out or model at capacity) and were skipped: `%s`' "$names"
}

# timeout_note_for_run RUN_DIR
#
# Sentinel→note adapter: echoes the format_specialist_timeouts fragment when
# this run recorded specialist timeouts (_wave_b_timeouts.txt non-empty),
# else nothing. Shared by the live worker (review-one-pr.sh) and replay
# (replay.sh) so a partial review discloses skipped angles identically on
# both surfaces — without either consumer re-implementing the read+format.
timeout_note_for_run() {
    local sentinel="$1/_wave_b_timeouts.txt" timed_out
    [ -s "$sentinel" ] || return 0
    timed_out=$(paste -sd, "$sentinel")
    format_specialist_timeouts "$timed_out"
}

# prepend_review_header COMMENT_BODY NOTE [NOTE...]
#
# Renders the unified deterministic registry as one blockquote line right
# under the auto-post marker. Each NOTE is a fully-formed fragment (icon
# + text, no trailing punctuation); helper joins with ". " and appends a
# final ".". Worker-side single source of truth: every deterministic
# signal lives in REVIEW_NOTES (see review-one-pr.sh, search "REVIEW_NOTES=()")
# — scope, stale-head, skipped pre-checks (tests, KID), gap findings
# (strict typing, future). One render target keeps the header from
# splitting into stacked blockquotes and prevents any signal from being
# hidden by a downstream filter.
#
# Empty notes list → fail-fast (return 1, stderr diagnostic). Worker
# always pushes at least the scope fragment, so an empty REVIEW_NOTES
# means an internal invariant violation; silently omitting the disclosure
# would let a regression ship a header-less review (per CLAUDE.md /
# feedback_fail_hard — crash loudly).
#
# Pure string transform — hermetic. All branches fenced in
# review-header-smoke.sh.
prepend_review_header() {
    local comment_body="$1"
    shift
    if [ "$#" -eq 0 ]; then
        printf 'prepend_review_header: empty notes list — internal invariant violated, refusing to silently omit header\n' >&2
        return 1
    fi
    local joined=""
    local note
    for note in "$@"; do
        if [ -z "$joined" ]; then
            joined="$note"
        else
            joined="$joined. $note"
        fi
    done
    joined="$joined."
    # Preserve ONLY the two exact-match knightwatch-reviewer markers
    # (auto-post + ai-author, both invisible in rendered Markdown).
    # Exact match — not prefix — because R8 caught that prefix matching
    # on the ai-author line lets an attacker craft a different content
    # suffix that gets preserved as if trusted. The auto-post string is
    # also pinned in lib/pr-comments.sh under the same env-var
    # default; both consume BOT_AI_AUTHOR_MARKER (defined at top of this
    # file) for the ai-author line so there's a single source of truth.
    local AUTO_POST_LINE="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
    local n_leading
    n_leading=$(printf '%s' "$comment_body" | awk -v auto="$AUTO_POST_LINE" -v ai="$BOT_AI_AUTHOR_MARKER" '
        $0 == auto { n++; next }
        $0 == ai   { n++; next }
        { exit }
        END { print n+0 }')
    [ "$n_leading" -lt 1 ] && n_leading=1
    local leading rest
    leading=$(printf '%s' "$comment_body" | sed -n "1,${n_leading}p")
    rest=$(printf '%s' "$comment_body" | sed -n "$((n_leading + 1)),\$p")
    printf '%s\n> %s\n\n%s' "$leading" "$joined" "$rest"
}

# is_run_author_visible <run_dir>
#   Returns 0 (author-visible — review was posted) or 1 (not author-visible —
#   aborted, in-flight, or otherwise unposted).
#
# Two signals indicate "the author saw this review on GitHub":
#   1. posted_at present — primary signal, stamped immediately after
#      `gh pr comment` succeeds.
#   2. status == "completed" — fallback for legacy runs created before
#      posted_at existed. status only flips to "completed" on the
#      success path after gh has posted, so "status == completed"
#      reliably implies "gh post succeeded" for any preserved run.
#
# Single owner for "which prior review rounds count" — both
# stage_prior_reviews (carry-forward) and compute_loc_trend
# (per-round LoC table) call this so they can't drift.
is_run_author_visible() {
    local run_dir="$1"
    [ -f "$run_dir/meta.json" ] || return 1
    local included
    included=$(jq -r 'if ((.posted_at // "") != "") or ((.status // "") == "completed") then "yes" else "no" end' \
        "$run_dir/meta.json" 2>/dev/null)
    [ "$included" = "yes" ]
}

# author_visible_runs_iter <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: one line per author-visible run dir for this PR, sorted by
#   timestamp ascending (run-dir names share repo_slug+pr_num prefix, so
#   `find | sort` is equivalent to "sort by RUN_TS"). Skips current_run_dir
#   and any run dir that fails the author-visible predicate (which also
#   filters out pre-checkout aborts that never wrote meta.json).
#
# Single source-of-truth walker for "which prior posted reviews exist for
# this PR." Every consumer that asks "what has the author seen?" reads
# from this iterator instead of re-implementing the run-dir glob +
# self-exclusion + author-visible filter — the BCR class flagged across
# multiple rounds of PR #38 was exactly this kind of split-across-consumers
# divergence (state.json's PREV_BODY vs runs/ metadata vs LOC-trend).
#
# Pure read-only walk; no side effects. Callers project whatever they
# need (body, ts, sha) from the yielded run-dir paths.
author_visible_runs_iter() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local prior_run
    while IFS= read -r prior_run; do
        [ "$prior_run" = "$current_run_dir" ] && continue
        is_run_author_visible "$prior_run" || continue
        printf '%s\n' "$prior_run"
    done < <(find "$state_dir/runs" -maxdepth 1 -type d -name "${repo_slug}__${pr_num}__*" 2>/dev/null | sort)
}

stage_prior_reviews() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local prior_run prior_ts result=""
    while IFS= read -r prior_run; do
        prior_ts=$(basename "$prior_run" | grep -oE 'T[0-9]+Z' | head -1)
        result+=$'\n--- review at '"${prior_ts:-unknown}"$' ---\n'
        result+=$(cat "$prior_run/agents/aggregator/output.md")
        result+=$'\n'
    done < <(author_visible_runs_iter "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    printf '%s' "$result"
}

# reeval_marker_fired <marker> <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   Returns 0 if <marker> has already fired in a prior author-visible round.
#
# Re-eval fire-once markers are standalone lines the aggregator emits at the
# top of a review body. Read each prior run's aggregator output directly and
# inspect only its first 8 lines — no in-band separator parsing, so nothing a
# rendered Sketch fence can contain (fake separators, quoted markers) is ever
# window-eligible.
reeval_marker_fired() {
    local marker="$1" state_dir="$2" repo_slug="$3" pr_num="$4" current_run_dir="$5"
    local prior_run
    while IFS= read -r prior_run; do
        [ -f "$prior_run/agents/aggregator/output.md" ] || continue
        if head -8 "$prior_run/agents/aggregator/output.md" | grep -qxF "$marker"; then
            return 0
        fi
    done < <(author_visible_runs_iter "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    return 1
}

# latest_author_visible_review <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: aggregator output of the most recent author-visible prior review
#   (last by timestamp), or empty if no prior author-visible run exists.
#
# Single seam for "what did the author see last?" — replaces state.json's
# PREV_BODY as the source for previous-review.md staging + the momentum
# gate. Sourcing from runs/ closes the BCR drift on the gh-post-succeeded /
# state_set-failed path: meta.json's posted_at lands BEFORE state_set
# fires, so this helper still sees the latest review even when state.json
# never got the PREV_BODY/sha update.
#
# Sibling helpers latest_author_visible_review_sha and
# latest_author_visible_review_approved expose the same selection's
# reviewed SHA and approval verdict — together they form the "one
# author-visible round projection" the BCR-class fence demands so the
# three values (body, sha, approved) can't drift across consumers.
latest_author_visible_review() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest
    latest=$(_latest_author_visible_run_dir "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    [ -n "$latest" ] && cat "$latest/agents/aggregator/output.md" 2>/dev/null
}

# _latest_author_visible_run_dir — internal: returns the path of the
# most recent author-visible run dir (or empty if none). Single owner
# of the "last one wins" selection so body/sha/approved helpers can't
# pick different runs.
_latest_author_visible_run_dir() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest="" prior_run
    while IFS= read -r prior_run; do
        latest="$prior_run"  # last one wins (iterator is sorted ascending)
    done < <(author_visible_runs_iter "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    printf '%s' "$latest"
}

# latest_author_visible_review_sha <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: reviewed SHA of the most recent author-visible prior review,
#   or empty if no prior author-visible run exists.
#
# SHA preference matches author_visible_rounds: .reviewed_sha (post-
# checkout HEAD the worker actually evaluated) wins over .sha
# (orchestrator-enumerated, can drift from HEAD on a fast-cadence race).
# Companion to latest_author_visible_review (body) and
# latest_author_visible_review_approved — replaces state.json's
# `state_get "sha"` read in review-one-pr.sh, closing the same BCR race
# the body helper closed: gh-post-succeeded + state_set-failed leaves
# state.json stale, but meta.json was stamped before state_set ran.
latest_author_visible_review_sha() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest
    latest=$(_latest_author_visible_run_dir "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    [ -z "$latest" ] && return 0
    jq -r '.reviewed_sha // .sha // empty' "$latest/meta.json" 2>/dev/null
}

# latest_author_visible_review_approved <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: "true" if the latest author-visible round actually approved
#   (per review_is_approval — APPROVE verdict AND full coverage), "false"
#   if it commented or was a partial-coverage review, or empty if no prior
#   author-visible run exists.
#
# Semantic: "did our last review approve?" — routed through review_is_approval
# so the carried-forward verdict matches the worker's submit decision exactly
# (single source of truth). A partial-coverage round whose aggregator line
# said APPROVE reads "false" here, the same way the worker withheld the GitHub
# approval — the two can't drift. NOT a signal of the GitHub PR's current
# approval state: `submit_approval` (lib/auth.sh) can still decline a
# self-authored PR even on a true approval, but that divergence is irrelevant
# (the only reader is REVIEW_TASK in lib/review-one-pr.sh, reporting what the
# prior review concluded).
#
# Parsed from output.md rather than state.json so the body, sha, and
# approved values all anchor to the same round — same BCR fence as the
# other two helpers. Aggregator contract (prompts/aggregator.md): final
# line is `VERDICT: APPROVE`, `VERDICT: APPROVE — pending: ...`, or
# `VERDICT: COMMENT`. Match anchored at start-of-line on the last 10
# lines so trailing prose can't false-positive.
# review_is_approval VERDICT_LINE RUN_DIR
#   exit 0 iff this run is an actual approval: the aggregator verdict is
#   `VERDICT: APPROVE`/`APPROVE — pending: ...` AND coverage was full (no
#   specialist timed out, i.e. _wave_b_timeouts.txt is absent/empty).
#
# Single owner of "did this review approve?" — both the worker's GitHub
# submit gate (review-one-pr.sh) and the carried-forward `approved`
# projection (latest_author_visible_review_approved below) route through it,
# so partial coverage can never greenlight in one place while reading as
# approved in the other. A partial review (a specialist, possibly security,
# was skipped) is never an approval — disclosed by the ⏱️ header instead.
review_is_approval() {
    local verdict="$1" run_dir="$2"
    [[ "$verdict" == VERDICT:\ APPROVE* ]] || return 1
    [ -s "$run_dir/_wave_b_timeouts.txt" ] && return 1
    return 0
}

latest_author_visible_review_approved() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest verdict
    latest=$(_latest_author_visible_run_dir "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    [ -z "$latest" ] && return 0
    verdict=$(tail -n 10 "$latest/agents/aggregator/output.md" 2>/dev/null \
        | grep -E '^VERDICT:' | tail -1)
    if review_is_approval "$verdict" "$latest"; then
        printf 'true'
    else
        printf 'false'
    fi
}

# latest_author_visible_review_started_at <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: ISO 8601 timestamp from meta.json's `started_at` field of the
#           latest author-visible run, or empty if no prior author-visible
#           run exists.
#
# Used by review.sh's slash-command cutoff logic ("are there /srosro-*
# comments newer than the last review?"). Replaces a stale
# `state_get "reviewed_at"` read on state.json that left the
# gh-success + state_set-failure race leaking through the trigger
# cutoff: meta.json's started_at is stamped at run init (well before
# state_set), so the cutoff stays accurate even when the post-review
# state.json write never landed.
#
# Field choice: started_at, NOT posted_at. Cutoff semantic is "any comment
# arriving after this review STARTED is fresh and should requalify on
# the next tick" — matches the existing REVIEW_START_TS plumbing in
# lib/review-one-pr.sh. posted_at is later (after gh succeeds), so a
# /srosro-review posted DURING the review would fall before posted_at
# and be silently lost on the next tick if we keyed off it.
latest_author_visible_review_started_at() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest
    latest=$(_latest_author_visible_run_dir "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    [ -z "$latest" ] && return 0
    jq -r '.started_at // empty' "$latest/meta.json" 2>/dev/null
}

# author_visible_rounds <state_dir> <repo_slug> <pr_num> <current_run_dir>
#   stdout: one line per author-visible round, format: <ts>\t<sha>
#   sorted by timestamp ascending (matches author_visible_runs_iter).
#
# Canonical SHA + timestamp sources are meta.json fields. SHA preference:
#   1. .reviewed_sha — post-checkout HEAD; what the worker actually evaluated.
#      Stamped after the checkout in review-one-pr.sh.
#   2. .sha — pre-checkout, orchestrator-enumerated PR_SHA. Falls behind when
#      the head moves between enumeration and the worker's fetch (a normal
#      race in a fast-cadence orchestrator).
#   3. Run-dir-name suffix — legacy parse for older runs without meta fields.
# .reviewed_sha winning over .sha keeps the LOC trajectory anchored to the
# SHA whose diff the worker fed into the round, even when an enumeration
# race made the two diverge.
#
# This is the single owner for the "(ts, sha) per round" contract that
# compute_loc_trend (per-round LoC table) consumes. Drift fence: keep
# the canonical-SHA projection in one helper so a downstream caller
# can't drift to a stale local copy.
author_visible_rounds() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local prior_run meta_sha meta_ts
    while IFS= read -r prior_run; do
        meta_sha=$(jq -r '.reviewed_sha // .sha // empty' "$prior_run/meta.json" 2>/dev/null)
        meta_ts=$(jq -r '.started_at // empty' "$prior_run/meta.json" 2>/dev/null)
        # Fall back to run-dir name parsing only if meta is incomplete.
        [ -z "$meta_ts" ] && meta_ts=$(basename "$prior_run" | grep -oE 'T[0-9]+Z' | head -1)
        [ -z "$meta_sha" ] && meta_sha=$(basename "$prior_run" | awk -F'__' '{print $4}')
        [ -z "$meta_sha" ] && continue
        printf '%s\t%s\n' "$meta_ts" "$meta_sha"
    done < <(author_visible_runs_iter "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
}
