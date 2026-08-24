#!/usr/bin/env bash
# Sourceable helper for enumerating open PRs across all tracked repos in
# one batched pass per owner instead of one gh pr list per repo.
#
# Pre-conditions: caller has already sourced lib/tracked-repos.sh, so
# REPOS=(…) and ORGS=(…) are in scope.
#
# enumerate_open_prs
#   For each owner in ORGS (reviewed in FULL):
#       paginated gh api graphql search(user:OWNER is:pr is:open
#       archived:false) — one batched search per owner per tick (NOT a
#       per-repo fan-out), returns every non-archived open PR.
#   For each entry in REPOS whose owner is NOT in ORGS:
#       gh pr list --repo OWNER/NAME --json … — fallthrough for
#       partially-tracked owners (an owner NOT in ORGS).
#   Concatenates results with NO post-filter: ORGS owners are reviewed in
#   FULL (every result is wanted), and the per-repo path only fetches the
#   explicit non-ORGS REPOS entries — so nothing untracked is ever fetched.
#
# On success: prints one JSON array on stdout (possibly empty), exits 0.
# Output shape per element:
#   {"repository":{"nameWithOwner":"owner/name"},
#    "number":N, "title":"…", "headRefName":"…", "headRefOid":"…", "updatedAt":"…",
#    "author":{"login":"…"}}
#   With --with-poller-inputs, the ORGS/graphql path additionally carries:
#    "comments":{"nodes":[{"databaseId":N,"createdAt":"…","body":"…",
#                          "author":{"login":"…"}}]},
#    "reviewRequests":{"nodes":[{"createdAt":"…","login":"…"}]}
#   databaseId IS the REST comment id, so it drops straight into the seen-key
#   the approve poller already uses.
#
#   The per-repo `gh pr list` fallthrough never carries them, and the reason is
#   SHAPE, not capability: `comments` and `reviewRequests` ARE valid
#   `gh pr list --json` fields, but the wrong ones. Its `comments[].id` is the
#   GraphQL node id, not the REST databaseId the approve seen-key is built from
#   — adding the flag would silently key the seen-store on a different id space
#   and re-approve everything once. And its `reviewRequests` is the CURRENT
#   pending reviewer set with no createdAt, so it cannot drive a watermark that
#   exists to tell a new request from an old one. Their absence is the
#   documented signal that sends poll-pr-actions.sh back to the REST helpers.
# On any underlying gh failure: exits non-zero, prints nothing — mirrors
# fetch_issue_comments' contract so callers stay on the existing
# `|| { log; continue; }` short-circuit.
#
# Why this exists: each tick of the high-frequency pollers (review.sh,
# poll-pr-actions.sh) was doing 41× `gh pr
# list --json` = 164 GraphQL points/tick — combined ~19,800 pts/hr
# against GitHub's 5000/hr per-user GraphQL quota, causing recurring
# exhaustion (plow-pbc/plow#642's "review aborted before completion" was
# one instance). The ORG-batched search collapses the 39 plow-pbc +
# srosro repos into 1 call per owner (~3 pts each), keeping owners not in ORGS on
# per-repo because those orgs are only partially tracked.

# The poller's two per-PR inputs ride along ONLY when asked for. They replace
# two PAGINATED REST calls per PR per tick in poll-pr-actions.sh — ~150 requests
# across 75 open PRs every 2 minutes, which kept that poller on the wire for 90s
# of every 120s. That sustained rate, not any hourly volume, is what tripped
# GitHub's SECONDARY limit hourly (64 of 65 pause events in one day classified
# `secondary`, each logged with core showing 4975+/5000 remaining).
#
# OPT-IN, because the payload is not free even though the points are. Measured
# against the live org: the lean response is 22 KB, the enriched one 2.7 MB — a
# 123x difference, since the comment bodies are knightwatch's own multi-KB
# reviews. review.sh enumerates every 60s and reads NONE of it, and it already
# has an idle-skip whose whole purpose is to avoid per-PR comment fetches; making
# this unconditional would hand that path a multi-MB response to hold in a shell
# variable and re-pipe through jq. The GraphQL point cost is flat at 2 either
# way, so the flag buys the payload back without costing quota.
#
# Both `last:` bounds are 100 and sized from the live org rather than guessed,
# because each replaces an unbounded --paginate and a short window drops a real
# request SILENTLY. The busiest thread carries 67 comments. For timelineItems the
# bound matters more than the measured max of 1 event/PR suggests: it applies to
# ALL review-requested events and the non-User filter runs afterwards in jq, so
# Copilot/team/CODEOWNERS requests occupy slots and could evict the BOT_USER
# request before the filter ever sees it — the consumer would then read an empty
# list and never post the trigger, with nothing in the log to distinguish that
# from "no request". Connection cost is per parent node, not per page size (the
# query costs 2 points at 30, 60 or 100), so the wide window is free insurance
# against a silent drop.
_ENUMERATE_POLLER_FIELDS='
        comments(last: 100) {
          nodes { databaseId createdAt body author { login } }
        }
        timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT]) {
          nodes { ... on ReviewRequestedEvent {
            createdAt requestedReviewer { ... on User { login } } } }
        }'

# _enumerate_graphql_query [EXTRA_PR_FIELDS] — one template, so the lean and
# enriched forms cannot drift apart the way two copies would.
_enumerate_graphql_query() {
    cat <<GQL
query(\$q: String!, \$after: String) {
  search(query: \$q, type: ISSUE, first: 100, after: \$after) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title headRefName headRefOid updatedAt
        author { login }
        repository { nameWithOwner }${1:-}
      }
    }
  }
}
GQL
}

# The rate-limit seam (defines gh()). It was once sourced inside
# repos_with_bot_activity_since alone so enumerate_open_prs stayed unburdened;
# that split ended when enumerate_open_prs also moved onto the wrapper — it is
# the fleet's highest-volume GitHub caller (graphql is the loaded bucket at
# ~30 pts/min vs core ~0), so a rate limit that surfaces here has to trip the
# fleet-wide pause rather than being swallowed as a bare non-zero exit.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-retry.sh"

owner_in_orgs() {
    local owner="$1" o
    for o in "${ORGS[@]}"; do
        [ "$o" = "$owner" ] && return 0
    done
    return 1
}

enumerate_open_prs() {
    local pieces=() owner repo raw nodes
    declare -A _seen_owners=()
    # --with-poller-inputs adds the two heavy per-PR fields (see the block above
    # the query template for why they are opt-in rather than always-on).
    local extra_fields="" query
    # An `if`, not `[ … ] && extra_fields=…`: that form returns 1 on the common
    # (lean) path, which aborts the whole function under a `set -e` caller —
    # lib/replay.sh runs `set -euo pipefail`. Same class as scenario 15 in
    # gh-rate-limit-smoke.
    if [ "${1:-}" = "--with-poller-inputs" ]; then
        extra_fields="$_ENUMERATE_POLLER_FIELDS"
    elif [ -n "${1:-}" ]; then
        # Fail loud on anything else. Silently going lean would be the worst
        # outcome available: the documented consumer contract is "field absence
        # ⇒ REST fallback", so a renamed or mistyped flag reads to the poller as
        # "every PR needs the REST helpers" and restores the ~150-calls-per-tick
        # fan-out this branch exists to remove — indistinguishable in the log
        # from normal operation, and detectable only via GitHub's secondary-limit
        # pauses hours later. Same silent-drop reasoning as the timeline window.
        # NOT this function's stdout — that is the JSON array its callers
        # capture (`ALL_PRS=$(enumerate_open_prs …)`), and scenarios 5a/5b exist
        # to keep diagnostics out of it. Same rule, and same fd, as gh-retry.sh.
        log "enumerate_open_prs: unrecognized argument '$1' (expected --with-poller-inputs)" >&"${GH_DIAG_FD:-2}"
        return 2
    fi
    query=$(_enumerate_graphql_query "$extra_fields")

    # 1. ORGS-batched path: paginated graphql search per ORGS owner. ORGS are
    #    reviewed in FULL, so one batched search per owner per tick covers the
    #    whole org — it does NOT fan out per-repo (that would scale gh-quota
    #    cost with org size on every poll). Paged (not just first:100) because
    #    whole-org coverage of a >100-open-PR owner would otherwise miss page 2;
    #    bounded by GitHub's 1000-result search cap (far past our operating
    #    point). archived:false mirrors org-sync's `--no-archived` (never review
    #    an archived repo's stale PRs); it does NOT mirror `--source`, so an
    #    org-owned fork's PR is in scope — intended/harmless at our operating
    #    point, and `fork:false` is NOT usable (the issues index free-texts it,
    #    zeroing results — verified against the live API).
    local after
    for owner in "${ORGS[@]}"; do
        [ -n "${_seen_owners[$owner]:-}" ] && continue
        _seen_owners[$owner]=1
        after=""
        while :; do
            if [ -n "$after" ]; then
                raw=$(gh api graphql -F q="user:${owner} is:pr is:open archived:false" \
                        -F after="$after" -f query="$query" 2>/dev/null) || return 1
            else
                raw=$(gh api graphql -F q="user:${owner} is:pr is:open archived:false" \
                        -f query="$query" 2>/dev/null) || return 1
            fi
            if [ -n "$extra_fields" ]; then
                # Flatten timelineItems -> reviewRequests so no consumer has to
                # reach through the GraphQL union shape. A request targeting a
                # TEAM (or any non-User reviewer) has no .login and is dropped
                # rather than surfacing as a null-login entry that would never
                # match BOT_USER but would still burden every reader.
                # Only on the enriched path: on the lean one it would bolt an
                # empty reviewRequests onto every PR, erasing the very
                # field-absence that tells poll-pr-actions.sh which PRs need the
                # REST fallback.
                nodes=$(printf '%s' "$raw" | jq -c '[(.data.search.nodes // [])[]
                    | .reviewRequests = {nodes: [((.timelineItems.nodes // [])[]
                        | select(.requestedReviewer.login != null)
                        | {createdAt, login: .requestedReviewer.login})]}
                    | del(.timelineItems)]') || return 1
            else
                nodes=$(printf '%s' "$raw" | jq -c '.data.search.nodes // []') || return 1
            fi
            pieces+=("$nodes")
            after=$(printf '%s' "$raw" | jq -r '.data.search.pageInfo // {} | if .hasNextPage then (.endCursor // empty) else empty end') || return 1
            [ -n "$after" ] || break
        done
    done

    # 2. Per-repo fallthrough for manual entries in non-ORGS namespaces.
    for repo in "${REPOS[@]}"; do
        owner="${repo%%/*}"
        owner_in_orgs "$owner" && continue
        if ! raw=$(gh pr list --repo "$repo" \
                --json number,title,headRefName,headRefOid,updatedAt,author \
                --state open --limit 200 2>/dev/null); then
            return 1
        fi
        # gh pr list omits the repository field — re-inject it so the
        # output shape matches the graphql branch.
        nodes=$(printf '%s' "$raw" | jq -c --arg r "$repo" \
            'map(. + {repository: {nameWithOwner: $r}})') || return 1
        pieces+=("$nodes")
    done

    # 3. Concat all pieces. No post-filter needed: an ORGS owner is reviewed
    #    in FULL (every result is wanted), and the per-repo fallthrough only
    #    fetches explicit REPOS entries — so nothing untracked is ever fetched.
    if [ ${#pieces[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi
    printf '%s\n' "${pieces[@]}" | jq -s 'add // []'
}

_bot_activity_graphql_query='query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { repository { nameWithOwner } } }
  }
}'

# repos_with_bot_activity_since SINCE_ISO BOT_USER
#
# Prints (newline-separated, deduped) the tracked ORG-owned repos that have a
# PR the bot commented on and that was updated since SINCE_ISO — a paginated
# gh api graphql search per ORG owner, vs a per-repo issues/comments fetch for
# every tracked repo. Post-filtered against ${REPOS[@]}. Non-ORG owners are NOT
# searched; callers walk those unconditionally.
#
# Why: specialist-bakeoff.sh fans a paginated comments + collaborators fetch
# across all ~45 tracked repos every run, exhausting the 5000/hr budget
# (HTTP 403) so repos walked last fail. Most of those repos have no bot reviews
# at all; this discovers the active subset in a few calls per owner so the walk
# skips the rest. Same batched-search shape as enumerate_open_prs above. Paged
# (not just first:100) because an org can have >100 matching PRs under a widened
# floor, and a low-activity repo's only match could fall past page 1 — the
# caller would then zero-stamp the repo and permanently skip its reviews.
#
# On success: prints the active repo set (possibly empty), exits 0.
# On any gh failure: exits non-zero, prints nothing. The caller chooses its
# failure policy — specialist-bakeoff.sh fails loud (PARTIAL + exit) rather than
# re-entering the per-repo fan-out this batched path exists to retire.
repos_with_bot_activity_since() {
    local since="$1" bot="$2" owner q raw after pieces=()
    declare -A _seen_owners=() _tracked=()
    for owner in "${ORGS[@]}"; do
        [ -n "${_seen_owners[$owner]:-}" ] && continue
        _seen_owners[$owner]=1
        q="user:${owner} is:pr commenter:${bot} updated:>=${since}"
        after=""
        while :; do
            if [ -n "$after" ]; then
                raw=$(gh api graphql -F q="$q" -F after="$after" -f query="$_bot_activity_graphql_query" 2>/dev/null) || return 1
            else
                raw=$(gh api graphql -F q="$q" -f query="$_bot_activity_graphql_query" 2>/dev/null) || return 1
            fi
            pieces+=("$(printf '%s' "$raw" | jq -r '.data.search.nodes[]?.repository.nameWithOwner')") || return 1
            # endCursor only when there is a next page (else empty → stop). A
            # malformed hasNextPage-without-cursor stops too, not loop forever.
            after=$(printf '%s' "$raw" | jq -r '.data.search.pageInfo // {} | if .hasNextPage then (.endCursor // empty) else empty end') || return 1
            [ -n "$after" ] || break
        done
    done
    if [ ${#pieces[@]} -eq 0 ]; then return 0; fi
    local t r
    for t in "${REPOS[@]}"; do _tracked["$t"]=1; done
    # Process-substitution (not a pipe) so the loop runs in this shell and the
    # function's exit status is the explicit `return 0` below — NOT the loop's
    # last-body status, which is 1 whenever the final repo is untracked (the
    # `[ ] && printf` short-circuits false). A non-zero return here would trip
    # the caller's `set -e` on `out=$(repos_with_bot_activity_since …)`.
    while IFS= read -r r; do
        [ -n "${_tracked[$r]:-}" ] && printf '%s\n' "$r"
    done < <(printf '%s\n' "${pieces[@]}" | grep -v '^$' | sort -u)
    return 0
}
