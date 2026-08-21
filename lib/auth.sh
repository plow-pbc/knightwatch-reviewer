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
# treat 2 as falsy → fail closed. Two callers branch on 2 explicitly, in
# opposite directions, and both are deliberate: review.sh DEFERS (an
# unverifiable lookup must not drop a trusted author's PR), while
# review-one-pr.sh's execution gate fails CLOSED (it only grants capability,
# and the read is already authorized by the requester gate upstream).
#
# Reuses gh_api_retry: it bounded-retries 5xx/network but intentionally NOT
# 403 — exactly the "transient couldn't-verify vs definitive" split here.
_AUTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_AUTH_LIB_DIR/gh-retry.sh"  # defines gh() — the rate-limit seam

# is_bot_account LOGIN → 0 when the login is a bot/automation account.
#
# One owner for a policy three authorization-adjacent paths consult: the
# no-push-access notice (review.sh) must not address a bot that cannot act on
# it, and the approve/memorize pollers must not honour a command from one. The
# three had drifted into separate copies of the same case pattern.
is_bot_account() {
    case "$1" in
        *"[bot]"|"Copilot"|"copilot") return 0 ;;
        *) return 1 ;;
    esac
}

# The verdict logic, unchanged and extracted so the cache wrapper below stays
# thin and the tri-state contract keeps exactly one owner.
_trust_probe() {
    local repo="$1" user="$2"
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

# A (repo,user) role is near-static, but this ran UNCACHED once per PR per tick
# per container — the one call that tripped GitHub's SECONDARY limit fleet-wide
# (#233: every attributed trip in orchestrator.log was this endpoint, while
# core sat at 4997/5000, which is why "primary looks fine" kept hiding it).
#
# The TTL is minutes, not hours, because it bounds how long a REVOKED
# collaborator keeps a trusted verdict — and a trusted verdict is what lets
# `just test` execute PR-supplied code. Even at 15 minutes this turns ~480
# lookups/hour/PR into 4.
is_trusted_repo_author() {
    local repo="$1" user="$2"
    [ -z "$user" ] && return 1
    local ttl="${GH_TRUST_CACHE_TTL_SECS:-900}" file key now entry stamp cached rc
    file=$(trust_cache_file); key="$repo|$user"; now=$(date +%s)
    entry=$(seen_get "$file" "$key" 2>/dev/null || true)
    if [ -n "$entry" ]; then
        stamp="${entry%%:*}"; cached="${entry##*:}"
        # A malformed entry (torn write, format change) falls through to a live
        # probe rather than aborting on arithmetic against a non-number.
        case "$stamp$cached" in
            ''|*[!0-9]*) ;;
            *) [ "$(( now - stamp ))" -lt "$ttl" ] && return "$cached" ;;
        esac
    fi
    _trust_probe "$repo" "$user"; rc=$?
    # DEFINITIVE verdicts only. rc=2 means "the API did not answer" — caching it
    # would freeze a non-answer for the whole TTL and make a throttled lookup
    # read as settled, which is the exact failure this cache exists to end.
    [ "$rc" -ne 2 ] && seen_set_value "$file" "$key" "$now:$rc"
    return "$rc"
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
