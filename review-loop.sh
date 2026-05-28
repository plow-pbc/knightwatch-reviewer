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
export REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$(pwd)/lib}"
# PROMPTS_DIR also defaults to $HOME/.pr-reviewer/prompts in the worker; the
# image ships prompts under the repo, so point it there or reviews abort at
# `probe-schema.md missing`.
export PROMPTS_DIR="${PROMPTS_DIR:-$(pwd)/prompts}"
POLL_SECS="${POLL_SECS:-30}"
export MAX_CONCURRENT=1
# Block each tick until its dispatched worker finishes (review.sh honors this),
# so one container/account runs at most ONE review at a time. Without it, the
# poll loop's next tick starts while the prior detached worker is still running
# and one account ends up driving multiple concurrent reviews.
export WAIT_FOR_WORKERS=1

# Block until the dind daemon answers, so the first `just test` doesn't
# race the sidecar's startup. Fail loud if it never comes up.
for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && { echo "FATAL: dind daemon (${DOCKER_HOST:-default}) never became ready" >&2; exit 1; }
    sleep 2
done
echo "[review-loop] dind ready at ${DOCKER_HOST:-default}; polling every ${POLL_SECS}s (worker=${WORKER_ID:-?})"

while true; do
    # review.sh returns 0 on normal/no-PR/transient-enumerate-failure ticks
    # and non-zero ONLY on fatal misconfig (missing worker script, no tracked
    # repos). Surface that loudly via container exit + restart instead of
    # spinning forever on a broken config.
    ./review.sh || { echo "[review-loop] FATAL: review.sh exited non-zero — config/auth error; exiting for container restart" >&2; exit 1; }
    sleep "$POLL_SECS"
done
