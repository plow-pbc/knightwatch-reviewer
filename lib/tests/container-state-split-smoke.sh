#!/bin/bash
# Verifies the container state split: the per-PR lock + the just-test semaphore
# stay SHARED (STATE_DIR) so cross-container dedup and #100's global
# MAX_CONCURRENT_TESTS cap both hold across reviewer containers, while the
# canonical clone/fetch lock + per-account stop-state (quota-paused-until,
# auth-offline) are per-container (LOCAL_STATE_DIR). Sources lib/locking.sh
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
# canonical clone/fetch lock + per-account stop-state (quota-paused-until,
# auth-offline) are per-container (LOCAL_STATE_DIR).
grep -q 'acquire_just_test_lock "\$STATE_DIR"' "$HERE/review-one-pr.sh" \
  || fail "just-test semaphore not on the shared STATE_DIR (global cap would break across containers)"
grep -q 'CANONICAL_LOCK_DIR="\$LOCAL_STATE_DIR/canonical-locks"' "$HERE/review-one-pr.sh" \
  || fail "canonical lock not pointed at LOCAL_STATE_DIR (per-container)"

# The shared `claims` volume (runs/ — the KNOWN_SHA dedup history) MUST be an
# external fixed-name volume so it survives project rename / `down -v` / prune;
# a compose-managed volume is lost on those and the reviewer re-reviews every
# open PR (duplicate comments + codex burn). PR #130's durability contract.
# Match the top-level `claims:` block (2-space indent under `volumes:`), not the
# `- claims:/shared` mounts. Pure text assertion (no docker needed at test time).
COMPOSE="$(cd "$HERE/.." && pwd)/docker-compose.yml"
claims_block=$(awk '/^  claims:/{f=1;next} /^  [a-z]/{f=0} f' "$COMPOSE")
printf '%s\n' "$claims_block" | grep -q 'external: true' \
  || fail "claims volume is not external:true (durable review state regressed — PR #130)"
printf '%s\n' "$claims_block" | grep -q 'name: kwr_claims' \
  || fail "claims external name is not kwr_claims (durability contract regressed — PR #130)"

# kwr-config cache delivery: the convention/standards cache reaches the fleet ONLY
# via the read-only host mount + KWR_CONFIG_DIR env. Pin both for EVERY reviewer —
# a reviewer missing either silently can't find the convention cache (and would
# fail loud at review time when KWR_CONFIG_REPO is set). Pure text assertion.
grep -qF 'KWR_CONFIG_DIR: /root/.kwr-config' "$COMPOSE" \
  || fail "x-reviewer-env missing KWR_CONFIG_DIR: /root/.kwr-config (containers can't locate the convention cache)"
n_reviewers=$(grep -cE '^  reviewer-[0-9]+:' "$COMPOSE")
n_mounts=$(grep -cF '${HOME}/services/kwr-config:/root/.kwr-config:ro' "$COMPOSE")
[ "$n_reviewers" -ge 1 ] || fail "no reviewer-N services found in compose"
[ "$n_mounts" -eq "$n_reviewers" ] \
  || fail "kwr-config cache mount on $n_mounts of $n_reviewers reviewers — every reviewer must mount it read-only"

# docker compose plugin: the static docker tarball ships only the client, so the
# reviewer image must install the compose plugin into the default cli-plugins dir
# or every compose-based reviewed suite (plow's `_ensure-dbs`) fails at db-setup
# with "unknown flag: --env-file" → a guaranteed false "Tests failed" while THIS
# suite stays green (it never builds the image). Pure text assertion pins the
# install contract so a Dockerfile edit can't silently drop it. (PR #157.)
DOCKERFILE="$(cd "$HERE/.." && pwd)/docker/Dockerfile"
grep -qE '^ARG COMPOSE_VERSION=' "$DOCKERFILE" \
  || fail "Dockerfile missing pinned ARG COMPOSE_VERSION (compose plugin install regressed — PR #157)"
grep -qF '/usr/local/lib/docker/cli-plugins/docker-compose' "$DOCKERFILE" \
  || fail "Dockerfile not installing the compose plugin into the default cli-plugins dir (PR #157)"
grep -qF 'docker-compose-linux-x86_64' "$DOCKERFILE" \
  || fail "Dockerfile not downloading the compose release asset (PR #157)"
grep -qF 'chmod +x /usr/local/lib/docker/cli-plugins/docker-compose' "$DOCKERFILE" \
  || fail "Dockerfile not making the compose plugin executable (PR #157)"

echo "PASS: container-state-split-smoke"
