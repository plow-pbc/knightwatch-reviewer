#!/usr/bin/env bash
# Smoke test for lib/pr-enumerate.sh — covers the matrix:
#   1. ORGS-only owner → one gh api graphql call, JSON aggregated.
#   2. REPOS entry whose owner ∉ ORGS → per-repo gh pr list fallthrough.
#   3. Combined ORGS + manual REPOS → both paths run, results concatenated.
#   4. ORG search returns a repo NOT in ${REPOS[@]} → post-filter drops it.
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
    q=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "-F" ]; then
            j=$((i+1))
            case "${!j}" in q=*) q="${!j#q=}" ;; esac
        fi
    done
    echo "graphql q=$q" >> "$STUB_CALL_LOG"
    [ -n "${MOCK_GRAPHQL_FAIL:-}" ] && exit 1
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
export MOCK_GRAPHQL_user_plow_pbc_is_pr_is_open='{"data":{"search":{"nodes":[
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

# ---- scenario 4: ORG search returns untracked repo → post-filter drops it ----
: > "$STUB_CALL_LOG"
( REPOS=("plow-pbc/seed"); ORGS=("plow-pbc")   # seed-1password NOT in REPOS → drop
  source "$PROJECT_ROOT/lib/pr-enumerate.sh"
  out=$(enumerate_open_prs)
  assert_eq "scenario 4 count after filter" 1 "$(echo "$out" | jq 'length')"
  assert_eq "scenario 4 surviving repo" "plow-pbc/seed" "$(echo "$out" | jq -r '.[0].repository.nameWithOwner')"
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

echo "ALL PASS: pr-enumerate-smoke.sh"
