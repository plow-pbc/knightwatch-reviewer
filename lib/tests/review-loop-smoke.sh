#!/bin/bash
# Smoke for review-loop.sh — the container entrypoint that replaces the systemd
# timer. Covers the three contracts that silently abort container reviews if
# broken: (1) fail loud when the dind daemon never comes up (don't hang),
# (2) export REVIEWER_LIB_DIR/PROMPTS_DIR/MAX_CONCURRENT/WAIT_FOR_WORKERS to the
# worker, (3) a fatal (non-zero) review.sh tick exits for container restart
# instead of looping forever.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/review-loop.sh"
[ -f "$SRC" ] || { echo "FAIL: review-loop.sh not found at $SRC" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Sandbox: a temp dir holding a copy of review-loop.sh plus stubbed
# docker/sleep on PATH. review-loop cd's to its own dir, so $repo == sandbox.
make_sandbox() {
    local d; d=$(mktemp -d)
    cp "$SRC" "$d/review-loop.sh"; chmod +x "$d/review-loop.sh"
    mkdir -p "$d/bin" "$d/lib" "$d/prompts"
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
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" DOCKER_HOST=tcp://x ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 on a fatal (non-zero) review.sh tick (should exit for restart)"
fi
grep -q "REVIEWER_LIB_DIR=$d/lib" "$d/env.seen"     || fail "REVIEWER_LIB_DIR not exported to worker as \$repo/lib"
grep -q "PROMPTS_DIR=$d/prompts" "$d/env.seen"      || fail "PROMPTS_DIR not exported to worker as \$repo/prompts"
grep -q "MAX_CONCURRENT=1" "$d/env.seen"            || fail "MAX_CONCURRENT not pinned to 1"
grep -q "WAIT_FOR_WORKERS=1" "$d/env.seen"          || fail "WAIT_FOR_WORKERS not set (one-review-per-account cap)"
rm -rf "$d"

echo "PASS: review-loop-smoke"
