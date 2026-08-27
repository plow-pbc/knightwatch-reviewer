#!/bin/bash
# Verifies the container state split: the per-PR lock + the just-test semaphore
# stay SHARED (STATE_DIR) so cross-container dedup and #100's global
# MAX_CONCURRENT_TESTS cap both hold across reviewer containers, while the
# canonical clone/fetch lock is per-container (LOCAL_STATE_DIR). Per-account
# stop-state (quota-paused-until, auth-offline) lives in the shared
# $STATE_DIR/pool/<WORKER_ID>/ namespace (lib/state-io.sh) so any account can
# render pool_status while still honoring only its own files. Sources lib/locking.sh
# directly — the same functions review-one-pr.sh uses.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/locking.sh"

SHARED=$(mktemp -d); MARK=$(mktemp -d)
trap 'rm -rf "$SHARED" "$MARK"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }
# Wait for the holder to signal it actually holds the lock, so the competing
# acquire races a held lock — not a fixed sleep that scheduler load could flip.
await() { local m="$1" i; for i in $(seq 1 200); do if [ -e "$m" ]; then return 0; fi; sleep 0.05; done; fail "timed out waiting for $m"; }

# Per-PR lock on the SHARED dir: a second container must lose (cross-container dedup).
( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" && touch "$MARK/pr" && sleep 5 ) &
held=$!
await "$MARK/pr"
if ( . "$HERE/locking.sh"; acquire_pr_lock "$SHARED" "cncorp_plow__749" ); then
    fail "second container acquired the shared per-PR lock (dedup broken)"
fi
wait "$held"

# Source contract: the just-test semaphore (#100's global N-slot cap) stays on the
# SHARED STATE_DIR so MAX_CONCURRENT_TESTS holds across containers; the
# canonical clone/fetch lock is per-container (LOCAL_STATE_DIR); per-account
# stop-state lives in the shared $STATE_DIR/pool/ namespace.
grep -q 'acquire_just_test_lock "\$STATE_DIR"' "$HERE/review-one-pr.sh" \
  || fail "just-test semaphore not on the shared STATE_DIR (global cap would break across containers)"
grep -q 'CANONICAL_LOCK_DIR="\$LOCAL_STATE_DIR/canonical-locks"' "$HERE/review-one-pr.sh" \
  || fail "canonical lock not pointed at LOCAL_STATE_DIR (per-container)"
# The author-trust verdict cache holds ENUMERATION verdicts; every acting gate
# re-checks live (lib/auth.sh), so this is dispatch isolation rather than an
# authorization boundary. Per-container still keeps one compromised `just test`
# run from steering its siblings' enumeration, and costs nothing.
grep -q 'trust_cache_file() {.*LOCAL_STATE_DIR' "$HERE/state-io.sh" \
  || fail "trust verdict cache not per-container — a shared store lets one compromised run steer every sibling container's enumeration"

# The compose-render contract (external `claims` volume, KWR_CONFIG_DIR,
# REPO_ENV_DIR, the per-unit mounts) lives in render-compose-smoke.sh, which
# already drives the generator — this suite is only about locking/state-split.

# docker compose plugin: the static docker tarball ships only the client, so the
# reviewer image must install the compose plugin into the default cli-plugins dir
# or every compose-based reviewed suite (plow's `_ensure-dbs`) fails at db-setup
# with "unknown flag: --env-file" → a guaranteed false "Tests failed" while THIS
# suite stays green (it never builds the image). Pure text assertion pins the
# install contract so a Dockerfile edit can't silently drop it. (PR #157.)
DOCKERFILE="$(cd "$HERE/.." && pwd)/docker/Dockerfile"
# Unlike the compose reads above — where awk exits 2 and `set -e` aborts with
# no label at all — `grep -q ... || fail` on a missing file fires the fail
# with the WRONG message, reporting a content regression for a file that
# isn't there. Misattribution earns the guard; a bare abort didn't.
[ -f "$DOCKERFILE" ] || fail "Dockerfile not found at $DOCKERFILE"
grep -qE '^ARG COMPOSE_VERSION=' "$DOCKERFILE" \
  || fail "Dockerfile missing pinned ARG COMPOSE_VERSION (compose plugin install regressed — PR #157)"
grep -qF '/usr/local/lib/docker/cli-plugins/docker-compose' "$DOCKERFILE" \
  || fail "Dockerfile not installing the compose plugin into the default cli-plugins dir (PR #157)"
grep -qF 'docker-compose-linux-x86_64' "$DOCKERFILE" \
  || fail "Dockerfile not downloading the compose release asset (PR #157)"
grep -qF 'chmod +x /usr/local/lib/docker/cli-plugins/docker-compose' "$DOCKERFILE" \
  || fail "Dockerfile not making the compose plugin executable (PR #157)"

# jq version pin: the image must install jq 1.7.x as a static binary, NOT
# bookworm's apt jq 1.6. plow's start.sh readiness gate `curl … | jq -e
# '.config_written == true'` relies on jq exiting non-zero on empty stdin
# (unreachable plowd): jq 1.6 exits 0, jq 1.7 exits 4. Under 1.6 the gate
# false-passes → test_start_sh.bats false-fails → a false "Tests failed" on
# plow PRs while THIS suite stays green (it never builds the image). Pure text
# assertion pins the contract so a Dockerfile edit can't silently drop back to
# apt. (PR #160.)
grep -qE '^ARG JQ_VERSION=1\.7\.' "$DOCKERFILE" \
  || fail "Dockerfile missing pinned ARG JQ_VERSION=1.7.x (jq version pin regressed — PR #160)"
grep -qF 'jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64' "$DOCKERFILE" \
  || fail "Dockerfile not downloading the jq 1.7 static binary (PR #160)"
grep -qF -- '-o /usr/local/bin/jq' "$DOCKERFILE" \
  || fail "Dockerfile not installing jq to /usr/local/bin/jq (PR #160)"
grep -qF 'chmod +x /usr/local/bin/jq' "$DOCKERFILE" \
  || fail "Dockerfile not making the jq binary executable (PR #160)"

echo "PASS: container-state-split-smoke"
