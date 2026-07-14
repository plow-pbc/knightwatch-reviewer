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
# Stub the reviewer-test reap (pkill -u / pgrep -u) like the other privileged
# ops above: the reap is a bring-up check, not asserted here. Unstubbed, when
# this suite itself runs AS reviewer-test (the container review path), the real
# `pkill -KILL -u reviewer-test` would kill the test runner — a harness
# artifact, not a prod issue (the prod worker runs as root and reaps a distinct
# reviewer-test). pgrep exits 1 (no survivors) so run_just_test's reap-confirm
# loop proceeds cleanly.
printf '#!/bin/bash\nexit 0\n'             > "$d/bin/pkill"
printf '#!/bin/bash\nexit 1\n'             > "$d/bin/pgrep"
# /scenario-shared is a root-owned named volume in prod, so the bridge reset's
# fs ops would need root there — point SCENARIO_SHARED_DIR (the test seam in
# run_just_test) at a sandbox dir instead, so the real mkdir/find/chmod run
# un-privileged and the discard contract is asserted for real below. The dind
# reap (docker) is stubbed: no daemon at unit-test time.
export SCENARIO_SHARED_DIR="$d/sshared"
# The stub records argv and answers `ps -aq` with ORPHAN_ID when set, so BOTH
# reap paths are asserted for real: the common clean-dind run (no orphans →
# no docker rm, prunes still fire) and the orphan run (found → rm -f'd).
cat > "$d/bin/docker" <<STUB
#!/bin/bash
echo "docker \$*" >> "$d/docker.calls"
[ "\$1" = ps ] && [ -n "\${ORPHAN_ID:-}" ] && echo "\$ORPHAN_ID"
exit 0
STUB
# log()/PR_ID are the worker's context (state-io.sh); the FATAL branches
# asserted below need both to exist here.
log() { echo "$*"; }
PR_ID="pr-test"
cat > "$d/bin/just" <<'STUB'
#!/bin/bash
echo "GH_TOKEN_VISIBLE=${GH_TOKEN:-<unset>}"
echo "DOCKER_HOST_VISIBLE=${DOCKER_HOST:-<unset>}"
echo "XDG_CACHE_HOME_VISIBLE=${XDG_CACHE_HOME:-<unset>}"
echo "UV_CACHE_DIR_VISIBLE=${UV_CACHE_DIR:-<unset>}"
echo "PIP_CACHE_DIR_VISIBLE=${PIP_CACHE_DIR:-<unset>}"
STUB
chmod +x "$d/bin"/*
export PATH="$d/bin:$PATH" DOCKER_HOST="tcp://127.0.0.1:2375" GH_TOKEN="secret-xyz"   # the pinned dind endpoint (docker-compose.yml)

# Container branch: the token in run_just_test's own env must NOT reach `just`.
# Seed stale residue on the bridge (a prior run's root-owned dir, issue #172)
# to assert the per-run reset actually discards it and leaves the root 1777.
export REVIEWER_TEST_USER=reviewer-test
mkdir -p "$d/sshared/plow-scenario-shared"; touch "$d/sshared/plow-scenario-shared/stale"
: > "$d/docker.calls"   # phase-scope the call ledger: greps below see only this run
run_just_test /dev/null "$d/repo" "$d/log" 30s 5s
[ ! -e "$d/sshared/plow-scenario-shared" ] || fail "stale bridge entries survived the per-run reset (issue #172 class)"
[ "$(stat -c %a "$d/sshared")" = "1777" ]  || fail "bridge root not left mode 1777 after the reset"
grep -q "docker rm -f" "$d/docker.calls" && fail "reap ran docker rm on a clean dind (no orphans — empty-args rm would abort every review)" || true
grep -q "GH_TOKEN_VISIBLE=<unset>" "$d/log"            || fail "GH_TOKEN leaked into the test command env despite the env -i scrub"
grep -q "DOCKER_HOST_VISIBLE=tcp://127.0.0.1:2375" "$d/log" || fail "DOCKER_HOST not preserved for the dind daemon"
grep -q "XDG_CACHE_HOME_VISIBLE=$d/sshared" "$d/log" || fail "XDG_CACHE_HOME not steered to the bridge dir (nested-dind scenario token bridge missing)"
# uv/pip package caches must be redirected OFF the dind-shared volume (onto the test
# user's HOME) so no dind-side process can race them and no stale root ownership can
# accrue there — while XDG_CACHE_HOME stays /scenario-shared for plow's bridge.
grep -q "UV_CACHE_DIR_VISIBLE=/home/reviewer-test/.cache/uv" "$d/log"   || fail "UV_CACHE_DIR not redirected off /scenario-shared to the test user's HOME"
grep -q "PIP_CACHE_DIR_VISIBLE=/home/reviewer-test/.cache/pip" "$d/log" || fail "PIP_CACHE_DIR not redirected off /scenario-shared to the test user's HOME"
grep -qF "_CACHE_DIR_VISIBLE=$d/sshared" "$d/log" && fail "a package cache is still pointed at the dind-shared bridge volume" || true

# Mode-strip: the container branch strips group/other write from the checkout
# after the test, so a leftover proc / a test that ran `chmod 777` can't write it
# while the root scratch-staging path runs. (The detached-writer reap, pkill -u,
# needs a real uid switch and is verified at bring-up.)
# This run doubles as the orphan-present reap path: ps answers with a fake id,
# which must be force-removed.
chmod 0777 "$d/repo"
export ORPHAN_ID=feedfacecafe   # single authoritative id: the stubs read it from env, the grep below uses it
: > "$d/docker.calls"   # phase-scope: the rm assertion below must match THIS run
run_just_test /dev/null "$d/repo" "$d/log1b" 30s 5s
(( 8#$(stat -c %a "$d/repo") & 0022 )) && fail "repo_dir still group/other-writable after run_just_test (mode-strip missing)" || true
grep -qF "docker rm -fv $ORPHAN_ID" "$d/docker.calls" || fail "orphan container from ps -aq not force-removed (with its anonymous volumes: -v)"

# Bridge-reset fail-loud contracts: anything but the pinned dind endpoint must
# refuse the reap (an ambient endpoint could be the HOST daemon — rm -f there
# is the fleet), and a failed reset must abort before the test runs (a broken
# bridge otherwise resurfaces downstream as opaque per-PR test failures —
# issue #172 class). One representative case each.
out=$( (unset DOCKER_HOST; run_just_test /dev/null "$d/repo" "$d/log-guard" 30s 5s) 2>&1 ) \
    && fail "run_just_test proceeded with DOCKER_HOST unset (off-sidecar cleanup hazard)"
grep -q "refusing dind reap" <<<"$out" || fail "guard refusal missing its FATAL diagnostic"
printf '#!/bin/bash\n[ "$1" = ps ] && exit 1\nexit 0\n' > "$d/bin/docker"    # reset fails at the reap
out=$( (run_just_test /dev/null "$d/repo" "$d/log-reset" 30s 5s) 2>&1 ) \
    && fail "run_just_test proceeded past a failed bridge reset"
grep -q "bridge reset failed" <<<"$out" || fail "failed reset abort missing its FATAL diagnostic"
[ ! -e "$d/log-guard" ] && [ ! -e "$d/log-reset" ] || fail "a test ran despite a refused/failed bridge reset"
unset ORPHAN_ID
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"                             # restore

# Host branch (no REVIEWER_TEST_USER): unchanged — runs as the operator, env not
# scrubbed. Pins that the scrub is container-only, not a behavior change on host.
unset REVIEWER_TEST_USER
run_just_test /dev/null "$d/repo" "$d/log2" 30s 5s
grep -q "GH_TOKEN_VISIBLE=secret-xyz" "$d/log2"        || fail "host path unexpectedly scrubbed the env (should be container-only)"

echo "PASS: run-just-test-isolation-smoke"
