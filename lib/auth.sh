#!/usr/bin/env bash
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

# just_test_skip_reason JUST_FILE IS_TRUSTED → echoes why `just test` must NOT
# run (empty string = run it). Pure: takes precomputed inputs, no gh calls.
#
# `just test` executes PR-controlled recipes + test code. An untrusted author
# (no push access) must never have their code run — it would execute with the
# reviewer's home-dir read access (~/.ssh, the gh PAT) and network. This holds
# on EVERY path, not just the container/dind one; the host/systemd path used to
# run untrusted tests (without canonical secrets), which still exposed those
# credentials to exfiltration. Trusted authors with a justfile run as before.
just_test_skip_reason() {
    local just_file="$1" is_trusted="$2"
    if [ -z "$just_file" ]; then
        echo "no justfile in repo root"
    elif [ "$is_trusted" != true ]; then
        echo "untrusted author (no push access) — PR code is not executed"
    fi
}

# submit_approval REPO PR_NUM BOT_USER PR_AUTHOR APPROVE_BODY — wraps the
# full auto-approve flow that lib/review-one-pr.sh used to inline:
#   - If PR_AUTHOR == BOT_USER, skip the API call (GitHub rejects
#     self-approval with "Can not approve your own pull request"; the
#     resulting GraphQL noise pollutes the journal). Returns 1.
#   - Else call `gh pr review --approve`. Returns 0 on success, 1 on
#     failure. Failures are logged loud instead of being swallowed by
#     the prior `||`-suppressed call (which used to leave the caller
#     setting APPROVED=true unconditionally).
#
# PR_AUTHOR is passed in (not refetched) so this re-uses the value the
# worker already fetched once at the top of review-one-pr.sh.
submit_approval() {
    local repo="$1" pr_num="$2" bot_user="$3" pr_author="$4" body="$5"
    if [ "$pr_author" = "$bot_user" ]; then
        log "Skipping approve on $repo#$pr_num — PR authored by $bot_user (GitHub forbids self-approval)"
        return 1
    fi
    if gh pr review "$pr_num" --repo "$repo" --approve --body "$body" 2>&1 >/dev/null; then
        log "Approved $repo#$pr_num ($body)"
        return 0
    fi
    log "$repo#$pr_num: gh pr review --approve FAILED — see journal; not marking approved"
    return 1
}
