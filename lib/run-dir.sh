#!/bin/bash
# Sourceable helper for allocating a per-run dir. Lives outside
# review-one-pr.sh so the regression smoke can exercise the same
# function the worker calls (instead of testing a copy).
#
# Caller must already have LOG_FILE + PR_ID set up so log() works.

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
        rm -rf "$run_dir"
        return 1
    fi
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
# filter regression silently disables Bug-Class-Recurrence detection
# without tripping any other test.
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
# Returns 0 on success; returns 1 on jq parse / mv failure (and cleans
# up the .tmp file). The worker's EXIT trap calls this; failures are
# caught by the trap and logged. Smoke regression-fences the four
# branches the worker depends on (see lib/tests/finalize-meta-smoke.sh).
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
#   "fallback:<sha>"      — KNOWN_SHA NOT in local history (force-push/rebase
#                           evicted it); specialists silently see the full PR
#                           via gh pr diff because the incremental view is
#                           unavailable — the scope name calls this out so
#                           prepend_review_scope_note + REVIEW_TASK both
#                           disclose it instead of framing it as incremental
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
#   - exit 124                            → ran, TIMED OUT
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
        124) printf 'true\tTIMED OUT (>%s)\n' "$test_timeout" ; return ;;
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

# prepend_review_header COMMENT_BODY SCOPE REVIEWED_SHA CURRENT_HEAD TESTS_RAN
#
# Single source of truth for the disclosure header that goes right under
# the auto-post marker. Combines three signals into one concise blockquote:
#
#   1. Scope (always present): what kind of review this is — first,
#      whole-PR re-review, incremental re-review, or silent-fallback
#      re-review. Lets the reader interpret findings in the right
#      context (e.g. an incremental re-review didn't look at unchanged
#      code; a fallback evaluated the whole PR despite framing).
#
#   2. Stale-head warning (conditional): if CURRENT_HEAD differs from
#      REVIEWED_SHA, the PR head moved during the run and the review is
#      for an older SHA — appended as one-sentence suffix to the same
#      blockquote. Empty CURRENT_HEAD (best-effort gh-fetch failed) is
#      treated as "no warning" — same as matched.
#
#   3. Tests-not-run warning (conditional): if TESTS_RAN="false", the
#      worker couldn't run `just test` (no justfile, or recipe failed
#      with command-not-found inside). Specialists reviewed the diff
#      alone — disclose so the reader doesn't assume "no test failures
#      flagged" means the bot ran tests and they passed. Any other value
#      ("true" or empty) suppresses the suffix.
#
# Replaces the previous two helpers (prepend_review_scope_note +
# prepend_stale_head_note) that stacked two separate verbose
# blockquotes. One concise line keeps the header from dominating the
# review and gives the reader all signals at the same vertical glance.
#
# SCOPE format:
#   "first"               — first review of this PR
#   "whole"               — force_whole_pr=true (e.g. /srosro-review)
#   "incremental:<sha>"   — KNOWN_SHA in local history; specialists got
#                           git diff KNOWN_SHA..HEAD
#   "fallback:<sha>"      — KNOWN_SHA NOT in local history (force-push
#                           / rebase evicted it); worker silently fell
#                           back to gh pr diff (the full PR)
#
# Unknown SCOPE: fail-fast (return 1, stderr diagnostic) — see the
# default case in compute_review_scope's contract. Caller must check
# the exit code and abort the run.
#
# Pure string transform — hermetic. All branches fenced in
# review-header-smoke.sh.
prepend_review_header() {
    local comment_body="$1" scope="$2" reviewed_sha="$3" current_head="$4" tests_ran="$5"
    local scope_text stale_suffix="" tests_suffix="" sha
    case "$scope" in
        first)
            scope_text="📋 First review of this PR."
            ;;
        whole)
            scope_text="📋 Whole-PR re-review (\`/srosro-review\`) — evaluated from scratch, no prior review consulted."
            ;;
        incremental:*)
            sha="${scope#incremental:}"
            scope_text="📋 Re-review of changes since \`${sha:0:7}\`."
            ;;
        fallback:*)
            sha="${scope#fallback:}"
            scope_text="📋 Re-review — prior SHA \`${sha:0:7}\` no longer in local history (force-push/rebase); evaluated full PR."
            ;;
        *)
            # scope is internal — only compute_review_scope produces it.
            # An unknown value means the worker has violated its own
            # invariant (e.g. a new scope was added to compute_review_scope
            # but not wired here). Per CLAUDE.md / feedback_fail_hard,
            # crash loudly instead of silently omitting the very header
            # this helper exists to add — that would let a regression
            # ship as a normal-looking review with no disclosure at all.
            printf 'prepend_review_header: unknown scope "%s" — internal invariant violated, refusing to silently omit header\n' "$scope" >&2
            return 1
            ;;
    esac
    if [ -n "$current_head" ] && [ "$current_head" != "$reviewed_sha" ]; then
        stale_suffix=" ⚠️ Stale: head moved from \`${reviewed_sha:0:7}\` to \`${current_head:0:7}\` mid-run — see commands below to re-run."
    fi
    if [ "$tests_ran" = "false" ]; then
        tests_suffix=" 🧪 Tests not run — review based on the diff alone (see test-results section for why)."
    fi
    local first_line rest
    first_line=$(printf '%s' "$comment_body" | head -1)
    rest=$(printf '%s' "$comment_body" | tail -n +2)
    printf '%s\n> %s%s%s\n\n%s' "$first_line" "$scope_text" "$stale_suffix" "$tests_suffix" "$rest"
}

stage_prior_reviews() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local prior_run prior_ts included result=""
    while IFS= read -r prior_run; do
        [ "$prior_run" = "$current_run_dir" ] && continue
        # Two signals say "the author saw this review on GitHub":
        #   1. posted_at present — primary signal, stamped immediately after
        #      `gh pr comment` succeeds in review-one-pr.sh. Set BEFORE
        #      state_set runs, so it correctly includes the rare case where
        #      gh succeeded but state_set or finalize failed afterward.
        #   2. status == "completed" — fallback for legacy runs created
        #      before this PR added the posted_at field. status only flips
        #      to "completed" after state_set succeeds, which in the
        #      production worker flow only runs after gh has posted, so
        #      "status == completed" reliably implies "gh post succeeded"
        #      for any preserved run.
        # Either signal is sufficient — the union captures all
        # author-visible reviews including legacy history, while excluding
        # aborted runs where the author never received the review.
        included=$(jq -r 'if ((.posted_at // "") != "") or ((.status // "") == "completed") then "yes" else "no" end' \
            "$prior_run/meta.json" 2>/dev/null)
        [ "$included" = "yes" ] || continue
        prior_ts=$(basename "$prior_run" | grep -oE 'T[0-9]+Z' | head -1)
        result+=$'\n--- review at '"${prior_ts:-unknown}"$' ---\n'
        result+=$(cat "$prior_run/agents/aggregator/output.md")
        result+=$'\n'
    done < <(find "$state_dir/runs" -maxdepth 1 -type d -name "${repo_slug}__${pr_num}__*" 2>/dev/null | sort)
    printf '%s' "$result"
}
