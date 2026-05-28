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

# Mode-strip: the container branch strips group/other write from the checkout
# after the test, so a leftover proc / a test that ran `chmod 777` can't write it
# while the root scratch-staging path runs. (The detached-writer reap, pkill -u,
# needs a real uid switch and is verified at bring-up.)
chmod 0777 "$d/repo"
run_just_test /dev/null "$d/repo" "$d/log1b" 30s 5s
(( 8#$(stat -c %a "$d/repo") & 0022 )) && fail "repo_dir still group/other-writable after run_just_test (mode-strip missing)" || true

# Host branch (no REVIEWER_TEST_USER): unchanged — runs as the operator, env not
# scrubbed. Pins that the scrub is container-only, not a behavior change on host.
unset REVIEWER_TEST_USER
run_just_test /dev/null "$d/repo" "$d/log2" 30s 5s
grep -q "GH_TOKEN_VISIBLE=secret-xyz" "$d/log2"        || fail "host path unexpectedly scrubbed the env (should be container-only)"

echo "PASS: run-just-test-isolation-smoke"
