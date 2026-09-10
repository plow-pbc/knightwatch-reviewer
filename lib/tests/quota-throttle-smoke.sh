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
mkusage() { printf '{"used_percent": %s, "resets_at": %s, "observed_at": %s}\n' "$2" "$3" "$NOW" > "$1"; }
# decide with a pinned clock; prints the epoch or nothing
decide() { python3 "$SRC" decide --usage "$1" --now "$NOW"; }

d=$(mktemp -d); trap 'rm -rf "$d"' EXIT

# --- Trigger A: projection over the 90% line fires once the gate is open.
# elapsed = 67h  ->  threshold is 90*67/168 = 35.9% used.
r=$(( NOW + (168-67)*H ))
mkusage "$d/u.json" 53.0 "$r"
out=$(decide "$d/u.json") || fail "decide exited non-zero on a firing projection"
[ -n "$out" ] || fail "projection 53%@67h (=133%) did not fire"
[ "$out" = "$(( NOW + 24*H ))" ] || fail "expected a 24h pause, got $out"

# --- Trigger A: under the line does NOT fire (same elapsed, 28% used = 70%).
mkusage "$d/u.json" 28.0 "$r"
[ -z "$(decide "$d/u.json")" ] || fail "projection 28%@67h (=70%) fired but is under 90%"

# --- Gate: before 24h elapsed the projection is ignored no matter how large.
# elapsed = 12h, used 20% -> projection 280%, but the gate is shut.
r12=$(( NOW + (168-12)*H ))
mkusage "$d/u.json" 20.0 "$r12"
[ -z "$(decide "$d/u.json")" ] || fail "projection fired at 12h elapsed (confidence gate must block it)"

# --- Trigger B: absolute 90% fires even with the gate shut.
mkusage "$d/u.json" 93.0 "$r12"
[ -n "$(decide "$d/u.json")" ] || fail "absolute trigger did not fire at 93% used inside the gate window"

# --- Pause is capped at the window reset (reset 6h out -> pause 6h, not 24h).
r6=$(( NOW + 6*H ))
mkusage "$d/u.json" 95.0 "$r6"
[ "$(decide "$d/u.json")" = "$r6" ] || fail "pause was not capped at resets_at"

# --- Fail open: rolled window (resets_at in the past) must NOT throttle,
#     even though the stale reading says 100% used.
mkusage "$d/u.json" 100.0 "$(( NOW - 10 ))"
[ -z "$(decide "$d/u.json")" ] || fail "throttled on a reading from an expired window"

# --- Fail open: missing file, malformed file, disabled.
[ -z "$(decide "$d/nope.json")" ] || fail "throttled with no usage file"
printf 'not json\n' > "$d/bad.json"
[ -z "$(decide "$d/bad.json")" ] || fail "throttled on a malformed usage file"
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

# --- record: no snapshot anywhere -> non-zero, and no file written.
mkdir -p "$d/empty"
python3 "$SRC" record --codex-home "$d/empty" --out "$d/none.json" && fail "record exited 0 with no snapshot available"
[ ! -e "$d/none.json" ] || fail "record wrote a file when no snapshot was found"

echo "quota-throttle smoke: all checks passed"
