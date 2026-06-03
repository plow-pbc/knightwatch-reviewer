#!/usr/bin/env bash
# Sourceable helper for enumerating open PRs across all tracked repos in
# one batched pass per owner instead of one gh pr list per repo.
#
# Pre-conditions: caller has already sourced lib/tracked-repos.sh, so
# REPOS=(…) and ORGS=(…) are in scope.
#
# enumerate_open_prs
#   For each owner in ORGS:
#       gh api graphql search(user:OWNER is:pr is:open) — one call per
#       owner, returns repository/number/title/headRefName/headRefOid/
#       updatedAt/author per PR.
#   For each entry in REPOS whose owner is NOT in ORGS:
#       gh pr list --repo OWNER/NAME --json … — fallthrough for
#       partially-tracked owners (today: cncorp/plow).
#   Concatenates results with NO post-filter: ORGS owners are reviewed in
#   FULL (every result is wanted), and the per-repo path only fetches the
#   explicit non-ORGS REPOS entries — so nothing untracked is ever fetched.
#
# On success: prints one JSON array on stdout (possibly empty), exits 0.
# Output shape per element:
#   {"repository":{"nameWithOwner":"owner/name"},
#    "number":N, "title":"…", "headRefName":"…", "headRefOid":"…", "updatedAt":"…",
#    "author":{"login":"…"}}
# On any underlying gh failure: exits non-zero, prints nothing — mirrors
# fetch_issue_comments' contract so callers stay on the existing
# `|| { log; continue; }` short-circuit.
#
# Why this exists: each tick of the high-frequency pollers (review.sh,
# re-request-poller.sh, approve-from-replies.sh) was doing 41× `gh pr
# list --json` = 164 GraphQL points/tick — combined ~19,800 pts/hr
# against GitHub's 5000/hr per-user GraphQL quota, causing recurring
# exhaustion (cncorp/plow#642's "review aborted before completion" was
# one instance). The ORG-batched search collapses the 39 plow-pbc +
# srosro repos into 1 call per owner (~3 pts each), keeping cncorp/* on
# per-repo because those orgs are only partially tracked.

_enumerate_graphql_query='query($q: String!, $after: String) {
  search(query: $q, type: ISSUE, first: 100, after: $after) {
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title headRefName headRefOid updatedAt
        author { login }
        repository { nameWithOwner }
      }
    }
  }
}'

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

    # 1. ORGS-batched path: paginated graphql search per ORGS owner. ORGS are
    #    reviewed in FULL, so one batched search per owner per tick covers the
    #    whole org — it does NOT fan out per-repo (that would scale gh-quota
    #    cost with org size on every poll). Paged (not just first:100) because
    #    whole-org coverage of a >100-open-PR owner would otherwise miss page 2.
    #    archived:false mirrors org-sync's `gh repo list --no-archived`: never
    #    review an archived repo's stale open PRs (read-only; nothing to do).
    #    It mirrors only HALF of org-sync's filter — there's no `--source`
    #    equivalent, so an open PR on an org-owned FORK is in scope here even
    #    though org-sync wouldn't clone it. Intended ("every open PR in the
    #    org") and harmless at our operating point (source orgs, no forks with
    #    open PRs); `fork:false` is NOT the fix — it's a repo/code-search
    #    qualifier the issues index free-texts, which zeroes the results.
    #    Residual cap (unaddressed): GitHub's search connection returns at most
    #    1000 results total regardless of cursoring, so an org with >1000 open
    #    PRs would still truncate. Far beyond the current operating point (tens
    #    per org); noted so "never miss page 2" isn't read as "never miss any".
    local after
    for owner in "${ORGS[@]}"; do
        [ -n "${_seen_owners[$owner]:-}" ] && continue
        _seen_owners[$owner]=1
        after=""
        while :; do
            if [ -n "$after" ]; then
                raw=$(gh api graphql -F q="user:${owner} is:pr is:open archived:false" \
                        -F after="$after" -f query="$_enumerate_graphql_query" 2>/dev/null) || return 1
            else
                raw=$(gh api graphql -F q="user:${owner} is:pr is:open archived:false" \
                        -f query="$_enumerate_graphql_query" 2>/dev/null) || return 1
            fi
            nodes=$(printf '%s' "$raw" | jq -c '.data.search.nodes // []') || return 1
            pieces+=("$nodes")
            # endCursor only when there is a next page (else empty → stop). A
            # malformed hasNextPage-without-cursor stops too, not loop forever.
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
# Prints (newline-separated, deduped) the ORGS-owned repos that have a PR the
# bot commented on and that was updated since SINCE_ISO — a paginated gh api
# graphql search per ORGS owner. ORGS owners are reviewed in full, so every
# discovered repo is wanted (no allowlist filter). Non-ORGS owners (e.g.
# cncorp/*) are NOT searched; callers union these with REPOS (union_with_repos).
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
    # Source gh_api_retry here, not at file scope, so only this discovery path
    # carries the dependency — enumerate_open_prs callers stay unburdened.
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-retry.sh"
    local since="$1" bot="$2" owner q raw after pieces=()
    declare -A _seen_owners=()
    for owner in "${ORGS[@]}"; do
        [ -n "${_seen_owners[$owner]:-}" ] && continue
        _seen_owners[$owner]=1
        q="user:${owner} is:pr commenter:${bot} updated:>=${since} archived:false"
        after=""
        while :; do
            if [ -n "$after" ]; then
                raw=$(gh_api_retry graphql -F q="$q" -F after="$after" -f query="$_bot_activity_graphql_query" 2>/dev/null) || return 1
            else
                raw=$(gh_api_retry graphql -F q="$q" -f query="$_bot_activity_graphql_query" 2>/dev/null) || return 1
            fi
            pieces+=("$(printf '%s' "$raw" | jq -r '.data.search.nodes[]?.repository.nameWithOwner')") || return 1
            # endCursor only when there is a next page (else empty → stop). A
            # malformed hasNextPage-without-cursor stops too, not loop forever.
            after=$(printf '%s' "$raw" | jq -r '.data.search.pageInfo // {} | if .hasNextPage then (.endCursor // empty) else empty end') || return 1
            [ -n "$after" ] || break
        done
    done
    if [ ${#pieces[@]} -eq 0 ]; then return 0; fi
    # Every searched owner is in ORGS (reviewed in full), so all discovered
    # repos are wanted — just dedupe and emit. Callers union with REPOS.
    #
    # `|| true` is load-bearing: on empty discovery (a common, expected
    # outcome — quiet window, fresh deploy) every page appends "" to pieces,
    # so the count guard above doesn't fire, and `grep -v '^$'` then matches
    # nothing and exits 1. Under the callers' `set -euo pipefail`
    # (specialist-bakeoff.sh, learn-from-replies.sh) that 1 would abort the
    # command-substitution subshell BEFORE the explicit `return 0`, making a
    # successful empty discovery look like an API failure. Absorb it so the
    # documented "prints possibly-empty set, exits 0" contract holds.
    printf '%s\n' "${pieces[@]}" | grep -v '^$' | sort -u || true
    return 0
}

# union_with_repos — read discovered repo slugs on stdin and print the
# sorted-unique union with the static REPOS allowlist. The one shared
# "tracked-target expansion" seam for per-repo bot-activity walks: both
# calibration consumers (learn-from-replies, specialist-bakeoff) feed it the
# repos_with_bot_activity_since result so each walks REPOS plus the ORGS repos
# discovered as active — the same universe the review path reviews.
union_with_repos() {
    { printf '%s\n' "${REPOS[@]}"; cat; } | grep -v '^$' | sort -u
}
