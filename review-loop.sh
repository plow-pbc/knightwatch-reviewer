#!/bin/bash
# Codex reviewer entrypoint: replace the systemd 2-min timer with an in-process
# poll loop running review.sh (MAX_CONCURRENT=1) every POLL_SECS. This container
# has NO docker — `just test` is delegated to the shared test-runner. N reviewers
# = N concurrent reviews across N accounts; the shared per-PR flock keeps two off
# the same PR, and a quota cap pauses this account (below) so others carry on.
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
export MAX_CONCURRENT=1
# Block each tick until its dispatched worker finishes (review.sh honors this),
# so one container/account runs at most ONE review at a time. Without it, the
# poll loop's next tick starts while the prior detached worker is still running
# and one account ends up driving multiple concurrent reviews.
export WAIT_FOR_WORKERS=1
# Sentinel so review.sh can re-pin the one-review-per-account contract AFTER it
# sources config.env (which could otherwise override MAX_CONCURRENT/WAIT_FOR_WORKERS).
export REVIEWER_CONTAINER_MODE=1
# `just test` is NOT run here — the reviewer has no docker. run_just_test
# delegates to the shared test-runner via TEST_RUNNER_QUEUE (set in compose).
QUOTA_FILE="$LOCAL_STATE_DIR/quota-paused-until"
echo "[review-loop] polling every ${POLL_SECS}s (worker=${WORKER_ID:-?})"

while true; do
    # Quota backoff: when codex caps this account, review-one-pr.sh writes the
    # reset epoch here; stop claiming reviews until it passes, so healthy accounts
    # handle the queue instead of this one poisoning PRs with paused placeholders.
    if [ -f "$QUOTA_FILE" ]; then
        until_epoch=$(head -n1 "$QUOTA_FILE" 2>/dev/null || echo 0)
        if [ "$(date +%s)" -lt "${until_epoch:-0}" ]; then
            echo "[review-loop] codex quota-paused until $(date -d "@$until_epoch" 2>/dev/null || echo "$until_epoch") — skipping tick (worker=${WORKER_ID:-?})"
            sleep "$POLL_SECS"; continue
        fi
        rm -f "$QUOTA_FILE"   # window passed; resume claiming
    fi
    # review.sh returns 0 on normal/no-PR/transient ticks, non-zero ONLY on fatal
    # misconfig — surface that via container exit + restart instead of spinning.
    ./review.sh || { echo "[review-loop] FATAL: review.sh exited non-zero — config/auth error; exiting for container restart" >&2; exit 1; }
    sleep "$POLL_SECS"
done
