#!/usr/bin/env bash
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

# format_review_scope SCOPE [HEAD_SHA]
#
# Maps the scope token (from compute_review_scope) to the human-readable
# fragment that goes into REVIEW_NOTES. Pure function. Returns 1 on
# unknown scope (fail-fast) — silently omitting the scope fragment would
# ship a header without disclosure of what was actually evaluated. The
# fallback case is wording-fenced separately from incremental so a
# regression that misframes fallback as incremental trips a smoke
# (recurring BCR class — see review-header-smoke.sh).
#
# HEAD_SHA is required on `incremental:<sha>` and ignored on every other
# scope. The incremental fragment cites both endpoints AND the exact
# git command that produced the diff — `git diff <from>..<to>` (two-dot,
# matching the worker's KID_INPUT_DIFF derivation) — so a reader can
# reproduce the review's diff locally with copy-paste, without having
# to guess which range the bot evaluated. Missing HEAD_SHA on the
# incremental path is fail-fast (return 1, stderr diagnostic) — the
# fragment would otherwise silently omit the to-SHA and the command.
format_review_scope() {
    local scope="$1" head_sha="${2:-}" sha from to
    case "$scope" in
        first)
            printf '📋 First review of this PR' ;;
        whole)
            printf '📋 Whole-PR re-review (`/srosro-review`) — evaluated from scratch, no prior review consulted' ;;
        incremental:*)
            sha="${scope#incremental:}"
            if [ -z "$head_sha" ]; then
                printf 'format_review_scope: incremental scope requires head_sha — internal invariant violated\n' >&2
                return 1
            fi
            from="${sha:0:7}"
            to="${head_sha:0:7}"
            printf '📋 Re-review of changes from `%s` to `%s` (`git diff %s..%s`)' "$from" "$to" "$from" "$to" ;;
        fallback:*)
            sha="${scope#fallback:}"
            printf '📋 Re-review — clean incremental unavailable for `%s` (rebase, force-push, or merge from base branch); evaluated full PR' "${sha:0:7}" ;;
        *)
            printf 'format_review_scope: unknown scope "%s" — internal invariant violated\n' "$scope" >&2
            return 1
            ;;
    esac
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
    # Preserve ALL leading HTML-comment lines (e.g. auto-post + ai-author
    # markers, both invisible in rendered Markdown) before injecting the
    # visible blockquote. Pinning to "line 1 only" pushes any second hidden
    # marker below the visible header, where AI-author tooling reading raw
    # bodies via `gh api` still sees it but the ordering contract drifts.
    local n_leading
    n_leading=$(printf '%s' "$comment_body" | awk '/^<!--/{n++; next} {exit} END{print n+0}')
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
# stage_prior_reviews (Bug-Class-Recurrence) and compute_loc_trend
# (LOC trajectory table) call this so they can't drift.
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
#   stdout: "true" if the latest author-visible round's aggregator output
#   ended in a `VERDICT: APPROVE` (or `VERDICT: APPROVE — pending: ...`)
#   line, "false" if it ended in `VERDICT: COMMENT`, or empty if no prior
#   author-visible run exists.
#
# Semantic: "what did our last review SAY?" — sourced from output.md so it
# anchors to the same round as body + sha (BCR fence). Consumers use it to
# carry the prior verdict into the next round's prompt. NOT a signal of
# the GitHub PR's current approval state — `submit_approval` (lib/auth.sh)
# can decline self-authored PRs, so a markdown verdict of APPROVE may
# coincide with no actual GitHub approval. That divergence is irrelevant
# here because no consumer asks "is the PR approved on GitHub right now?"
# (the only reader is REVIEW_TASK in lib/review-one-pr.sh, which reports
# what the prior review said).
#
# Parsed from output.md rather than state.json so the body, sha, and
# approved values all anchor to the same round — same BCR fence as the
# other two helpers. Aggregator contract (prompts/aggregator.md): final
# line is `VERDICT: APPROVE`, `VERDICT: APPROVE — pending: ...`, or
# `VERDICT: COMMENT`. Match anchored at start-of-line on the last 10
# lines so trailing prose can't false-positive.
latest_author_visible_review_approved() {
    local state_dir="$1" repo_slug="$2" pr_num="$3" current_run_dir="$4"
    local latest
    latest=$(_latest_author_visible_run_dir "$state_dir" "$repo_slug" "$pr_num" "$current_run_dir")
    [ -z "$latest" ] && return 0
    if tail -n 10 "$latest/agents/aggregator/output.md" 2>/dev/null \
            | grep -qE '^VERDICT: APPROVE'; then
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
# compute_loc_trend (LOC trajectory) consumes. Bug-Class-Recurrence
# fence: keep the canonical-SHA projection in one helper so a downstream
# caller can't drift to a stale local copy.
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
