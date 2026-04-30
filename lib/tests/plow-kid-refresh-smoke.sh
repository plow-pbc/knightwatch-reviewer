#!/bin/bash
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

export STUB_KID_LOG="$STATE_DIR/kid-calls.log"
export STUB_GIT_LOG="$STATE_DIR/git-calls.log"

# Stub `kid` — log every invocation.
cat > "$HOME/.local/bin/kid" <<'STUB'
#!/bin/bash
echo "KID $*" >> "${STUB_KID_LOG:-/dev/null}"
exit 0
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
    bash "$PROJECT_ROOT/plow-kid-refresh.sh" >/dev/null 2>&1 || true
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
echo "  scenario 4: no new commits — no-op tick, no kid call..."
PROJ="$TMPDIR/proj-current"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/current")
declare -A KID_PATHS=([acme/current]="$PROJ")
CONF
MOCK_GIT_LOCAL_SHA=samesame MOCK_GIT_REMOTE_SHA=samesame run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 kid calls (no new commits), got $n"; cat "$STUB_KID_LOG"; exit 1; }

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

echo "  PASS (5 scenarios: empty-noop, missing-checkout-skip, bootstrap-on-no-.keepitdry, no-new-commits-noop, new-commits-pull-then-index)"
