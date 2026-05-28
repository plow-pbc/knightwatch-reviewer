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
POLL_SECS="${POLL_SECS:-30}"
export MAX_CONCURRENT=1

# Block until the dind daemon answers, so the first `just test` doesn't
# race the sidecar's startup. Fail loud if it never comes up.
for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && { echo "FATAL: dind daemon (${DOCKER_HOST:-default}) never became ready" >&2; exit 1; }
    sleep 2
done
echo "[review-loop] dind ready at ${DOCKER_HOST:-default}; polling every ${POLL_SECS}s (worker=${WORKER_ID:-?})"

while true; do
    ./review.sh || echo "[review-loop] review.sh tick returned non-zero (continuing)"
    sleep "$POLL_SECS"
done
