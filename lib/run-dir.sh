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

# prepend_stale_head_note COMMENT_BODY REVIEWED_SHA CURRENT_HEAD
#
# If REVIEWED_SHA matches CURRENT_HEAD (or CURRENT_HEAD is empty —
# best-effort gh-fetch failed), echoes COMMENT_BODY unchanged.
#
# Otherwise, the PR head moved during this run and the review the user is
# about to see is for an older SHA. Inject a deterministic warning right
# after the auto-post marker (first line) so the user doesn't read the
# review as "the bot didn't see my fix" — it literally never saw it.
#
# The warning intentionally does NOT name a specific slash-command —
# it points to "the commands at the bottom of this comment" so there's
# one source of truth for usage (the existing footer), and so updating
# the available commands later doesn't fork into two surfaces.
#
# Hermetic — pure string transform. Smoke verifies all three branches:
# matched-shas (no-op), differing-shas (warning prepended), empty
# CURRENT_HEAD (gh failure path: no-op).
prepend_stale_head_note() {
    local comment_body="$1" reviewed_sha="$2" current_head="$3"
    if [ -z "$current_head" ] || [ "$current_head" = "$reviewed_sha" ]; then
        printf '%s' "$comment_body"
        return
    fi
    local warning first_line rest
    warning="> ⚠️ **Stale review** — generated against \`${reviewed_sha:0:7}\`, but the PR head has advanced to \`${current_head:0:7}\` since this review started. Findings below may already be addressed in newer commits. To trigger a fresh review against the current head, see the commands at the bottom of this comment."
    first_line=$(printf '%s' "$comment_body" | head -1)
    rest=$(printf '%s' "$comment_body" | tail -n +2)
    printf '%s\n%s\n\n%s' "$first_line" "$warning" "$rest"
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

# prepend_review_scope_note COMMENT_BODY SCOPE
#
# Injects a one-line "what kind of review is this" notice right after
# the auto-post marker (first line) of $COMMENT_BODY. So the user sees
# at a glance whether they're reading a first review, a /srosro-review
# whole-PR re-review, an incremental re-review (and from which prior
# SHA), or the silent full-diff fallback that fires when the prior SHA
# was evicted by force-push/rebase.
#
# Without this note, the worker's prose ("Re-review: the author has
# pushed new commits since your previous review") doesn't disclose the
# review scope — incremental and silent-fallback runs read identically
# even though the first sees N files and the second sees the whole PR.
#
# SCOPE format:
#   "first"               — first review of this PR
#   "whole"               — force_whole_pr=true (e.g. /srosro-review)
#   "incremental:<sha>"   — KNOWN_SHA in local history; specialists got
#                           git diff KNOWN_SHA..HEAD
#   "fallback:<sha>"      — KNOWN_SHA NOT in local history (force-push
#                           / rebase evicted it); worker silently fell
#                           back to gh pr diff (the full PR), framing
#                           it as incremental — this scope name calls
#                           it out explicitly
#   anything else         — no-op, returns body unchanged (best-effort)
#
# Pure string transform — hermetic. Smoke fences each branch.
prepend_review_scope_note() {
    local comment_body="$1" scope="$2"
    local note=""
    case "$scope" in
        first)
            note="> 📋 **First review** of this PR."
            ;;
        whole)
            note="> 📋 **Whole-PR re-review** — full diff evaluated from scratch (no prior review consulted)."
            ;;
        incremental:*)
            local sha="${scope#incremental:}"
            note="> 📋 **Re-review of changes since \`${sha:0:7}\`.** Specialists evaluated the incremental diff; aggregator verified prior findings against the current full PR state."
            ;;
        fallback:*)
            local sha="${scope#fallback:}"
            note="> 📋 **Re-review** — prior SHA \`${sha:0:7}\` is no longer in local history (likely a force-push or rebase); evaluated the full PR diff instead of an incremental one."
            ;;
        *)
            printf '%s' "$comment_body"
            return
            ;;
    esac
    local first_line rest
    first_line=$(printf '%s' "$comment_body" | head -1)
    rest=$(printf '%s' "$comment_body" | tail -n +2)
    printf '%s\n%s\n\n%s' "$first_line" "$note" "$rest"
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
