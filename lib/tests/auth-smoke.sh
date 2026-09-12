#!/usr/bin/env bash
# Smoke test for lib/auth.sh — covers is_trusted_repo_author and
# submit_approval. Stubs `gh` so the real GitHub API is never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t auth-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# log() comes from lib/state-io.sh; submit_approval calls it. Set
# LOG_FILE to a tmp path so we can assert which log line fired per
# scenario (the helper writes the same line via tee in production).
export LOG_FILE="$TMPDIR/log"
. "$PROJECT_ROOT/lib/state-io.sh"

# `gh` stub for two endpoints:
#   gh api repos/<repo>/collaborators/<user>/permission --jq .permission
#       → echoes "write" if user ∈ MOCK_TRUSTED_USERS, else "none"
#   gh pr review <num> --repo <repo> --approve --body <body>
#       → records the call, exits 0 unless MOCK_GH_REVIEW_FAILS=1
GH_REVIEW_LOG="$TMPDIR/gh-review.log"
export GH_REVIEW_LOG
GH_API_LOG="$TMPDIR/gh-api.log"
export GH_API_LOG
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ]; then
    endpoint=""
    for arg in "$@"; do
        case "$arg" in repos/*) endpoint="$arg" ;; esac
    done
    if [[ "$endpoint" == */collaborators/*/permission ]]; then
        echo "API $endpoint" >> "$GH_API_LOG"
        # MOCK_PERM_MODE drives the tri-state matrix below. Mirrors how real
        # `gh api` behaves per outcome: stdout = role (200), stderr + non-zero
        # exit = API error. gh_api_retry passes both through to the caller.
        case "${MOCK_PERM_MODE:-role}" in
            403) echo "gh: HTTP 403: API rate limit exceeded" >&2; exit 1 ;;
            # The OTHER 403, verbatim as gh emits it: GitHub refuses this
            # endpoint to a caller without push on the repo, for every subject.
            # Definitive, not transient — the pair of 403 rows is the contract.
            403-structural) echo "gh: Must have push access to view collaborator permission. (HTTP 403)" >&2; exit 1 ;;
            5xx) echo "gh: HTTP 503: Service Unavailable" >&2; exit 1 ;;
            empty) exit 1 ;;  # non-zero exit, no stdout/stderr (network drop)
            404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
            *) echo "${MOCK_PERM_ROLE:-none}" ;;  # clean 200 + role
        esac
    else
        echo "{}"
    fi
elif [ "$1" = "pr" ] && [ "$2" = "review" ]; then
    echo "REVIEW $*" >> "$GH_REVIEW_LOG"
    if [ -n "${MOCK_GH_REVIEW_FAILS:-}" ]; then
        echo "gh: server error" >&2
        exit 1
    fi
    exit 0
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Source the helpers under test.
. "$PROJECT_ROOT/lib/auth.sh"

reset_state() {
    : > "$LOG_FILE"
    : > "$GH_REVIEW_LOG"
}

# --- is_trusted_repo_author: tri-state by exit code ---
#   0 = trusted (clean 200 + push role)
#   1 = definitively untrusted (clean 200 + non-push role, OR a 404)
#   2 = unverifiable, RETRYABLE (rate-limit 403 / 5xx / network — defer, never
#       mislabel as untrusted)
#   3 = unverifiable, PERMANENT (structural 403 — this token cannot query the
#       repo's collaborators at all, so deferring would never terminate)
# Parametrized matrix: "label|MODE|ROLE|expected_rc" (no padding — fields are
# split on the bare delimiter). MODE drives the gh stub above.
# GH_API_RETRY_MAX=1 keeps the 5xx case from sleeping/retrying.
# Each scenario models an independent moment, so stop-state must not leak: the
# 403 stubs above are worded as rate limits and correctly stamp the shared pause,
# which would then short-circuit gh_retry for every later scenario.
reset_gh_pause() { rm -f "$(gh_pause_file)"; }
reset_trust_cache() { rm -f "$(trust_cache_file)" "$(trust_cache_file).lock"; }

reset_gh_pause; reset_trust_cache
echo "  scenario 1: is_trusted_repo_author tri-state matrix..."
TRUST_MATRIX=(
    "clean-200 admin|role|admin|0"
    "clean-200 write|role|write|0"
    "clean-200 maintain|role|maintain|0"
    "clean-200 read (none)|role|none|1"
    "clean-200 read (read)|role|read|1"
    "404 non-collaborator|404||1"
    "403 rate-limit (transient)|403||2"
    "403 structural (caller lacks push)|403-structural||3"
    "5xx server error|5xx||2"
    "empty (network drop)|empty||2"
)
for row in "${TRUST_MATRIX[@]}"; do
    IFS='|' read -r label mode role want <<<"$row"
    # Every row reuses cncorp/plow+someuser, so a live cache would answer rows
    # 2..n from row 1's verdict and the matrix would stop testing the stub.
    # The PAUSE is the same hazard from the other side: the 403 rate-limit row
    # stamps a fleet pause, after which gh_retry short-circuits with an EMPTY
    # errfile and every later row returns rc=2 without reaching its stub. The
    # rows that follow it all wanted 2, so they passed for the wrong reason and
    # the gap stayed invisible until a row below wanted something else.
    reset_gh_pause; reset_trust_cache
    set +e
    GH_API_RETRY_MAX=1 MOCK_PERM_MODE="$mode" MOCK_PERM_ROLE="$role" \
        is_trusted_repo_author "cncorp/plow" "someuser"
    got=$?
    set -e
    [ "$got" = "$want" ] || { echo "FAIL scenario 1 [$label]: expected rc=$want, got rc=$got"; exit 1; }
done

reset_gh_pause; reset_trust_cache
echo "  scenario 2: indeterminate (403) must NOT be trusted — security invariant..."
# The load-bearing invariant: an indeterminate result must defer, never grant
# trust. rc must be 2 (caller defers), and crucially NOT 0 (would run untrusted code).
set +e
GH_API_RETRY_MAX=1 MOCK_PERM_MODE=403 is_trusted_repo_author "cncorp/plow" "srosro"
got=$?
set -e
[ "$got" = 2 ] || { echo "FAIL scenario 2: indeterminate must yield rc=2 (defer), got rc=$got"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 3: is_trusted_repo_author returns false for empty user..."
is_trusted_repo_author "cncorp/plow" "" && { echo "FAIL scenario 3: empty user should not be trusted"; exit 1; } || true

# --- submit_approval ---
reset_gh_pause; reset_trust_cache
echo "  scenario 4: submit_approval skips the API call when bot is the PR author..."
reset_state
submit_approval "cncorp/plow" "100" "srosro" "srosro" "Approving per automated review above." && { echo "FAIL scenario 4: expected return 1 on self-author"; exit 1; } || true
[ ! -s "$GH_REVIEW_LOG" ] || { echo "FAIL scenario 4: gh pr review was called when bot is the PR author"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "Skipping approve on cncorp/plow#100 — PR authored by srosro" "$LOG_FILE" || { echo "FAIL scenario 4: expected 'Skipping approve' log line"; cat "$LOG_FILE"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 5: submit_approval calls gh pr review --approve and returns 0 on success..."
reset_state
submit_approval "cncorp/plow" "100" "srosro" "delattre1" "Approving per automated review above." || { echo "FAIL scenario 5: expected return 0 on successful approve"; cat "$LOG_FILE"; exit 1; }
[ "$(grep -c '^REVIEW' "$GH_REVIEW_LOG")" = "1" ] || { echo "FAIL scenario 5: expected exactly 1 gh pr review call, got $(grep -c '^REVIEW' "$GH_REVIEW_LOG" 2>/dev/null || echo 0)"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "Approved cncorp/plow#100" "$LOG_FILE" || { echo "FAIL scenario 5: expected 'Approved' log line"; cat "$LOG_FILE"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 6: submit_approval logs failure and returns 1 when gh pr review --approve fails..."
reset_state
MOCK_GH_REVIEW_FAILS=1 submit_approval "cncorp/plow" "100" "srosro" "delattre1" "Approving per automated review above." && { echo "FAIL scenario 6: expected return 1 on gh failure"; exit 1; } || true
[ "$(grep -c '^REVIEW' "$GH_REVIEW_LOG")" = "1" ] || { echo "FAIL scenario 6: expected exactly 1 gh pr review call (the failed attempt)"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "gh pr review --approve FAILED" "$LOG_FILE" || { echo "FAIL scenario 6: expected 'FAILED' log line"; cat "$LOG_FILE"; exit 1; }

# --- just_test_skip_reason ---
# `just test` executes PR-controlled code; untrusted authors (no push access)
# must never have their code run — on ANY path, not only container/dind mode.
reset_gh_pause; reset_trust_cache
echo "  scenario 7: just_test_skip_reason runs (empty reason) for a trusted author with a justfile..."
reason=$(just_test_skip_reason "/repo/justfile" true)
[ -z "$reason" ] || { echo "FAIL scenario 7: trusted author with justfile should run (empty reason), got: $reason"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 8: just_test_skip_reason skips untrusted authors regardless of mode..."
reason=$(just_test_skip_reason "/repo/justfile" false)
[ -n "$reason" ] || { echo "FAIL scenario 8: untrusted author should be skipped"; exit 1; }
printf '%s' "$reason" | grep -qi "untrusted" || { echo "FAIL scenario 8: skip reason should name the untrusted author, got: $reason"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 9: just_test_skip_reason skips when there is no justfile..."
reason=$(just_test_skip_reason "" true)
[ -n "$reason" ] || { echo "FAIL scenario 9: missing justfile should skip"; exit 1; }
printf '%s' "$reason" | grep -qi "justfile" || { echo "FAIL scenario 9: skip reason should name the missing justfile, got: $reason"; exit 1; }


# --- is_trusted_repo_author caching (#233) ---
# The lookup was uncached at one live API call per PR per tick per container,
# which is what tripped GitHub's secondary limit fleet-wide. These fence the
# cache AND the invariant that makes it safe.
reset_gh_pause; reset_trust_cache
echo "  scenario 10: a definitive verdict is cached — the second lookup makes no API call..."
: > "$GH_API_LOG"
MOCK_PERM_MODE=role MOCK_PERM_ROLE=write is_trusted_repo_author "cncorp/plow" "cacheduser" \
    || { echo "FAIL scenario 10: expected trusted"; exit 1; }
MOCK_PERM_MODE=role MOCK_PERM_ROLE=write is_trusted_repo_author "cncorp/plow" "cacheduser" \
    || { echo "FAIL scenario 10: cached lookup should still be trusted"; exit 1; }
[ "$(grep -c '^API' "$GH_API_LOG")" = "1" ] \
    || { echo "FAIL scenario 10: expected 1 API call across 2 lookups, got $(grep -c '^API' "$GH_API_LOG")"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 11: a NON-trusted verdict is never cached — one table, both kinds..."
# Only rc=0 is stored. rc=2 is not a verdict at all (freezing "the API did not
# answer" would make a throttled lookup read as settled), and a cached rc=1 is
# worse than no cache: poll-pr-actions.sh marks a rejected /approve PERMANENTLY
# seen, so one negative lookup would drop a promoted collaborator's approvals
# forever. Both rows: probe, then re-probe as trusted and require it to take.
# Columns: label|MOCK_PERM_MODE|MOCK_PERM_ROLE|expected rc|login
UNCACHED_MATRIX=(
    "indeterminate-403|403||2|flaky"
    "untrusted|role|none|1|promoted"
)
for row in "${UNCACHED_MATRIX[@]}"; do
    IFS='|' read -r label mode role want user <<<"$row"
    reset_gh_pause; reset_trust_cache; : > "$GH_API_LOG"
    set +e
    GH_API_RETRY_MAX=1 MOCK_PERM_MODE="$mode" MOCK_PERM_ROLE="$role" \
        is_trusted_repo_author "cncorp/plow" "$user"
    got=$?
    set -e
    [ "$got" = "$want" ] || { echo "FAIL scenario 11 [$label]: expected rc=$want, got rc=$got"; exit 1; }
    reset_gh_pause
    MOCK_PERM_MODE=role MOCK_PERM_ROLE=write is_trusted_repo_author "cncorp/plow" "$user" \
        || { echo "FAIL scenario 11 [$label]: the non-trusted verdict was cached and survived a re-probe"; exit 1; }
    [ "$(grep -c '^API' "$GH_API_LOG")" = "2" ] \
        || { echo "FAIL scenario 11 [$label]: expected 2 API calls (nothing cached), got $(grep -c '^API' "$GH_API_LOG")"; exit 1; }
done

reset_gh_pause; reset_trust_cache
echo "  scenario 12: the LIVE admission check never reads the cache..."
# The worker mirrors credentials and executes PR code up to ~40 min after the
# dispatcher warmed the cache. Serving that gate from cache would let a
# collaborator revoked inside the window still run code, so the live entry point
# must probe every time — proven by warming a trusted verdict, then making the
# API say otherwise and requiring the live call to see it.
: > "$GH_API_LOG"
MOCK_PERM_MODE=role MOCK_PERM_ROLE=write is_trusted_repo_author "cncorp/plow" "revoked" \
    || { echo "FAIL scenario 12: expected the warm-up lookup to be trusted"; exit 1; }
MOCK_PERM_MODE=404 is_trusted_repo_author_live "cncorp/plow" "revoked" \
    && { echo "FAIL scenario 12: the live check served a cached verdict — a revoked collaborator would still execute code"; exit 1; } || true
[ "$(grep -c '^API' "$GH_API_LOG")" = "2" ] \
    || { echo "FAIL scenario 12: the live check did not hit the API, got $(grep -c '^API' "$GH_API_LOG") call(s)"; exit 1; }
# ...and the cached wrapper still answers from cache, so the volume fix stands.
MOCK_PERM_MODE=404 is_trusted_repo_author "cncorp/plow" "revoked" \
    || { echo "FAIL scenario 12: the cached wrapper stopped caching — the per-tick storm returns"; exit 1; }
[ "$(grep -c '^API' "$GH_API_LOG")" = "2" ] \
    || { echo "FAIL scenario 12: the cached wrapper made an extra API call"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 13: an EXPIRED entry re-probes — the TTL is the only bound on a revoked verdict..."
# Every other scenario drives a FRESH entry, so deleting the age comparison
# outright left all of them green — and an unbounded cache is a permanent
# trusted verdict, not a degraded one. Seed a stale entry directly (it is a bare
# timestamp in a store the suite already owns) rather than reintroducing a knob.
: > "$GH_API_LOG"
seen_set_value "$(trust_cache_file)" "cncorp/plow|stale" "$(( $(date +%s) - 1000 ))"
MOCK_PERM_MODE=404 is_trusted_repo_author "cncorp/plow" "stale" \
    && { echo "FAIL scenario 13: a 1000s-old entry was served — the TTL bound is gone, so a revoked verdict never expires"; exit 1; } || true
[ "$(grep -c '^API' "$GH_API_LOG")" = "1" ] \
    || { echo "FAIL scenario 13: an expired entry did not re-probe, got $(grep -c '^API' "$GH_API_LOG") API call(s)"; exit 1; }
# ...and a fresh entry still serves, so the volume fix is intact.
: > "$GH_API_LOG"
seen_set_value "$(trust_cache_file)" "cncorp/plow|fresh" "$(date +%s)"
MOCK_PERM_MODE=404 is_trusted_repo_author "cncorp/plow" "fresh" \
    || { echo "FAIL scenario 13: a fresh entry was not served — the per-tick storm returns"; exit 1; }
[ "$(grep -c '^API' "$GH_API_LOG")" = "0" ] \
    || { echo "FAIL scenario 13: a fresh entry still hit the API"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 14: the cache is keyed per (repo,user) — no cross-talk..."
: > "$GH_API_LOG"
MOCK_PERM_MODE=role MOCK_PERM_ROLE=write is_trusted_repo_author "cncorp/plow" "alice" \
    || { echo "FAIL scenario 14: alice should be trusted"; exit 1; }
MOCK_PERM_MODE=role MOCK_PERM_ROLE=none is_trusted_repo_author "cncorp/plow" "mallory" \
    && { echo "FAIL scenario 14: mallory must NOT inherit alice's cached verdict"; exit 1; } || true
MOCK_PERM_MODE=role MOCK_PERM_ROLE=none is_trusted_repo_author "othercorp/plow" "alice" \
    && { echo "FAIL scenario 14: alice's verdict must not cross repos"; exit 1; } || true

reset_gh_pause; reset_trust_cache
echo "  scenario 15: is_allowlisted_author — manifest standing vouch matrix..."
# Reads config already in memory, so it is binary, not tri-state, and must cost
# no API call at all: the ALLOWLIST_MATRIX asserts the verdict, the API-log
# assertion after it is what keeps this a config read rather than a lookup.
# "repo|login|want_rc" — rc 0 allowlisted, 1 not.
: > "$GH_API_LOG"
declare -A TRUSTED_AUTHORS=(
    ["cncorp"]="octocat  Hubot"
    ["othercorp/plow"]="alice"
)
ALLOWLIST_MATRIX=(
    "owner key covers every repo under it|cncorp/plow|octocat|0"
    "owner key, second repo|cncorp/other|octocat|0"
    "exact repo key|othercorp/plow|alice|0"
    "repo key does not leak to a sibling repo|othercorp/other|alice|1"
    "login case is irrelevant — GitHub logins are|cncorp/plow|OCTOCAT|0"
    "manifest case is irrelevant too|cncorp/plow|hubot|0"
    "a prefix must not match|cncorp/plow|octo|1"
    "a suffix must not match|cncorp/plow|cat|1"
    "non-member|cncorp/plow|mallory|1"
    "empty login|cncorp/plow||1"
    "unlisted owner|elsewhere/plow|octocat|1"
)
for row in "${ALLOWLIST_MATRIX[@]}"; do
    IFS='|' read -r label repo login want <<<"$row"
    set +e
    is_allowlisted_author "$repo" "$login"
    got=$?
    set -e
    [ "$got" = "$want" ] || { echo "FAIL scenario 15 [$label]: expected rc=$want, got rc=$got"; exit 1; }
done
[ "$(grep -c '^API' "$GH_API_LOG")" = "0" ] \
    || { echo "FAIL scenario 15: the allowlist hit the permission API — it must be a pure config read, so an allowlisted author stays reviewable while GitHub throttles"; exit 1; }

reset_gh_pause; reset_trust_cache
echo "  scenario 16: the allowlist grants READING only — it must not reach any capability gate..."
# The security invariant of the whole feature. Every gate below hands out a
# capability (running PR code with mirrored .env; approving; teaching the
# corpus), and each one asks live push access. An allowlisted author with no
# push access must fail all of them, or a config line has become a grant.
MOCK_PERM_MODE=role MOCK_PERM_ROLE=read
export MOCK_PERM_MODE MOCK_PERM_ROLE
is_allowlisted_author "cncorp/plow" "octocat" \
    || { echo "FAIL scenario 16: fixture is wrong — octocat must be allowlisted for this to prove anything"; exit 1; }
set +e
is_trusted_repo_author_live "cncorp/plow" "octocat"; live_rc=$?
is_trusted_repo_author "cncorp/plow" "octocat"; cached_rc=$?
set -e
[ "$live_rc" = 1 ] \
    || { echo "FAIL scenario 16: is_trusted_repo_author_live consulted the allowlist (rc=$live_rc) — this gate mirrors .env and runs PR code"; exit 1; }
[ "$cached_rc" = 1 ] \
    || { echo "FAIL scenario 16: is_trusted_repo_author consulted the allowlist (rc=$cached_rc)"; exit 1; }
# ...and the one gate that consumes that boolean directly still declines.
skip=$(just_test_skip_reason "/tmp/justfile" false)
[ -n "$skip" ] \
    || { echo "FAIL scenario 16: just_test would RUN an allowlisted author's code — the allowlist is reading-only"; exit 1; }
unset MOCK_PERM_MODE MOCK_PERM_ROLE

reset_gh_pause; reset_trust_cache
echo "  scenario 17: an absent manifest array reads as 'nobody is allowlisted', not an error..."
# lib/auth.sh is sourced by consumers that never load the manifest, and an
# UNDECLARED associative name makes ${TRUSTED_AUTHORS[$repo]} an ARITHMETIC
# subscript — under `set -u` that dies on a repo slug instead of defaulting.
unset TRUSTED_AUTHORS
set +e
( set -u; is_allowlisted_author "cncorp/plow" "octocat" )
got=$?
set -e
[ "$got" = 1 ] \
    || { echo "FAIL scenario 17: expected rc=1 with no manifest loaded, got rc=$got (a crash here takes down every review on a manifest-less consumer)"; exit 1; }

echo "  PASS (17 scenarios: trust-tristate-matrix[10 rows: 3×trusted/2×untrusted/404/403-transient/403-structural-permanent/5xx/empty], indeterminate-defers-not-trusted, trust-empty, approval-self-skipped, approval-success, approval-failure-fail-loud, just-test run/untrusted-skip/no-justfile, trust-cache hit/non-trusted-never-cached[403+untrusted]/live-bypasses-cache/expired-re-probes/keyed-per-repo-user, allowlist-matrix[11 rows: owner/repo keys, case, prefix+suffix near-miss, empty]+no-API, allowlist-grants-reading-only, allowlist-absent-manifest)"
