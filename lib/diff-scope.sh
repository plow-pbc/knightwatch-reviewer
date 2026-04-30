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
#   stdout: concatenated per-commit patches for non-merge commits in
#           `<head_ref> ^<exclude_ref>...`, in chronological order.
#   exit:   0 on non-empty diff. 1 if no non-merge commits remain after
#           exclusions — caller decides fallback (typically `gh pr diff`
#           when local history is too shallow to trust the empty result,
#           or fail-closed when history is fine but the branch genuinely
#           has zero authored content).
#
# Per-commit patches, not a refspec range diff. The earlier impl filtered
# the three-dot range diff by filename; that worked for the full-PR case
# (`origin/main...HEAD` advances merge-base past the merged-in main
# commits) but leaked main-side hunks on incremental review when the
# range was `prior_sha...HEAD`: `prior_sha` is on the branch, so the
# merge-base doesn't advance, and any same-file edit main contributed
# between `prior_sha` and `HEAD` would slip through alongside the
# branch's own edits. Walking commits directly is structurally immune
# — main's commits are simply not in the walk.
build_authored_diff() {
    local repo_dir="$1" head_ref="$2"
    shift 2
    local exclude_args=()
    local ref
    for ref in "$@"; do
        exclude_args+=("^${ref}")
    done
    local shas
    shas=$(git -C "$repo_dir" log --no-merges --reverse --pretty=format:%H \
        "$head_ref" "${exclude_args[@]}" 2>/dev/null)
    [ -z "$shas" ] && return 1
    # --literal-pathspecs is defensive: this code path doesn't pass any
    # paths to git (per-commit show, no `-- <paths>`), but a future
    # tweak that adds path filtering would otherwise be vulnerable to
    # PR-controlled filenames being parsed as pathspec magic.
    local sha out=""
    while IFS= read -r sha; do
        out+="$(git -C "$repo_dir" --literal-pathspecs show \
            --no-color --pretty=format: "$sha" 2>/dev/null)"
        out+=$'\n'
    done <<< "$shas"
    [ -z "$out" ] && return 1
    printf '%s' "$out"
    return 0
}

# has_traceable_history <repo_dir> <ref_a> <ref_b>
#   Returns 0 if `git merge-base <ref_a> <ref_b>` succeeds, 1 otherwise.
#   Callers use this to distinguish "branch genuinely has no authored
#   content" (fail closed) from "shallow clone can't compute the range"
#   (legitimate fallback to gh pr diff).
has_traceable_history() {
    git -C "$1" merge-base "$2" "$3" >/dev/null 2>&1
}
