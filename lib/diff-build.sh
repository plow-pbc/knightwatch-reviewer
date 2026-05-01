#!/bin/bash
# Diff-build helper for the reviewer worker.
#
# Single source of truth for "what was reviewed": the worker captures
# REVIEWED_SHA + BASE_REF after `git checkout`, then derives the full
# PR diff, the optional incremental diff, the touched-file lists, and
# the diff-source context all from that one local worktree snapshot.
# No live `gh pr diff` calls during review production — those raced
# with mid-run pushes and contradicted the SHA the worker had just
# checked out (the BCR class flagged across PR #31 and PR #35 reviews).
#
# resolve_pr_base_ref REPO PR_NUM
#   Returns the PR's actual base branch name (e.g. "main",
#   "release-2.0") via `gh pr view --json baseRefName`. Required
#   because the prior worker resolved only `defaultBranchRef` (the
#   *repo's* default), so non-default-base PRs fetched the wrong
#   ref into canonical and diffed against the wrong upstream. Empty
#   stdout on gh failure — caller fail-fast.
#
# is_clean_incremental_available <repo_dir> <known_sha>
#   exit 0 if a local incremental diff (`git diff $known_sha..HEAD`)
#   would faithfully represent "what's new on the branch since
#   $known_sha":
#     (a) $known_sha is still an ancestor of HEAD — no force-push or
#         rebase has evicted it from the branch's current history
#     (b) no merge commits exist in $known_sha..HEAD — no merge-from-
#         main commits to pollute the incremental scope (the bot's
#         round 2 same-file leak finding)
#   exit 1 otherwise — caller falls back to the full PR diff with a
#   deterministic warning at the top of the review.

resolve_pr_base_ref() {
    local repo="$1" pr_num="$2"
    gh pr view "$pr_num" --repo "$repo" --json baseRefName --jq '.baseRefName' 2>/dev/null
}

is_clean_incremental_available() {
    local repo_dir="$1" known_sha="$2"
    git -C "$repo_dir" merge-base --is-ancestor "$known_sha" HEAD 2>/dev/null \
        && [ -z "$(git -C "$repo_dir" log --merges --pretty=format:%H "$known_sha..HEAD" 2>/dev/null)" ]
}

# extract_touched_files_both_sides
#   Reads a unified-diff text on stdin; emits sorted-unique file paths
#   touched on EITHER side of every file change — additions, deletions,
#   and renames (including similarity-100% pure renames where +++/---
#   headers are absent). Source: `diff --git a/X b/Y` headers, which
#   always appear once per file change regardless of type. Strips the
#   leading `a/` or `b/` prefix.
#
#   Used by the worker's strict-typing scope gate: a PR that DELETES
#   `foo.py` or RENAMES `foo.ts` → `foo.js` touched typed code, but
#   the post-image-only `+++ b/` parse misses both cases (deletion's
#   post-image is `/dev/null`; pure rename has no `+++ b/` line at
#   all). Without both-sides extraction the gate would silently
#   suppress the strict-typing note on those PRs (the Narrow-Fix
#   flagged in PR #31 round-1 review).
#
#   Limitation: paths quoted by git (containing spaces or special
#   chars: `diff --git "a/foo bar.py" "b/foo bar.py"`) are split on
#   whitespace by awk and won't extract cleanly. Repos with such
#   paths fall through to the empty list and the gate skips — same
#   as if no typed files were touched. Acceptable: the strict-typing
#   nag false-negatives on space-in-path repos, which is rare and
#   recoverable (the operator can read repos.conf and infer the
#   gap).
extract_touched_files_both_sides() {
    awk '/^diff --git / { print $3; print $4 }' \
        | sed 's|^[ab]/||' \
        | LC_ALL=C sort -u
}

