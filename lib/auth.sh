#!/bin/bash
# Author-trust gating. Two callers in this codebase grant trust to GitHub
# usernames who can ride into the review pipeline:
#
#   1. lib/review-one-pr.sh mirrors canonical's gitignored `.env*` files
#      into the per-PR workdir before `just test` runs. Untrusted PR
#      authors can otherwise modify a `just test` recipe to read those
#      live API keys.
#   2. review.sh stages the latest matching comment as
#      `.codex-scratch/trigger-comment.md`. Intent inference and the
#      aggregator weight that prose heavily on a pipeline that ends in
#      `gh pr review --approve`, so untrusted commenters can otherwise
#      shape the review.
#
# Both gates call `is_trusted_repo_author REPO USER`. Trust is "has push
# access" — `admin`, `write`, or `maintain` from the collaborators API.
# Anything else (including 404 / non-collaborator) is untrusted.

is_trusted_repo_author() {
    local repo="$1" user="$2"
    [ -z "$user" ] && return 1
    local perm
    perm=$(gh api "repos/$repo/collaborators/$user/permission" --jq '.permission' 2>/dev/null)
    case "$perm" in
        admin|write|maintain) return 0 ;;
        *) return 1 ;;
    esac
}

# is_pr_author REPO PR_NUM USER — true (exit 0) iff $USER is the GitHub
# account that opened PR_NUM in REPO. Used by lib/review-one-pr.sh's
# auto-approve gate to skip approving the bot's own PRs (GitHub rejects
# with "Can not approve your own pull request").
#
# A 404 / API error returns 1 (treat as "not the author" — the
# subsequent gh pr review call will then fail loud with a real diagnostic
# instead of silently degrading to "skip").
is_pr_author() {
    local repo="$1" pr_num="$2" user="$3"
    [ -z "$user" ] && return 1
    local author
    author=$(gh pr view "$pr_num" --repo "$repo" --json author --jq '.author.login' 2>/dev/null)
    [ "$author" = "$user" ]
}
