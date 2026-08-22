#!/usr/bin/env bash
# Author-trust gating. Trust is "has push access" — `admin`, `write`, or
# `maintain` from the collaborators API. Two entry points, split by what the
# caller does with the answer:
#
#   is_trusted_repo_author_live — ACTING gates. The caller is about to take an
#     irreversible action on the strength of the verdict: mirror canonical
#     `.env*` into a workdir that then runs PR-supplied `just test`; stage a
#     comment's verbatim prose for the codex pipeline (started with
#     --dangerously-bypass-approvals-and-sandbox); submit a GitHub approval;
#     apply a rule to the shared corpus. These fire long after the dispatcher
#     ran, so a cached verdict answers "did they have access THEN", not "may
#     this happen NOW".
#
#   is_trusted_repo_author — ENUMERATION only. The caller is deciding whether a
#     PR is worth looking at, and the acting gate behind it re-checks live. One
#     uncached call per PR per tick per container is what tripped GitHub's
#     secondary limit (#233) — the whole reason the cache exists.
#
# Deliberately NOT a list of call sites. Three consecutive review rounds found
# this header's hand-maintained enumerations stale — the enumeration was the
# defect, not any one instance of it. RT8 in
# lib/tests/orchestrator-skip-smoke.sh is the enumerable source of truth: it is
# executable and fails when a gate moves.
#
# TRI-STATE by exit code (the 2>/dev/null swallow used to make a 403
# rate-limit indistinguishable from "untrusted", silently skipping a
# genuinely-trusted author while throttled):
#   0 — trusted        : clean 200 + a push role (admin/write/maintain)
#   1 — untrusted      : DEFINITIVELY not — clean 200 + non-push role, or a
#                        404 non-collaborator (also: empty user)
#   2 — indeterminate  : couldn't verify — 403/5xx/network, or any non-zero
#                        gh exit that isn't a clean "not a collaborator"
# Callers that only branch trusted/untrusted treat 2 as falsy → fail closed.
# rc=2 is never a verdict, so a caller that branches on it explicitly picks one
# of three dispositions — DEFER (an unverifiable lookup must not drop a trusted
# author's PR), fail CLOSED (an execution gate only grants capability), or leave
# the item unseen to retry — and says which at its own call site. Not listed
# here, for the reason given above.
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

# The LIVE admission check — one API call, never cached. Every caller about to
# ACT on trust uses this: mirroring canonical .env* into a workdir, executing
# PR-supplied `just test`, submitting an approval. The worker runs up to ~40 min
# behind the dispatcher that warmed the cache (reviews serialize on a per-repo
# test lock), so a collaborator revoked inside that window would otherwise still
# clear the gate that runs their code. One owner for the tri-state contract.
is_trusted_repo_author_live() {
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

# Cached wrapper for the ENUMERATION path only. One uncached call per PR per
# tick per container is what tripped GitHub's secondary limit (#233); this
# decides "enqueue this PR", never "run this code" — every acting caller goes
# through is_trusted_repo_author_live above, so a stale verdict here costs at
# most one wasted dispatch that the worker's live check then rejects.
#
# Caches rc=0 ONLY. A cached rc=1 is worse than no cache: poll-pr-actions.sh
# marks a rejected /approve PERMANENTLY seen, so a collaborator promoted after
# one negative lookup would have their approvals silently dropped forever. And
# rc=2 is not a verdict at all — freezing "the API did not answer" would make a
# throttled lookup read as settled, the exact failure this cache exists to end.
# Storing just the timestamp follows: a present, fresh entry means trusted.
is_trusted_repo_author() {
    local repo="$1" user="$2"
    [ -z "$user" ] && return 1
    # 15 minutes, fixed — not an operator knob. It bounds how long a REVOKED
    # collaborator keeps a cached trusted verdict on the enumeration path, and a
    # configurable version would carry a mode (0) that restores the very hot
    # lookup this cache exists to remove.
    local ttl=900 file key now entry rc
    file=$(trust_cache_file); key="$repo|$user"; now=$(date +%s)
    entry=$(seen_get "$file" "$key" 2>/dev/null || true)
    # A malformed entry (torn write, format change) falls through to a live
    # probe rather than aborting on arithmetic against a non-number.
    case "$entry" in
        ''|*[!0-9]*) ;;
        *) [ "$(( now - entry ))" -lt "$ttl" ] && return 0 ;;
    esac
    is_trusted_repo_author_live "$repo" "$user"; rc=$?
    [ "$rc" -eq 0 ] && seen_set_value "$file" "$key" "$now"
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
