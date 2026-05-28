#!/bin/bash
# Test-runner entrypoint: the ONLY container with docker access. Codex reviewers
# (no daemon reachable) delegate `just test` here via request files under the
# shared test-queue; this loop runs each as the unprivileged reviewer-test user
# (run_just_test's isolation branch) against the shared per-PR workdir, and writes
# the exit code back. One runner → `just test` is serialized for free.
set -uo pipefail
cd "$(dirname "$0")"
export REVIEWER_LIB_DIR="$(pwd)/lib"
. "$REVIEWER_LIB_DIR/run-dir.sh"

QUEUE="${TEST_RUNNER_QUEUE:-$STATE_DIR/test-queue}"
POLL_SECS="${POLL_SECS:-2}"
mkdir -p "$QUEUE"

# Block until dind answers (the reviewers have no daemon; only this loop does).
for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    [ "$i" -eq 60 ] && { echo "FATAL: dind (${DOCKER_HOST:-?}) never became ready" >&2; exit 1; }
    sleep 2
done
echo "[test-runner] dind ready; polling $QUEUE"

while true; do
    shopt -s nullglob
    for req in "$QUEUE"/*.req; do
        id=$(basename "$req" .req)
        proc="$QUEUE/$id.proc"
        # Atomic claim: rename wins exactly once, so a half-written req (the
        # reviewer writes .tmp then renames in) or a duplicate isn't double-run.
        mv "$req" "$proc" 2>/dev/null || continue
        # Fields are 5 plain lines (run_just_test args) — read literally, never
        # sourced, so a PR-derived path can't inject shell.
        mapfile -t F < "$proc"
        echo "[test-runner] just test for $id (repo=${F[1]})"
        run_just_test "${F[0]}" "${F[1]}" "${F[2]}" "${F[3]}" "${F[4]}"
        rc=$?
        printf '%s\n' "$rc" > "$QUEUE/$id.result.tmp" && mv "$QUEUE/$id.result.tmp" "$QUEUE/$id.result"
        rm -f "$proc"
    done
    shopt -u nullglob
    sleep "$POLL_SECS"
done
