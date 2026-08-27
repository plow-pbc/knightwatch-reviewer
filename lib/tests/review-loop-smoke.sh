#!/bin/bash
# Smoke for review-loop.sh — the container entrypoint that replaces the systemd
# timer. Covers the contracts that silently abort/derail container reviews if
# broken: (1) fail loud when the dind daemon never comes up (don't hang),
# (2) export REVIEWER_LIB_DIR/PROMPTS_DIR/MAX_CONCURRENT/WAIT_FOR_WORKERS to the
# worker, (3) a fatal (non-zero) review.sh tick exits for container restart
# instead of looping forever, (4) a FUTURE quota-paused-until epoch makes the
# loop skip ticks (never claim) and a PAST one resumes.
set -euo pipefail
# The host `just test` path deliberately does NOT scrub the environment
# (run-just-test-isolation-smoke pins that), so a host-surface review of a KWR PR
# runs this suite with the operator's real GH_TOKEN exported. Inherited, it
# defeats both directions of the token fence below: the export mutation stops
# failing because bash keeps the export attribute across config.env's bare
# re-assignment, and the no-token case starts passing ${GH_TOKEN:?} from the
# ambient value — so a CORRECT entrypoint fails that one.
unset GH_TOKEN
export WORKER_ID="solo"   # the modeled account; pool-state contract requires it
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/review-loop.sh"
[ -f "$SRC" ] || { echo "FAIL: review-loop.sh not found at $SRC" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Sandbox: a temp dir holding a copy of review-loop.sh plus stubbed
# docker/sleep on PATH. review-loop cd's to its own dir, so $repo == sandbox.
make_sandbox() {
    local d; d=$(mktemp -d)
    cp "$SRC" "$d/review-loop.sh"; chmod +x "$d/review-loop.sh"
    mkdir -p "$d/bin" "$d/lib" "$d/prompts" "$d/state"
    # review-loop.sh sources lib/state-io.sh (log + quota_active/quota_pause_file);
    # give the sandbox the real lib so the quota-pause check exercises production code.
    cp "$(dirname "$SRC")/lib/state-io.sh" "$d/lib/state-io.sh"
    printf '#!/bin/bash\nexit 0\n' > "$d/bin/sleep"; chmod +x "$d/bin/sleep"  # noop: don't actually wait
    # Provisioned codex home. Every case passes CODEX_HOME="$d/codex" so the
    # startup auth guard reads the sandbox, never the operator's real ~/.codex
    # (which would make these cases pass or fail on the host's login state).
    mkdir -p "$d/codex"; echo '{}' > "$d/codex/auth.json"   # non-empty: the guard tests -s
    # review-loop.sh reads GH_TOKEN straight out of config.env — the quota probe
    # runs in ITS shell, and reading the file only in child processes is what
    # shipped that report inert. Compose always mounts one, so the sandbox does too.
    # Deliberately NOT exported: a bare assignment is an ordinary operator edit,
    # and the entrypoint has to turn it into environment or the probe, the git
    # credential helper and the worker all run unauthenticated.
    printf 'GH_TOKEN=ghp_fake_for_smoke\n' > "$d/config.env"
    echo "$d"
}

# 1. dind never ready → fail loud (non-zero), don't hang.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 1\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"    # `docker info` always fails
printf '#!/bin/bash\nexit 0\n' > "$d/review.sh"; chmod +x "$d/review.sh"
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 when the dind daemon never came up (should fail loud)"
fi
rm -rf "$d"

# 2+3. dind ready → worker env is exported; a non-zero review.sh tick exits non-zero.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"    # `docker info` succeeds
cat > "$d/review.sh" <<'STUB'
#!/bin/bash
{ echo "REVIEWER_LIB_DIR=$REVIEWER_LIB_DIR"
  echo "PROMPTS_DIR=$PROMPTS_DIR"
  echo "STATE_DIR=$STATE_DIR"
  echo "GH_TOKEN=$GH_TOKEN"
  echo "MAX_CONCURRENT=$MAX_CONCURRENT"
  echo "WAIT_FOR_WORKERS=$WAIT_FOR_WORKERS"; } > env.seen
exit 1   # fatal tick: review-loop must exit (not loop) — also breaks the test loop
STUB
chmod +x "$d/review.sh"
# Inherit bogus REVIEWER_LIB_DIR/PROMPTS_DIR to prove the entrypoint OWNS these
# (the contract that broke in the bot's worker, which exports REVIEWER_LIB_DIR):
# review-loop must override them to the in-image paths, not honor the caller.
#
# And the same three from CONFIG_ENV.ENV, which is the newer and nastier source:
# the loop reads config.env into its OWN shell now, and config.env is
# operator-edited. STATE_DIR is the one that fails quietly — the container still
# starts, but gh_pause_file() points at a private path and the tick's fleet-pause
# gate goes blind. Asserted behaviourally rather than by parsing source order,
# so it covers all three names and survives any rearrangement that keeps the
# contract.
cat >> "$d/config.env" <<'CFG'
export REVIEWER_LIB_DIR=/bogus/from/config
export PROMPTS_DIR=/bogus/from/config
export STATE_DIR=/bogus/from/config
# Ends in a valid conditional that evaluates FALSE, which is the shape an
# operator's own config.env has (`[ -d …plow-kid ] && KID_EXTRA_MOUNTS=…` on a
# host without that path). `source`'s status is the status of the LAST command in
# the file, so gating the entrypoint on it hard-exits here and restart-loops the
# whole fleet — env.seen never gets written and the assertions below fail by name.
[ -d /nonexistent/kid ] && export KID_EXTRA_MOUNTS=/nonexistent/kid
CFG
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" \
        CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" \
        REVIEWER_LIB_DIR=/bogus/inherited/lib PROMPTS_DIR=/bogus/inherited/prompts \
        ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 on a fatal (non-zero) review.sh tick (should exit for restart)"
fi
grep -q "REVIEWER_LIB_DIR=$d/lib" "$d/env.seen"     || fail "REVIEWER_LIB_DIR not forced to \$repo/lib (caller env leaked through)"
grep -q "PROMPTS_DIR=$d/prompts" "$d/env.seen"      || fail "PROMPTS_DIR not forced to \$repo/prompts (caller env leaked through)"
grep -q "GH_TOKEN=ghp_fake_for_smoke" "$d/env.seen"  || fail "GH_TOKEN did not reach the worker's ENVIRONMENT — a bare assignment in config.env leaves the probe, the git credential helper and review.sh all unauthenticated"
grep -q "STATE_DIR=$d/state" "$d/env.seen"          || fail "STATE_DIR not re-pinned after config.env — gh_pause_file() then points at a private path and the loop goes blind to the fleet-wide pause"
grep -q "MAX_CONCURRENT=1" "$d/env.seen"            || fail "MAX_CONCURRENT not pinned to 1"
grep -q "WAIT_FOR_WORKERS=1" "$d/env.seen"          || fail "WAIT_FOR_WORKERS not set (one-review-per-account cap)"
rm -rf "$d"

# 2b. A config.env that is readable, regular and valid but carries no GH_TOKEN →
# fail loud, don't tick. Deliberately the ONLY negative case: the guard is one
# postcondition, so absent/directory/empty/malformed all reach it by the same
# path, and a case per file shape would be the same question with the fixture
# swapped. This is the shape render-compose.sh's own [ -f ] check cannot catch,
# because it is a perfectly good file.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"
printf '#!/bin/bash\ntouch called\nexit 0\n' > "$d/review.sh"; chmod +x "$d/review.sh"
printf 'export BOT_CMD_PREFIX=srosro\n' > "$d/config.env"
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" \
        CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 with a readable config.env carrying no GH_TOKEN — the quota probe would run unauthenticated and report nothing"
fi
[ ! -e "$d/called" ] || fail "review-loop ticked review.sh with no GH_TOKEN in scope"
rm -rf "$d"

# 4. Quota backoff: a FUTURE paused-until epoch → review-loop never calls review.sh; PAST → resumes.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # dind ready
printf '#!/bin/bash\ntouch "%s/called"\nexit 1\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
mkdir -p "$d/state/pool/solo"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$d/state/pool/solo/quota-paused-until"
# Backdate AFTER the file write (creating a file bumps the dir mtime): the
# loop's registration touch is then the only thing that can freshen it — the pin.
touch -d '3 hours ago' "$d/state/pool/solo"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1 || true
[ ! -e "$d/called" ] || fail "review-loop ran review.sh while quota-paused (should skip the tick)"
[ "$(stat -c %Y "$d/state/pool/solo")" -gt $(( $(date +%s) - 3600 )) ] || fail "loop tick did not touch the account dir (liveness registration unpinned)"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$d/state/pool/solo/quota-paused-until"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1 || true
[ -e "$d/called" ] || fail "review-loop skipped the tick with a PAST quota epoch (should resume)"
rm -rf "$d"

# 5. Auth offline: a fatal auth error takes the worker offline until re-login.
#    While the marker's recorded auth.json mtime still matches the live file,
#    review-loop never claims; a re-login (newer auth.json mtime) clears the
#    marker and resumes — no timer, no spin-aborting every tick.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # dind ready
printf '#!/bin/bash\ntouch "%s/called"\nexit 1\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
# Producer: the same mark_auth_offline (lib/state-io.sh) review-one-pr.sh calls
# on a fatal-auth abort — exercises the real produce→consume handoff, not a
# hand-written marker. It records the live auth.json mtime (not re-logged yet).
mkdir -p "$d/state/pool/solo"   # review-loop's registration, done test-side
( cd "$d" && STATE_DIR="$d/state" CODEX_HOME="$d/codex" bash -c '. lib/state-io.sh && mark_auth_offline' )
[ -s "$d/state/pool/solo/auth-offline" ] || fail "mark_auth_offline did not write the auth-offline marker"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1 || true
[ ! -e "$d/called" ] || fail "review-loop ran review.sh while auth-offline (should skip until re-login)"
# Simulate operator re-login: bump auth.json mtime past the marker.
touch -d "+1 hour" "$d/codex/auth.json"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1 || true
[ -e "$d/called" ] || fail "review-loop stayed offline after re-login (newer auth.json mtime should resume)"
[ ! -e "$d/state/pool/solo/auth-offline" ] || fail "review-loop did not clear the auth-offline marker after re-login"
rm -rf "$d"

# 6. Unprovisioned account: a codex home with no auth.json (compose auto-creates
#    an empty bind-mount source for an account that was never logged in) must
#    fail loud at startup — the logged-out phrasing never matches the fatal-auth
#    regex, so without this guard the account claims PRs and spin-aborts each one.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # dind ready
printf '#!/bin/bash\ntouch "%s/called"\nexit 0\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
rm -f "$d/codex/auth.json"
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x STATE_DIR="$d/state" CODEX_HOME="$d/codex" CONFIG_ENV_FILE="$d/config.env" ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 with no codex auth.json (unprovisioned account should fail loud)"
fi
[ ! -e "$d/called" ] || fail "review-loop claimed a review with no codex auth.json (should never reach review.sh)"
rm -rf "$d"

echo "PASS: review-loop-smoke"
