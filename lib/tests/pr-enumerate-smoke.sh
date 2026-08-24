#!/usr/bin/env bash
# Smoke test for lib/pr-enumerate.sh — covers the matrix:
#   1. ORGS-only owner → one gh api graphql call, JSON aggregated.
#   2. REPOS entry whose owner ∉ ORGS → per-repo gh pr list fallthrough.
#   3. Combined ORGS + manual REPOS → both paths run, results concatenated.
#   4. ORGS = whole-org coverage → an ORG-search repo absent from REPOS is
#      kept (no allowlist filter).
#   5. gh failure on either path → enumerate_open_prs exits non-zero, no stdout.
#
# Stub gh via PATH precedence — same pattern as gh-comments-smoke.sh and
# re-request-poller-smoke.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR=$(mktemp -d -t pr-enumerate-smoke-XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

export HOME="$WORKDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

STUB_CALL_LOG="$WORKDIR/gh-calls.log"
export STUB_CALL_LOG

# Stub gh. Two surfaces:
#   gh api graphql -F q=<query> -f query=<gql>  → echo per-owner fixture
#   gh pr list --repo <REPO> --json …           → echo per-repo fixture
# Both surfaces log to $STUB_CALL_LOG so the test can assert call counts.
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    q=""; after=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "-F" ]; then
            j=$((i+1))
            case "${!j}" in
                q=*)     q="${!j#q=}" ;;
                after=*) after="${!j#after=}" ;;
            esac
        fi
    done
    echo "graphql q=$q after=$after" >> "$STUB_CALL_LOG"
    # Record the GraphQL DOCUMENT too, not just the search string. Fixtures are
    # echoed verbatim, so an assertion on the RESPONSE proves nothing about what
    # was REQUESTED — drop a field from the query and production loses it while
    # the fixture keeps the test green. Scenario 7 asserts against this file.
    if [ -n "${STUB_QUERY_LOG:-}" ]; then
        for ((i=1; i<=$#; i++)); do
            if [ "${!i}" = "-f" ]; then
                j=$((i+1))
                case "${!j}" in query=*) printf '%s\n' "${!j#query=}" >> "$STUB_QUERY_LOG" ;; esac
            fi
        done
    fi
    [ -n "${MOCK_GRAPHQL_FAIL:-}" ] && exit 1
    # Pagination: a follow-up call (after set) serves MOCK_GRAPHQL_AFTER (page 2).
    if [ -n "$after" ] && [ -n "${MOCK_GRAPHQL_AFTER:-}" ]; then
        echo "$MOCK_GRAPHQL_AFTER"
        exit 0
    fi
    fixture_var="MOCK_GRAPHQL_${q//[^A-Za-z0-9]/_}"
    eval "fixture=\${$fixture_var:-}"
    if [ -n "$fixture" ]; then
        echo "$fixture"
    else
        echo '{"data":{"search":{"nodes":[]}}}'
    fi
elif [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    repo=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--repo" ]; then j=$((i+1)); repo="${!j}"; fi
    done
    echo "pr_list repo=$repo" >> "$STUB_CALL_LOG"
    [ -n "${MOCK_PR_LIST_FAIL:-}" ] && exit 1
    fixture_var="MOCK_PR_LIST_${repo//[^A-Za-z0-9]/_}"
    eval "fixture=\${$fixture_var:-[]}"
    echo "$fixture"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected='$expected' actual='$actual'"
        exit 1
    fi
    echo "OK: $name"
}

# Each scenario runs in a subshell so REPOS/ORGS/exported MOCK_* vars
# don't leak across scenarios.

# ---- scenario 1: single ORG, two PRs returned ----
# Fixture key carries `archived:false` — enumerate appends it to the search
# query (mirrors org-sync's --no-archived). Exported, scenarios 3/4 reuse it.
: > "$STUB_CALL_LOG"
export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open_archived_false='{"data":{"search":{"nodes":[
    {"number":1,"title":"a","headRefName":"feat/a","headRefOid":"aaa","author":{"login":"alice"},"repository":{"nameWithOwner":"plow-pbc/seed"}},
    {"number":2,"title":"b","headRefName":"feat/b","headRefOid":"bbb","author":{"login":"bob"},"repository":{"nameWithOwner":"plow-pbc/seed-1password"}}
]}}}'
( REPOS=("plow-pbc/seed" "plow-pbc/seed-1password"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 1 count" 2 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 1 graphql calls" 1 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
  assert_eq "scenario 1 pr_list calls" 0 "$(grep -c '^pr_list ' "$STUB_CALL_LOG")"
)

# ---- scenario 2: REPOS entry whose owner ∉ ORGS → per-repo fallthrough ----
: > "$STUB_CALL_LOG"
export MOCK_PR_LIST_cncorp_plow='[{"number":642,"title":"x","headRefName":"feat/x","headRefOid":"xxx","author":{"login":"srosro"}}]'
( REPOS=("cncorp/plow"); ORGS=()
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 2 count" 1 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 2 repo field" "cncorp/plow" "$(echo "$out" | jq -r '.[0].repository.nameWithOwner')"
  assert_eq "scenario 2 graphql calls" 0 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
  assert_eq "scenario 2 pr_list calls" 1 "$(grep -c '^pr_list ' "$STUB_CALL_LOG")"
)

# ---- scenario 3: combined ORG + manual ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed" "plow-pbc/seed-1password" "cncorp/plow"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 3 count" 3 "$(echo "$out" | jq 'length')"
)

# ---- scenario 4: whole-org coverage — an ORGS owner's repo is kept even
#      without a REPOS entry (no allowlist filter). Same fixture as scenario 1;
#      REPOS lists only seed, but seed-1password (same org) still appears. ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 4 count (whole-org keeps both)" 2 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 4 keeps repo absent from REPOS" "true" \
    "$(echo "$out" | jq 'any(.repository.nameWithOwner == "plow-pbc/seed-1password")')"
)

# ---- scenario 4b: enumerate paginates the org search — a PR only on page 2 is
#      still enumerated (data-integrity: a >100-PR owner must not miss page 2). ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open_archived_false='{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"E1"},"nodes":[
    {"number":10,"title":"p1","headRefName":"f/1","headRefOid":"o1","author":{"login":"a"},"repository":{"nameWithOwner":"plow-pbc/page1"}}
  ]}}}'
  export MOCK_GRAPHQL_AFTER='{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"number":11,"title":"p2","headRefName":"f/2","headRefOid":"o2","author":{"login":"b"},"repository":{"nameWithOwner":"plow-pbc/page2"}}
  ]}}}'
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 4b enumerates both pages" 2 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 4b page-2 PR present" "true" \
    "$(echo "$out" | jq 'any(.repository.nameWithOwner == "plow-pbc/page2")')"
  assert_eq "scenario 4b made 2 graphql calls" 2 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
  # The 2nd call must carry the EXACT endCursor from page 1 (E1), not just any
  # non-empty after — proves the cursor is plumbed through, not faked.
  assert_eq "scenario 4b 2nd call uses page-1 endCursor" 1 "$(grep -c 'after=E1' "$STUB_CALL_LOG")"
)

# ---- scenario 5a: gh graphql failure → non-zero, no stdout ----
: > "$STUB_CALL_LOG"
export MOCK_GRAPHQL_FAIL=1
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  if out=$(enumerate_open_prs 2>/dev/null); then
      echo "FAIL: scenario 5a expected non-zero exit"; exit 1
  fi
  assert_eq "scenario 5a no stdout on fail" "" "$out"
)
unset MOCK_GRAPHQL_FAIL

# ---- scenario 5b: gh pr list failure → non-zero, no stdout ----
: > "$STUB_CALL_LOG"
export MOCK_PR_LIST_FAIL=1
( REPOS=("cncorp/plow"); ORGS=()
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  if out=$(enumerate_open_prs 2>/dev/null); then
      echo "FAIL: scenario 5b expected non-zero exit"; exit 1
  fi
  assert_eq "scenario 5b no stdout on fail" "" "$out"
)
# Unset like its MOCK_GRAPHQL_FAIL sibling above. Exported and left set, it made
# `gh pr list` fail for the REST of the file — invisible only because no later
# scenario used the fallthrough path until one did, and it then failed with no
# assertion message (the subshell dies on `set -e` inside the command
# substitution, before any assert runs).
unset MOCK_PR_LIST_FAIL

# ---- scenario 6: repos_with_bot_activity_since (batched bake-off discovery) ----
# 6a: single ORG, search returns active repos (with a dup) → deduped, tracked-only.
: > "$STUB_CALL_LOG"
S6_SINCE="2026-05-01T00:00:00Z"
s6q="user:plow-pbc is:pr commenter:testbot updated:>=$S6_SINCE"
export "MOCK_GRAPHQL_${s6q//[^A-Za-z0-9]/_}"='{"data":{"search":{"nodes":[
    {"repository":{"nameWithOwner":"plow-pbc/seed"}},
    {"repository":{"nameWithOwner":"plow-pbc/seed"}},
    {"repository":{"nameWithOwner":"plow-pbc/seed-1password"}}
]}}}'
( REPOS=("plow-pbc/seed" "plow-pbc/seed-1password"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(repos_with_bot_activity_since "$S6_SINCE" "testbot")
  assert_eq "6a active repos (deduped)" $'plow-pbc/seed\nplow-pbc/seed-1password' "$(echo "$out" | sort)"
  assert_eq "6a graphql calls" 1 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
)

# 6b: search surfaces an untracked repo → post-filter drops it.
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")   # seed-1password not tracked → drop
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(repos_with_bot_activity_since "$S6_SINCE" "testbot")
  assert_eq "6b drops untracked" "plow-pbc/seed" "$out"
)

# 6c: graphql failure → non-zero, no stdout (caller picks its own failure
#     policy; specialist-bakeoff.sh fails loud rather than walking all).
: > "$STUB_CALL_LOG"
export MOCK_GRAPHQL_FAIL=1
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  if out=$(repos_with_bot_activity_since "$S6_SINCE" "testbot" 2>/dev/null); then
      echo "FAIL: 6c expected non-zero exit"; exit 1
  fi
  assert_eq "6c no stdout on fail" "" "$out"
)
unset MOCK_GRAPHQL_FAIL

# 6d: pages past first:100 — a repo whose only match is on page 2 is still found.
: > "$STUB_CALL_LOG"
S6D_SINCE="2026-05-02T00:00:00Z"
s6dq="user:plow-pbc is:pr commenter:testbot updated:>=$S6D_SINCE"
export "MOCK_GRAPHQL_${s6dq//[^A-Za-z0-9]/_}"='{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[{"repository":{"nameWithOwner":"plow-pbc/page1repo"}}]}}}'
export MOCK_GRAPHQL_AFTER='{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"repository":{"nameWithOwner":"plow-pbc/page2repo"}}]}}}'
( REPOS=("plow-pbc/page1repo" "plow-pbc/page2repo"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(repos_with_bot_activity_since "$S6D_SINCE" "testbot")
  assert_eq "6d paginates both pages" $'plow-pbc/page1repo\nplow-pbc/page2repo' "$(echo "$out" | sort)"
  assert_eq "6d made 2 graphql calls" 2 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
)
unset MOCK_GRAPHQL_AFTER

# 6e: empty discovery (search returns zero nodes — quiet window / fresh deploy)
#     → exit 0 with empty stdout, even under the callers' `set -o pipefail`
#     (specialist-bakeoff.sh's `active_list=$(…)`). Load-bearing: an accidental
#     non-zero return there aborts the run as a false PARTIAL.
: > "$STUB_CALL_LOG"
( set -o pipefail
  REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")   # no MOCK fixture for this query → stub returns []
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  if out=$(repos_with_bot_activity_since "2030-01-01T00:00:00Z" "nobody"); then
      assert_eq "6e empty discovery → empty stdout, exit 0" "" "$out"
  else
      echo "FAIL: 6e empty discovery exited non-zero under pipefail"; exit 1
  fi
)

# ---- scenario 7: the GraphQL path carries the poller's inputs; the per-repo
#      fallthrough does not (that is how poll-pr-actions.sh picks its path).
#      Why these fields live here: the poller was fetching issues/N/comments +
#      issues/N/timeline per PR per tick — ~150 REST calls across 75 open PRs,
#      every 2 minutes, 90s of continuous request rate out of every 120s, which
#      is what tripped GitHub's SECONDARY (burst) limit hourly. One batched
#      search already walks every PR; carrying the two fields on it drops that
#      fan-out to zero. ----
: > "$STUB_CALL_LOG"
export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open_archived_false='{"data":{"search":{"nodes":[
    {"number":1,"title":"a","headRefName":"feat/a","headRefOid":"aaa","author":{"login":"alice"},"repository":{"nameWithOwner":"plow-pbc/seed"},
     "comments":{"nodes":[{"databaseId":9001,"createdAt":"2026-08-24T16:40:40Z","body":"/srosro-approve","author":{"login":"carol"}}]},
     "timelineItems":{"nodes":[
        {"createdAt":"2026-08-24T16:39:02Z","requestedReviewer":{"login":"srosro"}},
        {"createdAt":"2026-08-24T16:41:00Z","requestedReviewer":{}}
     ]}}
]}}}'
export STUB_QUERY_LOG="$WORKDIR/gh-queries.log"
: > "$STUB_QUERY_LOG"
export MOCK_PR_LIST_cncorp_plow='[{"number":642,"title":"x","headRefName":"feat/x","headRefOid":"xxx","author":{"login":"srosro"}}]'
( REPOS=("plow-pbc/seed" "cncorp/plow"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs --with-poller-inputs)
  # The QUERY must actually ask for both fields. Without these two, the response
  # assertions below pass on fixture data alone and would not notice the query
  # losing the fields — which is the only way this change can regress.
  assert_eq "scenario 7 query requests comments" "true" \
    "$(grep -q 'comments(last:' "$STUB_QUERY_LOG" && echo true || echo false)"
  assert_eq "scenario 7 query requests review-request events" "true" \
    "$(grep -q 'REVIEW_REQUESTED_EVENT' "$STUB_QUERY_LOG" && echo true || echo false)"
  assert_eq "scenario 7 comment databaseId carried" "9001" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes[0].databaseId')"
  assert_eq "scenario 7 comment body carried" "/srosro-approve" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes[0].body')"
  assert_eq "scenario 7 comment author carried" "carol" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes[0].author.login')"
  # timelineItems is flattened to reviewRequests so no consumer reaches through
  # the GraphQL union shape, and a non-User reviewer (a TEAM request has no
  # .login) is dropped rather than surfacing as a null-login entry.
  assert_eq "scenario 7 review request flattened to one User entry" "1" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .reviewRequests.nodes | length')"
  assert_eq "scenario 7 review request login" "srosro" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .reviewRequests.nodes[0].login')"
  assert_eq "scenario 7 review request createdAt" "2026-08-24T16:39:02Z" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .reviewRequests.nodes[0].createdAt')"
  assert_eq "scenario 7 raw timelineItems removed" "null" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .timelineItems // "null"')"
  # The fallthrough PR must carry NEITHER field — its absence is the signal that
  # sends poll-pr-actions.sh back to the REST helpers for that PR.
  assert_eq "scenario 7 fallthrough has no batched comments" "null" \
    "$(echo "$out" | jq -r '.[] | select(.number==642) | .comments // "null"')"
  assert_eq "scenario 7 fallthrough has no batched reviewRequests" "null" \
    "$(echo "$out" | jq -r '.[] | select(.number==642) | .reviewRequests // "null"')"
)

# ---- scenario 8: the DEFAULT call stays lean. review.sh enumerates every 60s
#      and reads none of the poller fields; measured against the live org the
#      enriched response is 2.7 MB against 22 KB lean (the comment bodies are
#      knightwatch's own multi-KB reviews), so making them unconditional would
#      hand that path a multi-MB response to hold in a shell variable and re-pipe
#      through jq. This is the fence that keeps them opt-in. ----
: > "$STUB_CALL_LOG"; : > "$STUB_QUERY_LOG"
( REPOS=("plow-pbc/seed" "cncorp/plow"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 8 lean query omits comments" "false" \
    "$(grep -q 'comments(last:' "$STUB_QUERY_LOG" && echo true || echo false)"
  assert_eq "scenario 8 lean query omits review-request events" "false" \
    "$(grep -q 'REVIEW_REQUESTED_EVENT' "$STUB_QUERY_LOG" && echo true || echo false)"
  # And the lean path must NOT bolt an empty reviewRequests onto every PR —
  # field ABSENCE is what tells poll-pr-actions.sh a PR needs the REST fallback,
  # so an empty-but-present list would silently route every PR down the batched
  # path with no data.
  assert_eq "scenario 8 lean path adds no reviewRequests key" "null" \
    "$(echo "$out" | jq -r '.[0].reviewRequests // "null"')"
  assert_eq "scenario 8 still enumerates normally" "2" "$(echo "$out" | jq 'length')"
)

# ---- scenario 8b: a Bot comment author is normalized to the REST spelling, and
#      a TRUNCATED thread drops .comments so the PR routes to the REST fallback.
#      GraphQL resolves an App author through the Bot type, whose login omits the
#      [bot] suffix (verified live: `vercel`, not `vercel[bot]`) while
#      is_bot_account matches `*[bot]` — unnormalized, a bot-authored approve
#      slips the bot fence. And 100 is GitHub's connection maximum, so a longer
#      thread cannot be fetched by widening; it must fail over, not truncate. ----
: > "$STUB_CALL_LOG"; : > "$STUB_QUERY_LOG"
export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open_archived_false='{"data":{"search":{"nodes":[
    {"number":1,"title":"a","headRefName":"f","headRefOid":"h","author":{"login":"alice"},"repository":{"nameWithOwner":"plow-pbc/seed"},
     "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[
        {"databaseId":11,"createdAt":"t","body":"b","author":{"__typename":"Bot","login":"vercel"}},
        {"databaseId":12,"createdAt":"t","body":"b","author":{"__typename":"User","login":"alice"}}]},
     "timelineItems":{"nodes":[]}},
    {"number":2,"title":"b","headRefName":"f","headRefOid":"h","author":{"login":"bob"},"repository":{"nameWithOwner":"plow-pbc/seed-1password"},
     "comments":{"pageInfo":{"hasPreviousPage":true},"nodes":[
        {"databaseId":21,"createdAt":"t","body":"b","author":{"__typename":"User","login":"bob"}}]},
     "timelineItems":{"nodes":[]}}
]}}}'
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs --with-poller-inputs)
  assert_eq "scenario 8b query asks for the truncation signal" "true" \
    "$(grep -q 'hasPreviousPage' "$STUB_QUERY_LOG" && echo true || echo false)"
  # The fixture hardcodes "__typename":"Bot", so without this the normalization
  # assert below is mutation-vacuous: narrowing the query back to
  # `author { login }` — a plausible "trim the unused field" edit, since
  # __typename has no consumer outside one jq comparison — would leave
  # .author.__typename null in real responses, the Bot branch would never fire,
  # and the suite would stay green while bot-authored approves slip the fence.
  assert_eq "scenario 8b query asks for the author type" "true" \
    "$(grep -q '__typename' "$STUB_QUERY_LOG" && echo true || echo false)"
  assert_eq "scenario 8b Bot login gets the REST [bot] suffix" "vercel[bot]" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes[0].author.login')"
  assert_eq "scenario 8b User login is left alone" "alice" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes[1].author.login')"
  # Truncated thread: .comments removed entirely, so the documented
  # field-absence contract sends that PR to fetch_issue_comments.
  assert_eq "scenario 8b truncated thread drops comments" "null" \
    "$(echo "$out" | jq -r '.[] | select(.number==2) | .comments // "null"')"
  # …but only that PR — an untruncated sibling keeps its batched comments.
  assert_eq "scenario 8b untruncated sibling keeps comments" "2" \
    "$(echo "$out" | jq -r '.[] | select(.number==1) | .comments.nodes | length')"
)

# ---- scenario 9: an unrecognized argument fails LOUD rather than going lean.
#      Silently falling back to the lean query would read to poll-pr-actions.sh
#      as "every PR needs the REST helpers" — restoring the ~150-calls-per-tick
#      fan-out with nothing in the log, detectable only via GitHub's
#      secondary-limit pauses hours later. ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  rc=0
  out=$(enumerate_open_prs --with-poller-input 2>"$WORKDIR/err9") || rc=$?
  # Exit code 2 specifically, not just non-zero: poll-pr-actions.sh treats every
  # non-zero the same ("enumerate_open_prs failed — skipping this tick"), so
  # without the diagnostic a permanent misconfiguration is indistinguishable
  # from a transient gh outage and the poller stops approving forever while the
  # log reads as retryable. The LOUD half is the headline behavior here.
  assert_eq "scenario 9 exit code is 2 (misconfig, not transient failure)" "2" "$rc"
  assert_eq "scenario 9 no stdout on bad arg" "" "$out"
  assert_eq "scenario 9 names the bad argument" "true" \
    "$(grep -q "unrecognized arguments" "$WORKDIR/err9" && echo true || echo false)"
  assert_eq "scenario 9 echoes the offending token" "true" \
    "$(grep -q -- "--with-poller-input" "$WORKDIR/err9" && echo true || echo false)"
  assert_eq "scenario 9 made no graphql call" 0 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
)

# 9b: arity, not emptiness — an empty arg ahead of the flag, and a trailing
#     typo, both used to fall through to lean with exit 0.
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  rc=0; enumerate_open_prs "" --with-poller-inputs >/dev/null 2>&1 || rc=$?
  assert_eq "scenario 9b empty arg ahead of the flag is rejected" "2" "$rc"
  rc=0; enumerate_open_prs --with-poller-inputs --typo >/dev/null 2>&1 || rc=$?
  assert_eq "scenario 9b trailing typo is rejected" "2" "$rc"
)

# 9c: the diagnostic honours the diag fd, like gh-rate-limit-smoke scenario 19.
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  exec {GH_DIAG_FD}>"$WORKDIR/diag9"
  export GH_DIAG_FD
  enumerate_open_prs --nope >/dev/null 2>"$WORKDIR/err9c" || true
  assert_eq "scenario 9c diagnostic reaches the diag fd" "true" \
    "$(grep -q "unrecognized arguments" "$WORKDIR/diag9" && echo true || echo false)"
)

echo "ALL PASS: pr-enumerate-smoke.sh"
