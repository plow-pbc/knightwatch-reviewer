#!/bin/bash
# Diff-scope helper: identify files the PR actually authored, ignoring
# content brought in via `git merge origin/<default-branch>`.
#
# Today review-one-pr.sh hands `gh pr diff` (GitHub's three-dot view)
# to specialists. That view includes everything since the merge-base,
# so when a PR runs `git merge origin/main`, every main commit pulled
# in shows up as if the PR author wrote it. Specialists then file
# findings against the wrong author. compute_pr_authored_files filters
# the diff back down to "files that branch-unique non-merge commits
# touched" — the PR's actual contribution.
#
# Caller responsibility: ensure the workdir has enough history that
# `git log <base>..HEAD` is computable. review-one-pr.sh fetches with
# --depth=500 which covers the long tail of long-lived branches; if a
# branch exceeds that, the caller must fall back to the unfiltered
# diff and log a degradation note.

# compute_pr_authored_files <repo_dir> <default_branch>
#   stdout: one path per line, sorted, unique. Files touched by
#           non-merge commits unique to HEAD vs origin/<default_branch>.
#   exit:   0 if at least one file. 1 if empty (branch has no
#           non-merge content) — caller decides fallback.
compute_pr_authored_files() {
    local repo_dir="$1" default_branch="$2"
    local files
    files=$(git -C "$repo_dir" log --no-merges \
        "origin/${default_branch}..HEAD" \
        --name-only --pretty=format: 2>/dev/null \
        | grep -v '^$' | sort -u)
    [ -z "$files" ] && return 1
    printf '%s\n' "$files"
    return 0
}
