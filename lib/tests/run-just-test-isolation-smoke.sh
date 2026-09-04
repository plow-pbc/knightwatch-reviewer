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
# Re-installable: later sections overwrite $d/bin/docker with narrower stubs to
# drive failure branches, so the full one has to be restorable rather than
# written once.
install_docker_stub() {
cat > "$d/bin/docker" <<STUB
#!/bin/bash
echo "docker \$*" >> "$d/docker.calls"
[ "\$1" = ps ] && [ -n "\${ORPHAN_ID:-}" ] && echo "\$ORPHAN_ID"
# Image inventory for the scenario-image reclaim. __950 is the review under
# test (its workdir basename is the compose project), __951 belongs to another
# PR, python is a pulled base image.
if [ "\$1" = images ]; then
    echo "cncorp_plow__950-scenarios-plow-api:latest"
    echo "cncorp_plow__951-scenarios-plow-api:latest"
    # A repo whose name carries a dot: compose strips it from the project, so
    # the tag does NOT contain the workdir basename verbatim.
    echo "cncorp_plowco__950-scenarios-plow-api:latest"
    echo "python:3.12-slim"
fi
exit 0
STUB
chmod +x "$d/bin/docker"
}
install_docker_stub
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

# --- scenario image reclaim -------------------------------------------------
# Runs in the same preflight as the reap above, on a sandbox this run owns.
# The selection contract is stated once, at prune_stale_scenario_images in
# lib/run-dir.sh; these cases pin its consequences.
export REVIEWER_TEST_USER=reviewer-test
install_docker_stub                          # earlier sections narrowed it
mkdir -p "$d/cncorp_plow__950"               # workdir basename == compose project
: > "$d/docker.calls"
run_just_test /dev/null "$d/cncorp_plow__950" "$d/log-prune" 30s 5s
grep -q "rmi.*__951" "$d/docker.calls" || fail "another PR's scenario image was not reclaimed"
grep -q "rmi.*__950" "$d/docker.calls" && fail "reclaimed THIS review's own images — forces a rebuild of what it is about to use"
grep -q "rmi.*python" "$d/docker.calls" && fail "reclaimed a pulled base image"
grep -qE "image prune.*-a|image prune.*--all" "$d/docker.calls" \
    && fail "'image prune -a' used — deletes base images by upstream Created date"
grep -q "image prune -f" "$d/docker.calls"   || fail "dangling layers never pruned"
grep -q "builder prune" "$d/docker.calls"    || fail "BuildKit cache never pruned"
# Reclaim must precede the build it makes room for.
awk '/docker rmi/{p=1} /docker (image|builder) prune/{if(!p) exit 1}' "$d/docker.calls" \
    || fail "prune phases ran before the tag removal"

# A repo whose GitHub name carries a dot. Compose strips characters outside
# [a-z0-9_-] when deriving the project, so the workdir basename
# (cncorp_plow.co__950) is NOT a prefix of the resulting tags
# (cncorp_plowco__950-…). Matching on the whole project name would classify
# this review's own images as another PR's and reap them right before the build
# that reuses them — silently, every round, for that repo. Verified against
# docker compose, not assumed.
mkdir -p "$d/cncorp_plow.co__950"
: > "$d/docker.calls"
run_just_test /dev/null "$d/cncorp_plow.co__950" "$d/log-dotted" 30s 5s
grep -q "rmi.*cncorp_plowco__950" "$d/docker.calls" \
    && fail "reclaimed this review's own images for a dotted repo name (compose-normalization mismatch)"
grep -q "rmi.*__951" "$d/docker.calls" \
    || fail "dotted-repo run stopped reclaiming other PRs' images"

# Reclaiming is best-effort: a docker that fails outright must not fail the
# review. Called WITHOUT `|| fail` — bash suppresses errexit for any command
# whose status is tested, and that suppression reaches inside the function (and
# inside a subshell), so `run_just_test … || fail` could not observe an abort at
# all. Untested, the script's own `set -e` makes one loud, and the log assertion
# catches the silent-skip shape errexit wouldn't.
printf '#!/bin/bash\ncase "$1" in ps) exit 0;; *) exit 1;; esac\n' > "$d/bin/docker"
run_just_test /dev/null "$d/cncorp_plow__950" "$d/log-prune-fail" 30s 5s
grep -q "GH_TOKEN_VISIBLE" "$d/log-prune-fail" \
    || fail "the review did not proceed past a failed reclaim"

install_docker_stub                                                          # restore

# --- reap_test_user_processes ------------------------------------------------
# The uid switch can't happen in a unit test, so recording stubs assert the
# contract that matters: WHO gets signalled, in what order, and that the host
# path signals nobody. Last section — its stubs are not restored; `sleep` is one
# of them, so the survivor case doesn't spend the bounded wait's real 7s.
REAP_CALLS="$d/reap.calls"
printf '#!/bin/bash\necho "pkill $*" >> "%s"\nexit 0\n' "$REAP_CALLS" > "$d/bin/pkill"
printf '#!/bin/bash\necho "pgrep $*" >> "%s"\nexit "${REAP_PGREP_RC:-1}"\n' "$REAP_CALLS" > "$d/bin/pgrep"
printf '#!/bin/bash\nexit 0\n' > "$d/bin/sleep"
chmod +x "$d/bin/pkill" "$d/bin/pgrep" "$d/bin/sleep"

: > "$REAP_CALLS"; (unset REVIEWER_TEST_USER; reap_test_user_processes) || fail "host path (REVIEWER_TEST_USER unset) returned non-zero"
[ ! -s "$REAP_CALLS" ] || fail "host path signalled processes — a UID-wide reap there kills the operator's own: $(cat "$REAP_CALLS")"
: > "$REAP_CALLS"; REVIEWER_TEST_USER=reviewer-test reap_test_user_processes || fail "reap reported a survivor though pgrep says the test user has none"
grep -qx "pkill -TERM -u reviewer-test" "$REAP_CALLS" || fail "reap never TERMed the test user's processes"
grep -qx "pkill -KILL -u reviewer-test" "$REAP_CALLS" || fail "reap never escalated to SIGKILL (a TERM-trapping writer would survive)"
awk '/pkill -TERM/{t=1} /pkill -KILL/{if(!t) exit 1}' "$REAP_CALLS" || fail "reap sent SIGKILL before SIGTERM"
: > "$REAP_CALLS"; REAP_PGREP_RC=0 REVIEWER_TEST_USER=reviewer-test reap_test_user_processes && fail "a process surviving SIGKILL reported success — run_just_test could not fail loud on it" || true

# cleanup_test_clone gates that sweep on THIS worker holding a forked job: the
# account is shared, so an ungated one kills a sibling PR's live `just test`.
TEST_DIR="$d/no-such-clone"; (exit 0) & _gone=$!; wait "$_gone" 2>/dev/null   # a pid we own, already reaped
: > "$REAP_CALLS"; TEST_JOB_PID="" cleanup_test_clone
[ ! -s "$REAP_CALLS" ] || fail "cleanup with no forked test job swept the shared uid — kills a sibling PR's live run: $(cat "$REAP_CALLS")"
: > "$REAP_CALLS"; TEST_JOB_PID="$_gone" cleanup_test_clone
grep -qx "pkill -KILL -u reviewer-test" "$REAP_CALLS" || fail "cleanup with a forked job skipped the reap — a setsid descendant outlives its clone"

echo "PASS: run-just-test-isolation-smoke"
