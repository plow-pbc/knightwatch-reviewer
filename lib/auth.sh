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
#
# TRI-STATE by exit code (the 2>/dev/null swallow used to make a 403
# rate-limit indistinguishable from "untrusted", silently skipping a
# genuinely-trusted author while throttled):
#   0 — trusted        : clean 200 + a push role (admin/write/maintain)
#   1 — untrusted      : DEFINITIVELY not — clean 200 + non-push role, or a
#                        404 non-collaborator (also: empty user)
#   2 — indeterminate  : couldn't verify — 403/5xx/network, or any non-zero
#                        gh exit that isn't a clean "not a collaborator"
# Callers that only branch trusted/untrusted (`if is_trusted_repo_author`)
# treat 2 as falsy → fail closed; the container gate in review-one-pr.sh
# branches on 2 explicitly to DEFER (retry next tick) instead of mislabeling.
#
# Reuses gh_api_retry: it bounded-retries 5xx/network but intentionally NOT
# 403 — exactly the "transient couldn't-verify vs definitive" split here.
_AUTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_AUTH_LIB_DIR/gh-retry.sh"  # defines gh() — the rate-limit seam

is_trusted_repo_author() {
    local repo="$1" user="$2"
    [ -z "$user" ] && return 1
    local perm err rc errfile
    # Capture stdout (role), stderr (gh's error text), and the real exit code
    # separately — no 2>/dev/null, so a 403/5xx is a non-zero rc we can read,
    # not an empty body masquerading as untrusted. gh_api_retry routes gh's
    # error text to stderr, so the 404 marker lives in $err on the fail path.
    errfile=$(mktemp)
    perm=$(gh api "repos/$repo/collaborators/$user/permission" --jq '.permission' 2>"$errfile"); rc=$?
    err=$(cat "$errfile"); rm -f "$errfile"
    if [ "$rc" -ne 0 ]; then
        # Non-zero gh exit. A genuine non-collaborator returns 404 with a
        # "Not Found"/HTTP 404 message → DEFINITIVELY untrusted. Any other
        # failure (403 rate-limit, 5xx, network) → indeterminate, defer.
        case "$err" in
            *"HTTP 404"*|*"Not Found"*) return 1 ;;
        esac
        return 2
    fi
    # Clean 200. A push role is trusted; any other role is definitively not.
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
    # Via the wrapper: an approve is a content-creating write, so a throttled one
    # must stamp the pause like every other. The create-verb guard covers
    # `pr review` too, so it is never retried into a duplicate approval.
    if gh pr review "$pr_num" --repo "$repo" --approve --body "$body" 2>&1 >/dev/null; then
        log "Approved $repo#$pr_num ($body)"
        return 0
    fi
    log "$repo#$pr_num: gh pr review --approve FAILED — see journal; not marking approved"
    return 1
}
