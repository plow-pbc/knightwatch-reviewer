#!/bin/bash
# Diff-build helper for the reviewer worker.
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
#
# This is the only helper from the deleted lib/diff-scope.sh that
# survived. The rest of that machinery — build_pr_diff,
# build_incremental_diff, compute_authored_files, has_traceable_history,
# DIFF_EXCLUDES tracking — was layers of trying to reinvent what
# `gh pr diff` (server-side three-dot) already does correctly. The
# worker now defaults to gh pr diff and only takes the local
# incremental optimization when this predicate confirms it's safe.
is_clean_incremental_available() {
    local repo_dir="$1" known_sha="$2"
    git -C "$repo_dir" merge-base --is-ancestor "$known_sha" HEAD 2>/dev/null \
        && [ -z "$(git -C "$repo_dir" log --merges --pretty=format:%H "$known_sha..HEAD" 2>/dev/null)" ]
}
