#!/bin/bash
# Container entrypoint: replace the systemd 2-min timer with an in-process
# poll loop. Waits for the dind sidecar's daemon, then runs review.sh
# (serialized — one review per tick) every POLL_SECS. N containers = N
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
POLL_SECS="${POLL_SECS:-30}"
# review.sh pins MAX_CONCURRENT=1 and waits for its worker on its own (the single
# contract since the host reviewer was retired), so one container/account runs at
# most ONE review at a time. REVIEWER_CONTAINER_MODE still gates the container-only
# paths in review.sh (quota-pause break) and review-one-pr.sh (untrusted-author skip).
export REVIEWER_CONTAINER_MODE=1
# Run PR-controlled `just test` as this unprivileged user (created in the image)
# so a hostile test recipe can't read /root/.codex or the reviewer's tokens —
# see run_just_test in lib/run-dir.sh.
export REVIEWER_TEST_USER="${REVIEWER_TEST_USER:-reviewer-test}"

# Block until the dind daemon answers, so the first `just test` doesn't
# race the sidecar's startup. Fail loud if it never comes up.
for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && { echo "FATAL: dind daemon (${DOCKER_HOST:-default}) never became ready" >&2; exit 1; }
    sleep 2
done
echo "[review-loop] dind ready at ${DOCKER_HOST:-default}; polling every ${POLL_SECS}s (worker=${WORKER_ID:-?})"

# Quota backoff: when codex caps this account, review-one-pr.sh writes the reset
# epoch here; this loop stops claiming reviews until it passes, so a capped
# account backs off and the other accounts carry the queue.
QUOTA_FILE="$LOCAL_STATE_DIR/quota-paused-until"

while true; do
    if [ -f "$QUOTA_FILE" ]; then
        if [ "$(date +%s)" -lt "$(head -n1 "$QUOTA_FILE" 2>/dev/null || echo 0)" ]; then
            echo "[review-loop] codex quota-paused (worker=${WORKER_ID:-?}) — skipping tick"
            sleep "$POLL_SECS"; continue
        fi
        rm -f "$QUOTA_FILE"   # window passed; resume claiming
    fi
    # review.sh returns 0 on normal/no-PR/transient-enumerate-failure ticks
    # and non-zero ONLY on fatal misconfig (missing worker script, no tracked
    # repos). Surface that loudly via container exit + restart instead of
    # spinning forever on a broken config.
    ./review.sh || { echo "[review-loop] FATAL: review.sh exited non-zero — config/auth error; exiting for container restart" >&2; exit 1; }
    sleep "$POLL_SECS"
done
