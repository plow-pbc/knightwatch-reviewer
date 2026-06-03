#!/usr/bin/env bash
# Smoke test for lib/pr-enumerate.sh — covers the matrix:
#   1. ORGS-only owner → one gh api graphql call, JSON aggregated.
#   2. REPOS entry whose owner ∉ ORGS → per-repo gh pr list fallthrough.
#   3. Combined ORGS + manual REPOS → both paths run, results concatenated.
#   4. ORGS = whole-org coverage → an ORG-search repo absent from REPOS is
#      kept (no allowlist filter); 8. a partial org (∉ ORGS) is NOT widened.
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
: > "$STUB_CALL_LOG"
# Fixture key carries `archived:false` — enumerate_open_prs appends it to the
# search query (mirrors org-sync's --no-archived). Exported, so scenarios 3/4
# reuse it.
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
#      without a REPOS entry (ORGS = full coverage, no allowlist filter). Same
#      fixture as scenario 1; REPOS lists only seed, but seed-1password (same
#      org) still appears. This is the drift fix. ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 4 count (whole-org keeps both)" 2 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 4 keeps repo absent from REPOS" "true" \
    "$(echo "$out" | jq 'any(.repository.nameWithOwner == "plow-pbc/seed-1password")')"
)

# ---- scenario 8: a partial org is NOT widened. cncorp is not in ORGS, so it's
#      never org-searched; only the explicit REPOS entry (cncorp/plow) appears
#      via the per-repo fallthrough. ----
: > "$STUB_CALL_LOG"
( REPOS=("cncorp/plow"); ORGS=()
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 8 count" 1 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 8 only the REPOS-listed cncorp repo" "cncorp/plow" \
    "$(echo "$out" | jq -r '.[0].repository.nameWithOwner')"
)

# ---- scenario 9: enumerate_open_prs paginates the review-path search (the
#      data-integrity fix) — a PR that only appears on page 2 is enumerated. ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")
  # First page reports a next page; the stub serves MOCK_GRAPHQL_AFTER for the
  # follow-up (after=) call. Both repos are plow-pbc (an ORGS owner) → kept.
  export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open_archived_false='{"data":{"search":{"pageInfo":{"hasNextPage":true,"endCursor":"E1"},"nodes":[
    {"number":10,"title":"p1","headRefName":"f/1","headRefOid":"o1","author":{"login":"a"},"repository":{"nameWithOwner":"plow-pbc/page1"}}
  ]}}}'
  export MOCK_GRAPHQL_AFTER='{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"number":11,"title":"p2","headRefName":"f/2","headRefOid":"o2","author":{"login":"b"},"repository":{"nameWithOwner":"plow-pbc/page2"}}
  ]}}}'
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 9 enumerates both pages" 2 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 9 page-2 PR present" "true" \
    "$(echo "$out" | jq 'any(.repository.nameWithOwner == "plow-pbc/page2")')"
  assert_eq "scenario 9 made 2 graphql calls" 2 "$(grep -c '^graphql ' "$STUB_CALL_LOG")"
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

# ---- scenario 6: repos_with_bot_activity_since (batched bake-off discovery) ----
# 6a: single ORG, search returns active repos (with a dup) → deduped.
: > "$STUB_CALL_LOG"
S6_SINCE="2026-05-01T00:00:00Z"
s6q="user:plow-pbc is:pr commenter:testbot updated:>=$S6_SINCE archived:false"
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

# 6b: whole-org discovery — an ORGS owner's bot-active repo absent from REPOS
#     is still returned (no allowlist filter; ORGS = full coverage). Discovery
#     counterpart of scenario 4.
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")   # seed-1password not in REPOS but same org → kept
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(repos_with_bot_activity_since "$S6_SINCE" "testbot")
  assert_eq "6b whole-org returns repo absent from REPOS" \
    $'plow-pbc/seed\nplow-pbc/seed-1password' "$(echo "$out" | sort)"
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
s6dq="user:plow-pbc is:pr commenter:testbot updated:>=$S6D_SINCE archived:false"
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
#     → exit 0 with empty stdout, even under the callers' `set -o pipefail`.
#     Guards the grep-`-v '^$'`-matches-nothing-exits-1 trap that would
#     otherwise abort the command substitution before `return 0`.
: > "$STUB_CALL_LOG"
( set -o pipefail
  REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")   # no MOCK fixture for this query → stub returns []
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  if out=$(repos_with_bot_activity_since "2030-01-01T00:00:00Z" "nobody"); then
      assert_eq "6e empty discovery → empty stdout, exit 0" "" "$out"
  else
      echo "FAIL: 6e empty discovery exited non-zero under pipefail (grep-no-match trap)"; exit 1
  fi
)

# 7-union: union_with_repos — the shared walk-set seam — merges discovered
# repos with the REPOS allowlist, deduped and sorted, dropping blanks.
( REPOS=("cncorp/plow" "plow-pbc/seed")
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(printf '%s\n' "plow-pbc/seed" "plow-pbc/new-active" "" | union_with_repos)
  assert_eq "union_with_repos merges + dedups + sorts" \
    $'cncorp/plow\nplow-pbc/new-active\nplow-pbc/seed' "$out"
)

echo "ALL PASS: pr-enumerate-smoke.sh"
