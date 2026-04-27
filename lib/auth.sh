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
