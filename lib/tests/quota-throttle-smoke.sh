#!/bin/bash
# Smoke for lib/quota_throttle.py — the preemptive weekly-quota throttle.
#
# Covers the contracts that decide whether an account keeps claiming PRs:
# (1) the projection trigger and its >=24h confidence gate, (2) the absolute
# trigger that catches accounts which burn a week's quota before the gate opens,
# (3) the pause is capped at the window reset, (4) every fail-open path, and
# (5) `record` selects by max resets_at, because real rollouts interleave
# readings from an already-expired window.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/quota_throttle.py"
[ -f "$SRC" ] || { echo "FAIL: quota_throttle.py not found at $SRC" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
NOW=1789000000
H=3600

# usage.json fixture: $1=out $2=used $3=resets_at
mkusage() { printf '{"used_percent": %s, "resets_at": %s}\n' "$2" "$3" > "$1"; }
# decide with a pinned clock; prints the epoch or nothing
decide() { python3 "$SRC" decide --usage "$1" --now "$NOW"; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

# --- Decision table. Every row is the same arrange/act (write a snapshot,
#     run decide, compare stdout), so they belong in one matrix rather than
#     seven near-identical blocks. elapsed = 168h - (resets_at - NOW).
r=$(( NOW + (168-67)*H ))     # elapsed 67h -> line sits at 90*67/168 = 35.9% used
r12=$(( NOW + (168-12)*H ))   # elapsed 12h -> inside the confidence gate
r6=$(( NOW + 6*H ))           # reset sooner than the 24h pause length
DECIDE_CASES=(
  "projection over the line fires|53.0|$r|-|$(( NOW + 24*H ))"
  "projection under the line does not|28.0|$r|-|"
  "gate blocks a huge projection before 24h|20.0|$r12|-|"
  "absolute trigger fires inside the gate|93.0|$r12|-|$(( NOW + 24*H ))"
  "pause is capped at the window reset|95.0|$r6|-|$r6"
  "rolled window is ignored, not trusted|100.0|$(( NOW - 10 ))|-|"
  "KWR_THROTTLE_PCT=0 disables the throttle|99.0|$r|0|"
)
for row in "${DECIDE_CASES[@]}"; do
    IFS='|' read -r name used reset pct want <<<"$row"
    mkusage "$d/u.json" "$used" "$reset"
    if [ "$pct" = - ]; then got=$(decide "$d/u.json")
    else got=$(KWR_THROTTLE_PCT="$pct" decide "$d/u.json"); fi
    [ "$got" = "$want" ] || fail "$name: expected '$want', got '$got'"
done

# --- Fail open: missing file, malformed file, disabled.
# A MISSING snapshot is legitimately idle: silent, exit 0, nothing on stderr.
miss_err=$(python3 "$SRC" decide --usage "$d/nope.json" --now "$NOW" 2>&1 >/dev/null) \
    || fail "a missing usage file exited non-zero (it means the throttle is idle, not broken)"
[ -z "$miss_err" ] || fail "a missing usage file wrote to stderr: $miss_err"
[ -z "$(decide "$d/nope.json")" ] || fail "throttled with no usage file"

# A CORRUPT snapshot is a fault: still no throttle, but loud -- non-zero exit
# and a stderr diagnostic, so review-loop.sh reports it instead of reading the
# empty result as "under quota".
printf 'not json\n' > "$d/bad.json"
bad_out=$(python3 "$SRC" decide --usage "$d/bad.json" --now "$NOW" 2>/dev/null) \
    && fail "a corrupt usage file exited 0 — indistinguishable from 'no throttle needed'"
[ -z "$bad_out" ] || fail "a corrupt usage file still printed a throttle epoch: $bad_out"
bad_err=$(python3 "$SRC" decide --usage "$d/bad.json" --now "$NOW" 2>&1 >/dev/null || true)
printf '%s' "$bad_err" | grep -q 'unreadable usage snapshot' \
    || fail "a corrupt usage file produced no stderr diagnostic; got: $bad_err"
mkusage "$d/u.json" 99.0 "$r"
[ -z "$(KWR_THROTTLE_PCT=0 decide "$d/u.json")" ] || fail "KWR_THROTTLE_PCT=0 did not disable the throttle"

# --- record: picks the CURRENT window (max resets_at), not the newest file.
# Two rollouts; the newer FILE carries an expired window's reading.
sess="$d/codex/sessions/2026/09/10"; mkdir -p "$sess"
cur=$(( NOW + 100*H )); old=$(( NOW - 5*H ))
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":41.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$cur" > "$sess/rollout-a.jsonl"
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":2.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$old" > "$sess/rollout-b.jsonl"
touch -d '1 hour ago' "$sess/rollout-a.jsonl"      # current-window reading is the OLDER file
python3 "$SRC" record --codex-home "$d/codex" --out "$d/rec.json" || fail "record exited non-zero with a readable snapshot"
grep -q '"used_percent": 41.0' "$d/rec.json" || fail "record did not select by max resets_at (took the newest file instead)"

# --- record: one rollout carrying TWO windows. Sessions get resumed, so the
#     LAST rate_limits line in a file is routinely an older window's reading.
#     Taking one line per file reported a capped account (100%) as 55%.
mixed="$d/mixed/sessions/2026/09/10"; mkdir -p "$mixed"
{ printf '{"payload":{"rate_limits":{"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$cur"
  printf '{"payload":{"rate_limits":{"primary":{"used_percent":64.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$old"
} > "$mixed/rollout-mixed.jsonl"
python3 "$SRC" record --codex-home "$d/mixed" --out "$d/mixed.json" || fail "record failed on a mixed-window rollout"
grep -q '"used_percent": 100.0' "$d/mixed.json" \
    || fail "record took the file's LAST reading (an older window) instead of the current window's: $(cat "$d/mixed.json")"

# --- record: resets_at jitters by seconds inside one window, so grouping by
#     exact equality shatters it. All three readings below are one window.
jit="$d/jit/sessions/2026/09/10"; mkdir -p "$jit"
{ printf '{"payload":{"rate_limits":{"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$(( cur ))"
  printf '{"payload":{"rate_limits":{"primary":{"used_percent":70.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$(( cur + 1 ))"
  printf '{"payload":{"rate_limits":{"primary":{"used_percent":55.0,"window_minutes":10080,"resets_at":%s}}}}\n' "$(( cur + 2 ))"
} > "$jit/rollout-jitter.jsonl"
python3 "$SRC" record --codex-home "$d/jit" --out "$d/jit.json" || fail "record failed on jittered resets_at"
grep -q '"used_percent": 100.0' "$d/jit.json" \
    || fail "second-level resets_at jitter fragmented one window: $(cat "$d/jit.json")"

# --- record: a rollout with NO weekly-window block yields no snapshot, rather
#     than silently adopting a short window's percentage.
none5h="$d/none5h/sessions/2026/09/10"; mkdir -p "$none5h"
printf '{"payload":{"rate_limits":{"primary":{"used_percent":99.0,"window_minutes":300,"resets_at":%s}}}}\n' \
    "$cur" > "$none5h/rollout-5h.jsonl"
python3 "$SRC" record --codex-home "$d/none5h" --out "$d/none5h.json" \
    && fail "record accepted a non-weekly window as the weekly snapshot"
[ ! -e "$d/none5h.json" ] || fail "record wrote a snapshot from a non-weekly block"

# --- record: no snapshot anywhere -> non-zero, and no file written.
mkdir -p "$d/empty"
python3 "$SRC" record --codex-home "$d/empty" --out "$d/none.json" && fail "record exited 0 with no snapshot available"
[ ! -e "$d/none.json" ] || fail "record wrote a file when no snapshot was found"

# --- pool_status renders a throttled account distinctly from a hard cap, so
#     the author-facing paused comment shows the real reason for the wait.
lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
s=$(mktemp -d)
mkdir -p "$s/pool/1"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$s/pool/1/throttle-paused-until"
out=$( STATE_DIR="$s" WORKER_ID=1 bash -c "source '$lib_dir/state-io.sh'; pool_status" )
printf '%s' "$out" | grep -q 'throttled' \
    || fail "pool_status did not surface a throttled account (got: $out)"
printf '%s' "$out" | grep -q 'quota-paused' \
    && fail "pool_status mislabeled a throttle as a hard quota pause (got: $out)"
rm -rf "$s"

echo "quota-throttle smoke: all checks passed"
