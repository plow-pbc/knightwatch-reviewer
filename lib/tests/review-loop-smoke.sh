#!/bin/bash
# Smoke for review-loop.sh — the container entrypoint that replaces the systemd
# timer. Covers the contracts that silently abort/derail container reviews if
# broken: (1) fail loud when the dind daemon never comes up (don't hang),
# (2) export REVIEWER_LIB_DIR/PROMPTS_DIR/MAX_CONCURRENT/WAIT_FOR_WORKERS to the
# worker, (3) a fatal (non-zero) review.sh tick exits for container restart
# instead of looping forever, (4) a FUTURE quota-paused-until epoch makes the
# loop skip ticks (never claim) and a PAST one resumes.
set -euo pipefail
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
    echo "$d"
}

# 1. dind never ready → fail loud (non-zero), don't hang.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 1\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"    # `docker info` always fails
printf '#!/bin/bash\nexit 0\n' > "$d/review.sh"; chmod +x "$d/review.sh"
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x ./review-loop.sh ) >/dev/null 2>&1; then
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
  echo "MAX_CONCURRENT=$MAX_CONCURRENT"
  echo "WAIT_FOR_WORKERS=$WAIT_FOR_WORKERS"; } > env.seen
exit 1   # fatal tick: review-loop must exit (not loop) — also breaks the test loop
STUB
chmod +x "$d/review.sh"
# Inherit bogus REVIEWER_LIB_DIR/PROMPTS_DIR to prove the entrypoint OWNS these
# (the contract that broke in the bot's worker, which exports REVIEWER_LIB_DIR):
# review-loop must override them to the in-image paths, not honor the caller.
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x LOCAL_STATE_DIR="$d/state" \
        REVIEWER_LIB_DIR=/bogus/inherited/lib PROMPTS_DIR=/bogus/inherited/prompts \
        ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 on a fatal (non-zero) review.sh tick (should exit for restart)"
fi
grep -q "REVIEWER_LIB_DIR=$d/lib" "$d/env.seen"     || fail "REVIEWER_LIB_DIR not forced to \$repo/lib (caller env leaked through)"
grep -q "PROMPTS_DIR=$d/prompts" "$d/env.seen"      || fail "PROMPTS_DIR not forced to \$repo/prompts (caller env leaked through)"
grep -q "MAX_CONCURRENT=1" "$d/env.seen"            || fail "MAX_CONCURRENT not pinned to 1"
grep -q "WAIT_FOR_WORKERS=1" "$d/env.seen"          || fail "WAIT_FOR_WORKERS not set (one-review-per-account cap)"
rm -rf "$d"

# 4. Quota backoff: a FUTURE paused-until epoch → review-loop never calls review.sh; PAST → resumes.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # dind ready
printf '#!/bin/bash\ntouch "%s/called"\nexit 1\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$d/state/quota-paused-until"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x LOCAL_STATE_DIR="$d/state" ./review-loop.sh ) >/dev/null 2>&1 || true
[ ! -e "$d/called" ] || fail "review-loop ran review.sh while quota-paused (should skip the tick)"
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$d/state/quota-paused-until"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x LOCAL_STATE_DIR="$d/state" ./review-loop.sh ) >/dev/null 2>&1 || true
[ -e "$d/called" ] || fail "review-loop skipped the tick with a PAST quota epoch (should resume)"
rm -rf "$d"

# 5. Auth offline: a fatal auth error takes the worker offline until re-login.
#    While the marker's recorded auth.json mtime still matches the live file,
#    review-loop never claims; a re-login (newer auth.json mtime) clears the
#    marker and resumes — no timer, no spin-aborting every tick.
d=$(make_sandbox)
printf '#!/bin/bash\nexit 0\n' > "$d/bin/docker"; chmod +x "$d/bin/docker"   # dind ready
printf '#!/bin/bash\ntouch "%s/called"\nexit 1\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
mkdir -p "$d/codex"; : > "$d/codex/auth.json"
# Producer: the same mark_auth_offline (lib/state-io.sh) review-one-pr.sh calls
# on a fatal-auth abort — exercises the real produce→consume handoff, not a
# hand-written marker. It records the live auth.json mtime (not re-logged yet).
( cd "$d" && LOCAL_STATE_DIR="$d/state" CODEX_HOME="$d/codex" bash -c '. lib/state-io.sh && mark_auth_offline' )
[ -s "$d/state/auth-offline" ] || fail "mark_auth_offline did not write the auth-offline marker"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x LOCAL_STATE_DIR="$d/state" CODEX_HOME="$d/codex" ./review-loop.sh ) >/dev/null 2>&1 || true
[ ! -e "$d/called" ] || fail "review-loop ran review.sh while auth-offline (should skip until re-login)"
# Simulate operator re-login: bump auth.json mtime past the marker.
touch -d "+1 hour" "$d/codex/auth.json"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x LOCAL_STATE_DIR="$d/state" CODEX_HOME="$d/codex" ./review-loop.sh ) >/dev/null 2>&1 || true
[ -e "$d/called" ] || fail "review-loop stayed offline after re-login (newer auth.json mtime should resume)"
[ ! -e "$d/state/auth-offline" ] || fail "review-loop did not clear the auth-offline marker after re-login"
rm -rf "$d"

echo "PASS: review-loop-smoke"
