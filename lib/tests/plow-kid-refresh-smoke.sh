#!/usr/bin/env bash
# Smoke test for plow-kid-refresh.sh.
#
# Closes the runtime-coverage gap on the manifest consumer that
# bootstraps + maintains kid prior-art indexes for tracked repos.
# Same shape as the other per-consumer smokes: sandbox STATE_DIR,
# stub `git` and `kid` via PATH, exercise the script end-to-end,
# assert log lines + which `kid` invocations fired.
#
# Scenarios:
#   1. KID_PATHS empty (no repos to refresh) → no-op, no errors.
#   2. KID_PATHS entry whose checkout doesn't exist → "checkout missing"
#      log line, no `kid index` call.
#   3. KID_PATHS entry pointing to a .git dir with NO .keepitdry → bootstrap
#      `kid index` call (initial-index path).
#   4. KID_PATHS entry pointing to .git + .keepitdry, no new commits
#      (LOCAL == REMOTE) → no `kid index` call (no-op tick).
#   5. KID_PATHS entry pointing to .git + .keepitdry, new commits
#      (LOCAL != REMOTE) → `git pull` then `kid index` call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t kid-refresh-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export LOG="$STATE_DIR/plow-kid-refresh.log"
export LOCK="$TMPDIR/lock"
mkdir -p "$STATE_DIR"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
# Production no longer prepends $HOME/.local/bin to PATH (writable-PATH
# attack vector). Smoke prepends here so its stubs (kid, git) resolve.
export PATH="$HOME/.local/bin:$PATH"

export STUB_KID_LOG="$STATE_DIR/kid-calls.log"
export STUB_GIT_LOG="$STATE_DIR/git-calls.log"

# Stub `kid` — log every invocation.
cat > "$HOME/.local/bin/kid" <<'STUB'
#!/bin/bash
echo "KID $*" >> "${STUB_KID_LOG:-/dev/null}"
exit "${MOCK_KID_EXIT:-0}"
STUB
chmod +x "$HOME/.local/bin/kid"

# Stub `git` — log every invocation; behavior driven by env vars.
# `MOCK_GIT_LOCAL_SHA` / `MOCK_GIT_REMOTE_SHA` simulate the rev-parse
# outputs the script compares to decide "new commits or no-op".
cat > "$HOME/.local/bin/git" <<'STUB'
#!/bin/bash
echo "GIT $*" >> "${STUB_GIT_LOG:-/dev/null}"
case "$1" in
    fetch|pull) exit 0 ;;
    rev-parse)
        # Two callers: HEAD (LOCAL), origin/main (REMOTE).
        case "$2" in
            HEAD)        echo "${MOCK_GIT_LOCAL_SHA:-aaaaaaaa}" ;;
            origin/main) echo "${MOCK_GIT_REMOTE_SHA:-aaaaaaaa}" ;;
            --short)
                # `git rev-parse --short HEAD` is used in log strings
                # after a successful index. Emit a stub short SHA.
                echo "abc1234"
                ;;
            *) echo "${MOCK_GIT_LOCAL_SHA:-aaaaaaaa}" ;;
        esac
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$HOME/.local/bin/git"

# Sandbox lib dir + repos.conf. Each scenario rewrites repos.conf.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"

run_refresh() {
    : > "$STUB_KID_LOG"
    : > "$STUB_GIT_LOG"
    : > "$LOG"
    rm -f "$LOCK"
    # Capture rather than swallow: scenarios assert on the exit status, and
    # a bare non-zero would trip the suite's `set -e`.
    REFRESH_RC=0
    bash "$PROJECT_ROOT/plow-kid-refresh.sh" >/dev/null 2>&1 || REFRESH_RC=$?
}

count_kid() { grep -c '^KID ' "$STUB_KID_LOG" 2>/dev/null || true; }

# Scenario 1: empty KID_PATHS → no-op.
echo "  scenario 1: empty KID_PATHS — no-op, no kid calls..."
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=()
declare -A KID_PATHS=()
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 kid calls, got $n"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 2: KID_PATHS entry whose path doesn't exist → log "checkout missing".
echo "  scenario 2: missing checkout — log + skip..."
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/foo")
declare -A KID_PATHS=([acme/foo]="$TMPDIR/nonexistent")
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 2: expected 0 kid calls (missing checkout), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q 'checkout missing or not a git repo' "$LOG" || { echo "FAIL scenario 2: expected 'checkout missing' log line"; cat "$LOG"; exit 1; }
# Tolerated on purpose: a partial-org repo or a kwr-config .repos[] entry is
# tracked for review but never cloned on this host, so a missing checkout must
# NOT redden the unit — a permanent alarm would bury the repos that actually
# went stale, which is the signal this unit exists to carry. org-sync owns the
# "no mirror" condition and alarms there.
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 2: a missing checkout reddened the unit — permanent alarm buries real staleness"; cat "$LOG"; exit 1; }

# Scenario 3: .git but no .keepitdry → bootstrap kid index.
echo "  scenario 3: bootstrap (no .keepitdry yet) — initial kid index call..."
PROJ="$TMPDIR/proj-bootstrap"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/bootstrap")
declare -A KID_PATHS=([acme/bootstrap]="$PROJ")
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 3: expected 1 kid call (bootstrap), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q "KID index $PROJ" "$STUB_KID_LOG" || { echo "FAIL scenario 3: kid index call shape wrong"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 4: .git + .keepitdry, no new commits (LOCAL == REMOTE) → no-op.
# The index is deliberately NOT gated on new commits: a failed index leaves HEAD
# already advanced by the pull, so gating it would strand that repo stale until
# some unrelated commit landed, reporting success every tick in between. So an
# unchanged tick still re-indexes (kid is incremental) but must not re-pull.
echo "  scenario 4: no new commits — no pull, but the index still retries..."
PROJ="$TMPDIR/proj-current"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/current")
declare -A KID_PATHS=([acme/current]="$PROJ")
CONF
MOCK_GIT_LOCAL_SHA=samesame MOCK_GIT_REMOTE_SHA=samesame run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 4: expected 1 kid call (index retries on an unchanged tick), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q '^GIT pull' "$STUB_GIT_LOG" && { echo "FAIL scenario 4: pulled with no new commits"; cat "$STUB_GIT_LOG"; exit 1; }
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 4: healthy unchanged tick reported failure"; cat "$LOG"; exit 1; }

# Scenario 4b: the stale-index seam itself — an index that failed on the tick
# that pulled must retry on the NEXT tick, when LOCAL == REMOTE again.
echo "  scenario 4b: index failed after a pull — retries next tick, not stranded..."
PROJ="$TMPDIR/proj-retry"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/retry")
declare -A KID_PATHS=([acme/retry]="$PROJ")
CONF
# Tick 1: new commits, pull succeeds, index FAILS → unit must report failure.
MOCK_GIT_LOCAL_SHA=oldsha MOCK_GIT_REMOTE_SHA=newsha MOCK_KID_EXIT=1 run_refresh
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 4b: index failure on the pulling tick reported success"; cat "$LOG"; exit 1; }
# Tick 2: HEAD already advanced, so LOCAL == REMOTE — the index must still run.
MOCK_GIT_LOCAL_SHA=newsha MOCK_GIT_REMOTE_SHA=newsha run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 4b: index not retried after the advanced HEAD made LOCAL == REMOTE — stale forever"; cat "$STUB_KID_LOG"; exit 1; }
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 4b: recovery tick still reported failure"; cat "$LOG"; exit 1; }

# Scenario 5: .git + .keepitdry, new commits (LOCAL != REMOTE) → pull + index.
echo "  scenario 5: new commits — pull + kid index..."
PROJ="$TMPDIR/proj-fresh"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/fresh")
declare -A KID_PATHS=([acme/fresh]="$PROJ")
CONF
MOCK_GIT_LOCAL_SHA=oldsha MOCK_GIT_REMOTE_SHA=newsha run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 5: expected 1 kid call (incremental), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q '^GIT pull --ff-only' "$STUB_GIT_LOG" || { echo "FAIL scenario 5: expected 'git pull' before index"; cat "$STUB_GIT_LOG"; exit 1; }
grep -q "KID index $PROJ" "$STUB_KID_LOG" || { echo "FAIL scenario 5: kid index call shape wrong"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 6: project dir not writable → skipped with an actionable line, kid
# never invoked, unit exits non-zero.
# The regression this pins: this unit runs under ProtectHome=read-only with a
# per-repo ReadWritePaths allowlist that install.sh renders from repos.conf at
# INSTALL time, while org-sync grows the tracked set hourly. A repo discovered
# since the last install is outside the sandbox, so kid's chromadb bootstrap
# died with a bare "Read-only file system (os error 30)" traceback under a log
# line that only said "initial index failed" — 43 of 79 PRs reviewed in 24h
# had no semantic index and nothing said so.
echo "  scenario 6: project outside the sandbox — skipped loudly, no kid call, non-zero exit..."
PROJ="$TMPDIR/proj-readonly"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/readonly")
declare -A KID_PATHS=([acme/readonly]="$PROJ")
CONF
chmod a-w "$PROJ"
run_refresh
chmod -R u+w "$PROJ"   # restore before the trap cleans up
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 6: kid was invoked on an unwritable project ($n calls) — the doomed bootstrap wasn't skipped"; cat "$STUB_KID_LOG"; exit 1; }
grep -q 'not writable under this unit.s sandbox' "$LOG" || { echo "FAIL scenario 6: expected the sandbox-drift log line"; cat "$LOG"; exit 1; }
grep -q 'install.sh' "$LOG" || { echo "FAIL scenario 6: log line must name the remedy (re-run install.sh)"; cat "$LOG"; exit 1; }
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 6: refresh exited 0 despite a repo it could never index"; cat "$LOG"; exit 1; }

# Scenario 7: kid itself fails → the repo has no fresh index, so the unit must
# not report success. A missing index is invisible at review time (reviews just
# silently lose semantic context), which is the whole failure mode being fixed —
# the read-only sandbox was only one cause of it.
echo "  scenario 7: kid index fails — counted as degraded, non-zero exit..."
PROJ="$TMPDIR/proj-kidfail"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/kidfail")
declare -A KID_PATHS=([acme/kidfail]="$PROJ")
CONF
MOCK_KID_EXIT=1 run_refresh
grep -q 'initial index failed' "$LOG" || { echo "FAIL scenario 7: expected the index-failure log line"; cat "$LOG"; exit 1; }
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 7: refresh exited 0 with a repo left un-indexed"; cat "$LOG"; exit 1; }

echo "  PASS (8 scenarios: empty-noop, missing-checkout-tolerated-not-alarmed, bootstrap-on-no-.keepitdry, unchanged-tick-retries-index, failed-index-retries-next-tick, new-commits-pull-then-index, unwritable-project-skipped-loudly, index-failure-is-not-success)"
