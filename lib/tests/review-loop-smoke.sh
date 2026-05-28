#!/bin/bash
# Smoke for review-loop.sh — the codex reviewer entrypoint (no docker; delegates
# `just test` to the test-runner). Covers: (1) it forces the in-image
# REVIEWER_LIB_DIR/PROMPTS_DIR over inherited env and exports MAX_CONCURRENT=1 /
# WAIT_FOR_WORKERS=1; (2) a fatal review.sh tick exits for restart, not a spin;
# (3) it pauses (never calls review.sh) while a FUTURE quota-paused-until epoch is
# present, and resumes once it's in the past.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/review-loop.sh"
[ -f "$SRC" ] || { echo "FAIL: review-loop.sh not found at $SRC" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

make_sandbox() {
    local d; d=$(mktemp -d)
    cp "$SRC" "$d/review-loop.sh"; chmod +x "$d/review-loop.sh"
    mkdir -p "$d/bin" "$d/lib" "$d/prompts" "$d/state"
    printf '#!/bin/bash\nexit 0\n' > "$d/bin/sleep"; chmod +x "$d/bin/sleep"  # noop: don't actually wait
    echo "$d"
}

# 1+2. Worker env is exported (forced over inherited bogus values); a non-zero
# review.sh tick exits non-zero (fail-loud restart).
d=$(make_sandbox)
cat > "$d/review.sh" <<'STUB'
#!/bin/bash
{ echo "REVIEWER_LIB_DIR=$REVIEWER_LIB_DIR"
  echo "PROMPTS_DIR=$PROMPTS_DIR"
  echo "MAX_CONCURRENT=$MAX_CONCURRENT"
  echo "WAIT_FOR_WORKERS=$WAIT_FOR_WORKERS"; } > env.seen
exit 1   # fatal tick: review-loop must exit (not loop)
STUB
chmod +x "$d/review.sh"
if ( cd "$d" && timeout 20 env PATH="$d/bin:$PATH" LOCAL_STATE_DIR="$d/state" \
        REVIEWER_LIB_DIR=/bogus/lib PROMPTS_DIR=/bogus/prompts \
        ./review-loop.sh ) >/dev/null 2>&1; then
    fail "review-loop exited 0 on a fatal review.sh tick (should exit for restart)"
fi
grep -q "REVIEWER_LIB_DIR=$d/lib" "$d/env.seen"   || fail "REVIEWER_LIB_DIR not forced to \$repo/lib (caller env leaked)"
grep -q "PROMPTS_DIR=$d/prompts" "$d/env.seen"    || fail "PROMPTS_DIR not forced to \$repo/prompts (caller env leaked)"
grep -q "MAX_CONCURRENT=1" "$d/env.seen"          || fail "MAX_CONCURRENT not pinned to 1"
grep -q "WAIT_FOR_WORKERS=1" "$d/env.seen"        || fail "WAIT_FOR_WORKERS not set"
rm -rf "$d"

# 3. Quota backoff: a FUTURE paused-until epoch → review-loop never calls review.sh.
d=$(make_sandbox)
printf '#!/bin/bash\ntouch "%s/called"\nexit 1\n' "$d" > "$d/review.sh"; chmod +x "$d/review.sh"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$d/state/quota-paused-until"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" LOCAL_STATE_DIR="$d/state" ./review-loop.sh ) >/dev/null 2>&1 || true
[ ! -e "$d/called" ] || fail "review-loop ran review.sh while quota-paused (should skip the tick)"
# A PAST epoch → it resumes (calls review.sh, which fail-louds out).
printf '%s\n' "$(( $(date +%s) - 10 ))" > "$d/state/quota-paused-until"
( cd "$d" && timeout 3 env PATH="$d/bin:$PATH" LOCAL_STATE_DIR="$d/state" ./review-loop.sh ) >/dev/null 2>&1 || true
[ -e "$d/called" ] || fail "review-loop skipped the tick with a PAST quota epoch (should resume)"
rm -rf "$d"

echo "PASS: review-loop-smoke"
