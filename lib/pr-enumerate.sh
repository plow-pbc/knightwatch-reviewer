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
#       author per PR.
#   For each entry in REPOS whose owner is NOT in ORGS:
#       gh pr list --repo OWNER/NAME --json … — fallthrough for
#       partially-tracked owners (today: cncorp/plow, cncorp/plow-content).
#   Concatenates results, post-filters against ${REPOS[@]} so a batched
#   ORG search can't surface a repo we don't actually track (e.g. one
#   removed from repos.conf.auto between org-sync ticks, or an archived
#   repo whose pruning hasn't propagated yet).
#
# On success: prints one JSON array on stdout (possibly empty), exits 0.
# Output shape per element:
#   {"repository":{"nameWithOwner":"owner/name"},
#    "number":N, "title":"…", "headRefName":"…", "headRefOid":"…",
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

_enumerate_graphql_query='query($q: String!) {
  search(query: $q, type: ISSUE, first: 100) {
    nodes {
      ... on PullRequest {
        number title headRefName headRefOid
        author { login }
        repository { nameWithOwner }
      }
    }
  }
}'

_enumerate_owner_in_orgs() {
    local owner="$1" o
    for o in "${ORGS[@]}"; do
        [ "$o" = "$owner" ] && return 0
    done
    return 1
}

enumerate_open_prs() {
    local pieces=() owner repo raw nodes
    declare -A _seen_owners=()

    # 1. ORGS-batched path: one graphql call per fully-tracked owner.
    for owner in "${ORGS[@]}"; do
        [ -n "${_seen_owners[$owner]:-}" ] && continue
        _seen_owners[$owner]=1
        if ! raw=$(gh api graphql \
                -F q="user:${owner} is:pr is:open" \
                -f query="$_enumerate_graphql_query" 2>/dev/null); then
            return 1
        fi
        nodes=$(printf '%s' "$raw" | jq -c '.data.search.nodes // []') || return 1
        pieces+=("$nodes")
    done

    # 2. Per-repo fallthrough for manual entries in non-ORGS namespaces.
    for repo in "${REPOS[@]}"; do
        owner="${repo%%/*}"
        _enumerate_owner_in_orgs "$owner" && continue
        if ! raw=$(gh pr list --repo "$repo" \
                --json number,title,headRefName,headRefOid,author \
                --state open --limit 200 2>/dev/null); then
            return 1
        fi
        # gh pr list omits the repository field — re-inject it so the
        # output shape matches the graphql branch.
        nodes=$(printf '%s' "$raw" | jq -c --arg r "$repo" \
            'map(. + {repository: {nameWithOwner: $r}})') || return 1
        pieces+=("$nodes")
    done

    # 3. Concat all pieces, post-filter against ${REPOS[@]} so an ORG
    #    search can't surface an untracked repo.
    local tracked_json
    tracked_json=$(printf '%s\n' "${REPOS[@]}" | jq -R . | jq -s .)
    if [ ${#pieces[@]} -eq 0 ]; then
        echo "[]"
        return 0
    fi
    printf '%s\n' "${pieces[@]}" | jq -s --argjson tracked "$tracked_json" \
        'add // [] | map(select(.repository.nameWithOwner as $r | $tracked | index($r)))'
}
