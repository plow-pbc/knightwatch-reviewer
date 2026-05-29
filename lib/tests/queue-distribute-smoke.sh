#!/usr/bin/env bash
# Smoke for the enumerate-once-distribute behavior of review.sh:
#   A. Freshness skip — a 2nd review.sh run inside ENUMERATE_SECS makes ZERO
#      gh enumerate calls (the whole point: one refresh per window).
#   B. Election — two concurrent review.sh runs on a stale queue → exactly
#      one performs the gh enumerate (the other loses the election flock).
#   C. Claim spreading — when specs[0]'s per-PR flock is already held, the
#      consumer skips it and dispatches specs[1] instead.
#   D. Drained refetch — a fresh (within-window) queue whose every PR is
#      flock-held triggers an early refetch (work-driven cadence).
#   E. Idle no-spin — a fresh EMPTY queue does NOT refetch (empty != drained;
#      the fence against idle herd re-enumeration).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR_BASE=$(mktemp -d -t queue-dist-XXXXXX); trap 'rm -rf "$TMPDIR_BASE"' EXIT
export STATE_DIR="$TMPDIR_BASE/state"; export LOG_FILE="$STATE_DIR/orchestrator.log"
export REPOS_DIR="$STATE_DIR/repos"; export WORKDIRS_DIR="$STATE_DIR/workdirs"
mkdir -p "$STATE_DIR/locks" "$REPOS_DIR" "$WORKDIRS_DIR"
export BOT_USER="srosro"
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("cncorp/plow" "cncorp/plow-content")
declare -A KID_PATHS=()
CONF
export HOME="$TMPDIR_BASE/home"; mkdir -p "$HOME/.local/bin"; export PATH="$HOME/.local/bin:$PATH"

# gh stub: log every call; two open PRs (one per repo), no comments.
GH_LOG="$TMPDIR_BASE/gh-calls.log"; export GH_LOG
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$GH_LOG"
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    repo=""; for ((i=1;i<=$#;i++)); do [ "${!i}" = "--repo" ] && { j=$((i+1)); repo="${!j}"; }; done
    case "$repo" in
        cncorp/plow)         echo '[{"number":1,"title":"P1","headRefName":"f1","headRefOid":"aaa111"}]';;
        cncorp/plow-content) echo '[{"number":2,"title":"P2","headRefName":"f2","headRefOid":"bbb222"}]';;
        *) echo '[]';;
    esac
elif [ "$1" = "api" ]; then
    for arg in "$@"; do case "$arg" in */issues/*/comments*) echo '[]'; exit 0;; */pulls/*/commits*) echo '2020-01-01T00:00:00Z'; exit 0;; esac; done
    echo "{}"
else echo "{}"; fi
STUB
chmod +x "$HOME/.local/bin/gh"
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"
write_worker_flock_stub_if_missing "$HOME/.local/bin"
write_worker_timeout_stub_if_missing "$HOME/.local/bin"

export REVIEWER_LIB_DIR="$TMPDIR_BASE/lib"; mkdir -p "$REVIEWER_LIB_DIR"
for f in state-io.sh auth.sh locking.sh tracked-repos.sh gh-comments.sh run-dir.sh pr-enumerate.sh queue.sh; do
    cp "$PROJECT_ROOT/lib/$f" "$REVIEWER_LIB_DIR/$f"
done
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<'WORKER'
#!/bin/bash
echo "WORKER_DISPATCHED repo=$1 pr=$2 sha=$3" >> "$LOG_FILE"
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

# Source the real queue + lock helpers so scenarios D/E can write a queue with
# a controlled refreshed_at and hold flocks directly. TMPDIR for write_queue's
# atomic mktemp (review.sh itself re-pins TMPDIR via tracked-repos.sh).
export TMPDIR="$TMPDIR_BASE/tmp"; mkdir -p "$TMPDIR"
. "$REVIEWER_LIB_DIR/locking.sh"
. "$REVIEWER_LIB_DIR/queue.sh"
TWO_SPECS='[
  {"repo":"cncorp/plow","pr_num":1,"sha":"aaa111","branch":"f1","title":"P1","force_whole_pr":false,"trigger_user":"","trigger_body":"","tick_at":"2026-05-29T00:00:00Z"},
  {"repo":"cncorp/plow-content","pr_num":2,"sha":"bbb222","branch":"f2","title":"P2","force_whole_pr":false,"trigger_user":"","trigger_body":"","tick_at":"2026-05-29T00:00:00Z"}]'

run_review(){ : > "$LOG_FILE"; "$@" bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true; }
gh_enumerate_calls(){ local n; n=$(grep -cE '^(pr list|api graphql)' "$GH_LOG" 2>/dev/null || true); echo "${n:-0}"; }
# wait_dispatched — poll LOG_FILE until the number of WORKER_DISPATCHED lines
# matches the synchronous "dispatched N worker(s)" promise (up to ~5s).
# Workers are detached (background), so the dispatch line may arrive after
# review.sh exits. This mirrors the count_dispatches pattern in
# orchestrator-skip-smoke.sh.
wait_dispatched() {
    local promised actual
    promised=$(grep -oE 'dispatched [0-9]+ worker' "$LOG_FILE" 2>/dev/null \
                  | grep -oE '[0-9]+' | tail -1 || true)
    promised="${promised:-0}"
    if [ "$promised" -eq 0 ]; then return; fi
    for _ in $(seq 1 50); do
        actual=$(grep -c '^WORKER_DISPATCHED ' "$LOG_FILE" 2>/dev/null || true)
        actual="${actual:-0}"
        [ "$actual" -ge "$promised" ] && return
        sleep 0.1
    done
}

# --- A. freshness skip (default ENUMERATE_SECS=60) ---
echo "  A: freshness — 2nd run inside window makes 0 gh enumerate calls..."
rm -f "$STATE_DIR/queue.json"; : > "$GH_LOG"
run_review                       # 1st run: stale/missing → refreshes
first=$(gh_enumerate_calls); [ "$first" -ge 1 ] || { echo "FAIL A: 1st run made no enumerate calls"; exit 1; }
: > "$GH_LOG"
run_review                       # 2nd run: queue fresh → must NOT enumerate
second=$(gh_enumerate_calls)
[ "$second" -eq 0 ] || { echo "FAIL A: 2nd run inside window made $second enumerate calls, expected 0"; cat "$GH_LOG"; exit 1; }
echo "  OK A"

# --- B. election — two concurrent stale-queue runs → exactly 1 enumerates ---
echo "  B: election — concurrent refresh, exactly one enumerates..."
rm -f "$STATE_DIR/queue.json"; : > "$GH_LOG"
ENUMERATE_SECS=120 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
ENUMERATE_SECS=120 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
wait
plow_calls=$(grep -c 'pr list --repo cncorp/plow ' "$GH_LOG" 2>/dev/null || true); plow_calls="${plow_calls:-0}"
[ "$plow_calls" -ge 1 ] || { echo "FAIL B: neither runner enumerated — both review.sh runs may have errored (false-pass guard)"; cat "$GH_LOG"; exit 1; }
[ "$plow_calls" -le 1 ] || { echo "FAIL B: both containers enumerated (cncorp/plow listed $plow_calls times)"; cat "$GH_LOG"; exit 1; }
echo "  OK B"

# --- C. claim spreading — specs[0] flock held → consumer dispatches specs[1] ---
echo "  C: claim spreading — held lock on PR1 → PR2 dispatched..."
write_queue "$STATE_DIR" "$(date +%s)" "$TWO_SPECS"   # seed queue directly (independent of enumerate)
cat > "$TMPDIR_BASE/holder.sh" <<HOLDER
#!/usr/bin/env bash
. "$REVIEWER_LIB_DIR/locking.sh"
acquire_pr_lock "$STATE_DIR" "cncorp_plow__1" || exit 1
echo READY > "$TMPDIR_BASE/held.flag"
sleep 10
HOLDER
chmod +x "$TMPDIR_BASE/holder.sh"
bash "$TMPDIR_BASE/holder.sh" & HOLDER_PID=$!
for _ in $(seq 1 50); do [ -f "$TMPDIR_BASE/held.flag" ] && break; sleep 0.1; done
: > "$LOG_FILE"
ENUMERATE_SECS=999 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true   # fresh queue, consume only
wait_dispatched
kill "$HOLDER_PID" 2>/dev/null || true
grep -q 'WORKER_DISPATCHED repo=cncorp/plow-content pr=2' "$LOG_FILE" || { echo "FAIL C: PR2 not dispatched"; cat "$LOG_FILE"; exit 1; }
grep -q 'WORKER_DISPATCHED repo=cncorp/plow pr=1' "$LOG_FILE" && { echo "FAIL C: PR1 dispatched despite held lock"; cat "$LOG_FILE"; exit 1; }
echo "  OK C"

# --- D. drained → refetch EVEN within the time window ---
echo "  D: drained batch (every PR flock-held) → refetch within window..."
write_queue "$STATE_DIR" "$(date +%s)" "$TWO_SPECS"   # refreshed_at = now (fresh)
HPIDS=()
for slug in cncorp_plow__1 cncorp_plow-content__2; do
  cat > "$TMPDIR_BASE/h-$slug.sh" <<H
#!/usr/bin/env bash
. "$REVIEWER_LIB_DIR/locking.sh"
acquire_pr_lock "$STATE_DIR" "$slug" || exit 1
echo R > "$TMPDIR_BASE/h-$slug.flag"; sleep 10
H
  chmod +x "$TMPDIR_BASE/h-$slug.sh"; bash "$TMPDIR_BASE/h-$slug.sh" & HPIDS+=($!)
done
for _ in $(seq 1 50); do [ -f "$TMPDIR_BASE/h-cncorp_plow__1.flag" ] && [ -f "$TMPDIR_BASE/h-cncorp_plow-content__2.flag" ] && break; sleep 0.1; done
: > "$GH_LOG"
ENUMERATE_SECS=120 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true   # time-fresh, but drained
d_calls=$(gh_enumerate_calls)
for p in "${HPIDS[@]}"; do kill "$p" 2>/dev/null || true; done
[ "$d_calls" -ge 1 ] || { echo "FAIL D: drained batch did NOT refetch within window ($d_calls enumerate calls) — work-driven trigger missing"; cat "$GH_LOG"; exit 1; }
echo "  OK D"

# --- E. idle (EMPTY queue) within window → NO refetch (no idle-spin/herd) ---
echo "  E: empty queue within window → no refetch (idle no-spin)..."
write_queue "$STATE_DIR" "$(date +%s)" '[]'
: > "$GH_LOG"
ENUMERATE_SECS=120 bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 || true
e_calls=$(gh_enumerate_calls)
[ "$e_calls" -eq 0 ] || { echo "FAIL E: empty queue treated as drained → $e_calls enumerate calls (idle-spin/herd regression)"; cat "$GH_LOG"; exit 1; }
echo "  OK E"
echo "ALL PASS: queue-distribute-smoke.sh"
