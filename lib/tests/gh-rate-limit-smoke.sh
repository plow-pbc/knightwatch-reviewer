#!/usr/bin/env bash
# Smoke test for the GitHub rate-limit backoff protocol (lib/state-io.sh +
# lib/gh-retry.sh + review-loop.sh's third tick gate).
#
# Context: the fleet had NO GitHub rate-limit backoff. A rate-limit 403 fell
# through gh_api_retry as an ordinary hard failure, so every container
# re-attempted against the same throttled shared PAT on the next POLL_SECS tick
# — a transient limit became a two-day retry storm (2,179 deferrals on one unit).
#
# The load-bearing behaviors, in the order they matter:
#   1. A rate-limit 403 stamps a pause (it no longer passes silently).
#   2. Primary vs secondary are told apart by live bucket state, not by the 403
#      text — GitHub words both identically. Primary waits for the real reset;
#      secondary (invisible to /rate_limit) waits a short fixed window.
#   3. The pause is FLEET-WIDE, not per-account. One shared PAT means a
#      per-WORKER_ID pause would leave the other containers hammering.
#   4. A non-rate-limit failure must NOT pause — that would take the fleet down
#      on any ordinary 404/422.
#
# Runs in a private tmpdir with a shimmed `gh`; touches no real API and no
# ~/.pr-reviewer.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d -t gh-rate-limit-smoke-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

export STATE_DIR="$TMP/shared"
mkdir -p "$STATE_DIR" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# `gh` shim. GH_SHIM_BUCKETS is the TSV /rate_limit answer; GH_SHIM_ERR is the
# stderr text of the failing call. Any non-rate_limit invocation fails.
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do
    if [ "$a" = "rate_limit" ]; then
        [ -n "${GH_SHIM_BUCKETS:-}" ] || exit 1
        printf '%s\n' "$GH_SHIM_BUCKETS"
        exit 0
    fi
done
printf '%s\n' "${GH_SHIM_ERR:-gh: some other failure (HTTP 404)}" >&2
exit 1
SHIM
chmod +x "$TMP/bin/gh"

. "$PROJECT_ROOT/lib/gh-retry.sh"   # sources state-io.sh itself

RATE_LIMIT_ERR='gh: API rate limit exceeded for user ID 95421. (HTTP 403)'
NOW=$(date +%s)

reset_state() { rm -f "$(gh_pause_file)"; }

# --- 1. secondary: budget remains, yet a rate-limit 403 → short fixed pause ---
# This is the case that actually fired in production: core 4920/5000 and graphql
# 4742/5000 remaining while every call 403'd. /rate_limit cannot see secondary
# limits, so "403 with budget left" IS the secondary signal.
echo "  scenario 1: rate-limit 403 with budget remaining → secondary, short pause..."
reset_state
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
GH_SECONDARY_PAUSE_SECS=60 \
    gh_api_retry "user" >"$TMP/out1" 2>"$TMP/err1" || true
[ -f "$(gh_pause_file)" ] || fail "scenario 1: rate-limit 403 left no pause file — the fleet would keep hammering"
# gh_api_retry's stdout IS the API result its callers capture
# (`perm=$(gh_api_retry …)` in auth.sh) — a diagnostic leaked there would be
# read back as a permission string.
grep -q 'rate limit' "$TMP/out1" 2>/dev/null \
    && fail "scenario 1: the diagnostic leaked to stdout, corrupting the value callers capture"
UNTIL=$(head -n1 "$(gh_pause_file)")
DELTA=$(( UNTIL - NOW ))
[ "$DELTA" -ge 55 ] && [ "$DELTA" -le 75 ] \
    || fail "scenario 1: expected a ~60s secondary window, got ${DELTA}s (until=$UNTIL now=$NOW)"
grep -q 'secondary' "$TMP/err1" \
    || fail "scenario 1: diagnostic did not classify the limit as secondary — output: $(cat "$TMP/err1")"

# --- 2. primary/core exhausted → pause until the bucket's OWN reset ---
echo "  scenario 2: core remaining=0 → primary, pause until the real reset epoch..."
reset_state
CORE_RESET=$((NOW + 1800))
GH_SHIM_BUCKETS="0	$CORE_RESET	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh_api_retry "user" >/dev/null 2>"$TMP/err2" || true
[ "$(head -n1 "$(gh_pause_file)")" = "$CORE_RESET" ] \
    || fail "scenario 2: expected pause until core reset $CORE_RESET, got $(head -n1 "$(gh_pause_file)")"
grep -q 'primary/core' "$TMP/err2" \
    || fail "scenario 2: diagnostic did not classify as primary/core — output: $(cat "$TMP/err2")"

# --- 3. graphql is the exhausted bucket → its reset wins ---
# GraphQL is the loaded bucket in this deployment (~30 pts/min vs core ~0), so
# misreading a graphql exhaustion as core would resume at the wrong time.
echo "  scenario 3: graphql remaining=0 → primary/graphql, graphql's reset..."
reset_state
GQL_RESET=$((NOW + 2400))
GH_SHIM_BUCKETS="4920	$((NOW + 600))	0	$GQL_RESET" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh_api_retry "graphql" >/dev/null 2>"$TMP/err3" || true
[ "$(head -n1 "$(gh_pause_file)")" = "$GQL_RESET" ] \
    || fail "scenario 3: expected pause until graphql reset $GQL_RESET, got $(head -n1 "$(gh_pause_file)")"

# --- 4. an ordinary failure must NOT pause the fleet ---
echo "  scenario 4: non-rate-limit failure → no pause..."
reset_state
GH_SHIM_ERR='gh: Not Found (HTTP 404)' \
    gh_api_retry "repos/o/r/collaborators/u/permission" >/dev/null 2>&1 || true
[ ! -f "$(gh_pause_file)" ] \
    || fail "scenario 4: a 404 stamped a fleet pause — any missing collaborator would halt reviewing"

# --- 5. a stale reset epoch must not resume instantly ---
echo "  scenario 5: already-passed reset epoch → floored to a real window..."
reset_state
GH_SHIM_BUCKETS="0	$((NOW - 500))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
GH_SECONDARY_PAUSE_SECS=60 \
    gh_api_retry "user" >/dev/null 2>&1 || true
[ "$(head -n1 "$(gh_pause_file)")" -gt "$NOW" ] \
    || fail "scenario 5: a past reset epoch produced a non-future pause — would re-trip every tick"

# --- 6. gh_pause_active window semantics (what the tick gate reads) ---
echo "  scenario 6: gh_pause_active true inside the window, false after..."
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$(gh_pause_file)"
gh_pause_active || fail "scenario 6: gh_pause_active false inside an open window"
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$(gh_pause_file)"
! gh_pause_active || fail "scenario 6: gh_pause_active still true after the window passed"
reset_state
! gh_pause_active || fail "scenario 6: gh_pause_active true with no pause file"

# --- 7. fleet-wide, not per-account ---
# The whole point: all containers share one PAT. If this file were namespaced
# under pool/<WORKER_ID>/ the container that noticed would pause alone.
echo "  scenario 7: pause file is fleet-wide (not under pool/<WORKER_ID>/)..."
case "$(WORKER_ID=3 gh_pause_file)" in
    */pool/*) fail "scenario 7: gh_pause_file is namespaced per account — siblings would keep hammering the shared token" ;;
esac
[ "$(WORKER_ID=3 gh_pause_file)" = "$(WORKER_ID=5 gh_pause_file)" ] \
    || fail "scenario 7: gh_pause_file differs by WORKER_ID — the pause is not fleet-wide"

# --- 8. review-loop.sh actually gates on it ---
echo "  scenario 8: review-loop.sh honors the pause before dispatching..."
grep -q 'gh_pause_active' "$PROJECT_ROOT/review-loop.sh" \
    || fail "scenario 8: review-loop.sh has no gh_pause_active gate — the pause would be written but never read"
awk '/gh_pause_active/{g=NR} /\.\/review\.sh/{r=NR} END{exit !(g && r && g < r)}' "$PROJECT_ROOT/review-loop.sh" \
    || fail "scenario 8: the gh_pause_active gate does not precede ./review.sh"

echo "PASS: gh-rate-limit-smoke"
