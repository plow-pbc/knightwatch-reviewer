#!/bin/bash
# Container entrypoint: replace the systemd 2-min timer with an in-process
# poll loop. Waits for the dind sidecar's daemon, then runs review.sh
# (MAX_CONCURRENT=1 per container) every POLL_SECS. N containers = N
# concurrent reviews across N accounts; the shared per-PR flock keeps two
# containers off the same PR.
set -uo pipefail

cd "$(dirname "$0")"
# In the image the repo is the working dir; review.sh's libs and the
# tracked-repos manifest resolve relative to it. Default REVIEWER_LIB_DIR
# to the in-image lib so review.sh doesn't fall back to $HOME/.pr-reviewer/lib
# (which doesn't exist in the container). STATE_DIR / REPOS_DIR / WORKDIRS_DIR
# / LOCAL_STATE_DIR come from the compose environment.
# The entrypoint OWNS these paths — assign directly (not `${VAR:-default}`) so
# the container has one contract regardless of any inherited env. The worker
# otherwise defaults both to $HOME/.pr-reviewer/{lib,prompts}, which doesn't
# exist in the image (reviews abort at `probe-schema.md missing`).
export REVIEWER_LIB_DIR="$(pwd)/lib"
export PROMPTS_DIR="$(pwd)/prompts"
# Shared logger (timestamp + [w<WORKER_ID>] tag). LOG_FILE is unset here —
# review.sh sets it later — so log() falls back to stdout-only, which is what
# the container stream wants anyway.
source "$REVIEWER_LIB_DIR/state-io.sh"
POLL_SECS="${POLL_SECS:-30}"
# Time floor for refreshing the eligible-PR queue GLOBALLY: one container per
# window runs the GraphQL enumerate (election-serialized) and writes queue.json;
# all containers consume it every POLL_SECS and claim PRs via the per-PR flock.
# review.sh refreshes on this floor alone (no work-state gate), so enumeration
# runs ~once/ENUMERATE_SECS instead of once/POLL_SECS/container — that's what
# cuts the GraphQL burn. New PRs are discovered within one window.
export ENUMERATE_SECS="${ENUMERATE_SECS:-60}"
export MAX_CONCURRENT=1
# Block each tick until its dispatched worker finishes (review.sh honors this),
# so one container/account runs at most ONE review at a time. Without it, the
# poll loop's next tick starts while the prior detached worker is still running
# and one account ends up driving multiple concurrent reviews.
export WAIT_FOR_WORKERS=1
# Sentinel so review.sh can re-pin the one-review-per-account contract AFTER it
# sources config.env (which could otherwise override MAX_CONCURRENT/WAIT_FOR_WORKERS).
export REVIEWER_CONTAINER_MODE=1
# Run PR-controlled `just test` as this unprivileged user (created in the image)
# so a hostile test recipe can't read /root/.codex or the reviewer's tokens —
# see run_just_test in lib/run-dir.sh.
export REVIEWER_TEST_USER="${REVIEWER_TEST_USER:-reviewer-test}"

# Block until the dind daemon answers, so the first `just test` doesn't
# race the sidecar's startup. Fail loud if it never comes up.
for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && { log "[review-loop] FATAL: dind daemon (${DOCKER_HOST:-default}) never became ready"; exit 1; }
    sleep 2
done
log "[review-loop] dind ready at ${DOCKER_HOST:-default}; polling every ${POLL_SECS}s"

# Quota backoff: when codex caps this account, review-one-pr.sh writes the reset
# epoch here; this loop stops claiming reviews until it passes, so a capped
# account backs off and the other accounts carry the queue.
QUOTA_FILE="$LOCAL_STATE_DIR/quota-paused-until"

while true; do
    if [ -f "$QUOTA_FILE" ]; then
        if [ "$(date +%s)" -lt "$(head -n1 "$QUOTA_FILE" 2>/dev/null || echo 0)" ]; then
            log "[review-loop] codex quota-paused — skipping tick"
            sleep "$POLL_SECS"; continue
        fi
        rm -f "$QUOTA_FILE"   # window passed; resume claiming
    fi
    # review.sh returns 0 on normal/no-PR/transient-enumerate-failure ticks
    # and non-zero ONLY on fatal misconfig (missing worker script, no tracked
    # repos). Surface that loudly via container exit + restart instead of
    # spinning forever on a broken config.
    ./review.sh || { log "[review-loop] FATAL: review.sh exited non-zero — config/auth error; exiting for container restart"; exit 1; }
    sleep "$POLL_SECS"
done
