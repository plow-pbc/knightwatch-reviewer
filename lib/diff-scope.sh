#!/bin/bash
# Diff-scope helper: identify files the PR actually authored, ignoring
# content brought in via `git merge origin/<default-branch>`.
#
# Today review-one-pr.sh hands `gh pr diff` (GitHub's three-dot view)
# to specialists. That view includes everything since the merge-base,
# so when a PR runs `git merge origin/main`, every main commit pulled
# in shows up as if the PR author wrote it. Specialists then file
# findings against the wrong author. This helper filters the diff
# back down to "files that branch-unique non-merge commits touched"
# — the PR's actual contribution.
#
# The same problem hits two more sites: incremental re-review (diff
# since the prior reviewed SHA can include merged-in main commits
# pulled in between then and now) and file-history scratch staging.
# All three call into compute_authored_files() with the appropriate
# exclude refs.
#
# Caller responsibility: ensure the workdir has enough history that
# `git log` can walk the relevant commits. review-one-pr.sh fetches
# with --depth=500 to make this rare.

# compute_authored_files <repo_dir> <head_ref> <exclude_ref> [<exclude_ref>...]
#   stdout: one path per line, sorted, unique. Files touched by
#           non-merge commits reachable from <head_ref> but not from
#           any <exclude_ref>.
#   exit:   0 if at least one file. 1 if empty (no non-merge content
#           remains after exclusions) — caller decides fallback.
#
# Why multiple excludes: incremental review needs to filter out BOTH
# already-reviewed commits AND commits brought in via main-merges since.
# A single base ref isn't enough, because `prior_sha..HEAD` still
# contains merged-in main commits that were never on the branch's
# mainline.
compute_authored_files() {
    local repo_dir="$1" head_ref="$2"
    shift 2
    local exclude_args=()
    local ref
    for ref in "$@"; do
        exclude_args+=("^${ref}")
    done
    local files
    files=$(git -C "$repo_dir" log --no-merges \
        "$head_ref" "${exclude_args[@]}" \
        --name-only --pretty=format: 2>/dev/null \
        | grep -v '^$' | sort -u)
    [ -z "$files" ] && return 1
    printf '%s\n' "$files"
    return 0
}

# Thin compatibility wrapper for the full-PR case (single exclude:
# origin/<default-branch>).
compute_pr_authored_files() {
    local repo_dir="$1" default_branch="$2"
    compute_authored_files "$repo_dir" "HEAD" "origin/${default_branch}"
}

# build_authored_diff <repo_dir> <head_ref> <exclude_ref> [<exclude_ref>...]
#   stdout: unified diff restricted to files compute_authored_files
#           returns. The diff itself is `git diff <first-exclude>...<head>`
#           (three-dot, matches GitHub's view) — the file restriction is
#           what scopes it back down to what the PR actually wrote.
#   exit:   0 on non-empty diff. 1 if no authored files OR diff was
#           empty despite some — caller decides fallback (typically
#           the unfiltered raw diff, or `gh pr diff`).
build_authored_diff() {
    local repo_dir="$1" head_ref="$2" first_exclude="$3"
    local authored diff_out
    authored=$(compute_authored_files "$@") || return 1
    diff_out=$(printf '%s\n' "$authored" \
        | (cd "$repo_dir" && xargs -d '\n' git diff "${first_exclude}...${head_ref}" --) \
        2>/dev/null)
    [ -z "$diff_out" ] && return 1
    printf '%s' "$diff_out"
    return 0
}
