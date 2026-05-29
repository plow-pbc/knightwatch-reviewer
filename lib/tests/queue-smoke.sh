#!/usr/bin/env bash
# Smoke for lib/queue.sh — the enumerate-once-distribute work-list seam.
#   1. write_queue + read_queue_specs roundtrip preserves specs.
#   2. queue_needs_refresh: missing → refresh; just-written → fresh;
#      refreshed_at older than MAX → refresh.
#   3. acquire/release_enumerator_lock: second concurrent acquire loses,
#      succeeds after release.
#   4. release_pr_lock frees a held per-PR lock for a later acquirer.
#   5. queue_drained: empty→not drained; claimable→not drained;
#      non-empty-all-flock-held→drained.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR=$(mktemp -d -t queue-smoke-XXXXXX); trap 'rm -rf "$WORKDIR"' EXIT
export HOME="$WORKDIR/home"; mkdir -p "$HOME/.local/bin"; export PATH="$HOME/.local/bin:$PATH"
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"
write_worker_flock_stub_if_missing "$HOME/.local/bin"
export TMPDIR="$WORKDIR/tmp"; mkdir -p "$TMPDIR"
STATE_DIR="$WORKDIR/state"; mkdir -p "$STATE_DIR/locks"
. "$PROJECT_ROOT/lib/locking.sh"
. "$PROJECT_ROOT/lib/queue.sh"

assert_eq(){ [ "$2" = "$3" ] && echo "OK: $1" || { echo "FAIL: $1 — expected='$2' actual='$3'"; exit 1; }; }

# 1. roundtrip
SPECS='[{"repo":"a/b","pr_num":1,"sha":"deadbeef","branch":"f","title":"t","force_whole_pr":false,"trigger_user":"","trigger_body":"","tick_at":"2026-05-29T00:00:00Z"}]'
write_queue "$STATE_DIR" 1000 "$SPECS"
assert_eq "roundtrip count" 1 "$(read_queue_specs "$STATE_DIR" | jq 'length')"
assert_eq "roundtrip repo" "a/b" "$(read_queue_specs "$STATE_DIR" | jq -r '.[0].repo')"

# 2. freshness
rm -f "$STATE_DIR/queue.json"
queue_needs_refresh "$STATE_DIR" 120 5000 && echo "OK: missing→refresh" || { echo "FAIL: missing should need refresh"; exit 1; }
write_queue "$STATE_DIR" 5000 "$SPECS"
queue_needs_refresh "$STATE_DIR" 120 5050 && { echo "FAIL: 50s old should be fresh"; exit 1; } || echo "OK: fresh→skip"
queue_needs_refresh "$STATE_DIR" 120 5200 && echo "OK: 200s old→refresh" || { echo "FAIL: stale should refresh"; exit 1; }

# 3. enumerator election lock
acquire_enumerator_lock "$STATE_DIR" || { echo "FAIL: first election acquire"; exit 1; }
if ( . "$PROJECT_ROOT/lib/queue.sh"; . "$PROJECT_ROOT/lib/locking.sh"; acquire_enumerator_lock "$STATE_DIR" ); then
  echo "FAIL: second concurrent election acquire should lose"; exit 1
fi
echo "OK: election mutual exclusion"
release_enumerator_lock
( . "$PROJECT_ROOT/lib/queue.sh"; . "$PROJECT_ROOT/lib/locking.sh"; acquire_enumerator_lock "$STATE_DIR" ) || { echo "FAIL: post-release election acquire"; exit 1; }
echo "OK: election re-acquire after release"

# 4. release_pr_lock
acquire_pr_lock "$STATE_DIR" "a_b__1" || { echo "FAIL: pr lock acquire"; exit 1; }
release_pr_lock
( . "$PROJECT_ROOT/lib/locking.sh"; acquire_pr_lock "$STATE_DIR" "a_b__1" ) || { echo "FAIL: pr lock re-acquire after release"; exit 1; }
echo "OK: release_pr_lock"

# 5. queue_has_claimable: empty queue → no claimable (exit 1); non-empty + a
#    free PR → claimable (exit 0); non-empty + all flock-held → no claimable
#    (exit 1). The driver refreshes on STALE && ! queue_has_claimable, so
#    "no claimable" (empty OR all-held) is what permits a floor-rate refresh;
#    a free PR suppresses it (consume first).
write_queue "$STATE_DIR" 1000 "[]"
queue_has_claimable "$STATE_DIR" && { echo "FAIL: empty queue has no claimable PR"; exit 1; } || echo "OK: empty→no claimable"
write_queue "$STATE_DIR" 1000 "$SPECS"   # one spec, repo a/b pr 1, flock free
queue_has_claimable "$STATE_DIR" || { echo "FAIL: free PR must be claimable"; exit 1; }; echo "OK: free→claimable"
# Hold a/b__1's flock from a background holder so the only spec is unclaimable.
cat > "$WORKDIR/holder.sh" <<HOLD
#!/usr/bin/env bash
. "$PROJECT_ROOT/lib/locking.sh"
acquire_pr_lock "$STATE_DIR" "a_b__1" || exit 1
echo READY > "$WORKDIR/held.flag"; sleep 10
HOLD
chmod +x "$WORKDIR/holder.sh"
bash "$WORKDIR/holder.sh" & HPID=$!
for _ in $(seq 1 50); do [ -f "$WORKDIR/held.flag" ] && break; sleep 0.1; done
if queue_has_claimable "$STATE_DIR"; then kill "$HPID" 2>/dev/null; echo "FAIL: all-flock-held must have no claimable PR"; exit 1; else echo "OK: all-held→no claimable"; fi
kill "$HPID" 2>/dev/null || true
echo "ALL PASS: queue-smoke.sh"
