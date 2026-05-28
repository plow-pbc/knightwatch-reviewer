#!/bin/bash
# Security-contract smoke for run_just_test's container isolation branch: when
# REVIEWER_TEST_USER is set, `just test` must run with the reviewer's tokens
# scrubbed (env -i) so PR-controlled test code can't read them, while
# DOCKER_HOST is preserved (the test needs the dind daemon). Behavioral: a
# stubbed `just` reports what env it actually saw. runuser/timeout/chown are
# stubbed (can't switch uid in a unit test) so only the env contract is under
# test, not the privilege drop itself (that's a Task-7 live-bring-up check).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$HERE/run-dir.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/repo"
printf '#!/bin/bash\nshift 3\nexec "$@"\n' > "$d/bin/timeout"   # drop `-k <dur> <dur>`
printf '#!/bin/bash\nshift 3\nexec "$@"\n' > "$d/bin/runuser"   # drop `-u <user> --` (no real uid switch)
printf '#!/bin/bash\nexit 0\n'             > "$d/bin/chown"
cat > "$d/bin/just" <<'STUB'
#!/bin/bash
echo "GH_TOKEN_VISIBLE=${GH_TOKEN:-<unset>}"
echo "DOCKER_HOST_VISIBLE=${DOCKER_HOST:-<unset>}"
STUB
chmod +x "$d/bin"/*
export PATH="$d/bin:$PATH" DOCKER_HOST="tcp://dind:2375" GH_TOKEN="secret-xyz"

# Container branch: the token in run_just_test's own env must NOT reach `just`.
export REVIEWER_TEST_USER=reviewer-test
run_just_test /dev/null "$d/repo" "$d/log" 30s 5s
grep -q "GH_TOKEN_VISIBLE=<unset>" "$d/log"            || fail "GH_TOKEN leaked into the test command env despite the env -i scrub"
grep -q "DOCKER_HOST_VISIBLE=tcp://dind:2375" "$d/log" || fail "DOCKER_HOST not preserved for the dind daemon"

# Host branch (no REVIEWER_TEST_USER): unchanged — runs as the operator, env not
# scrubbed. Pins that the scrub is container-only, not a behavior change on host.
unset REVIEWER_TEST_USER
run_just_test /dev/null "$d/repo" "$d/log2" 30s 5s
grep -q "GH_TOKEN_VISIBLE=secret-xyz" "$d/log2"        || fail "host path unexpectedly scrubbed the env (should be container-only)"

# Enqueue branch (reviewer side): TEST_RUNNER_QUEUE set → run_just_test writes a
# request file and blocks on the result, returning the test-runner's exit code.
q="$d/queue"; mkdir -p "$q"
( . "$HERE/run-dir.sh"; rc=0; TEST_RUNNER_QUEUE="$q" run_just_test /jf /repo "$d/qlog" 30s 5s || rc=$?; echo "$rc" > "$d/qrc" ) &
client=$!
for i in $(seq 1 200); do req=$(ls "$q"/*.req 2>/dev/null) && break; sleep 0.05; done
[ -n "${req:-}" ] || fail "enqueue branch wrote no test-runner request"
mapfile -t RF < "$req"
[ "${RF[0]}" = "/jf" ] && [ "${RF[1]}" = "/repo" ] && [ "${RF[2]}" = "$d/qlog" ] \
    || fail "enqueued request fields wrong (got: ${RF[*]})"
printf '%s\n' 7 > "$q/$(basename "$req" .req).result"   # act as the test-runner: return exit 7
wait "$client"
[ "$(cat "$d/qrc")" = "7" ] || fail "enqueue branch didn't return the test-runner's exit code (got $(cat "$d/qrc"))"

echo "PASS: run-just-test-isolation-smoke"
