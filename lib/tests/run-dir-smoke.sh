#!/usr/bin/env bash
# Smoke for allocate_run_dir (lib/run-dir.sh).
#
# Locks down the no-overwrite guarantee at the worker's runtime guard:
#   1. Clean run dir → created with agents/ + inputs/ subdirs, returns 0
#   2. Pre-existing run dir → returns 1, logs "collision"
#   3. Subdir mkdir partially fails → rollback removes RUN_DIR; "as a
#      unit" contract holds (mkdir is function-stubbed since real
#      filesystem partial failures aren't easily simulable)
#   4. RUN_DIR's parent unwritable (read-only) → returns 1, logs the
#      parent-create failure
#
# Plus discard_empty_run_dir (the inverse, used by the worker's clean-skip
# exits — issue #189):
#   5. Freshly-allocated dir + run.log → removed, returns 0
#   6. Dir holding agents/aggregator/output.md → kept intact incl. its
#      run.log, returns 1
#   7. Dir holding meta.json → kept intact incl. its run.log, returns 1
#   8. Path fence (non-runs root, traversal, trailing slash, runs root, empty)
#      → refused, nothing touched
#   9. A ".." SUBSTRING inside a path component is not traversal → allowed
#
# Sources lib/run-dir.sh directly so this test exercises the same
# function review-one-pr.sh calls. Stubs `log()` to capture log lines
# locally; the production log() is in lib/state-io.sh.

set -uo pipefail

TMPDIR=$(mktemp -d -t run-dir-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR" 2>/dev/null; chmod -R u+w "$TMPDIR" 2>/dev/null; rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

# Stub the log() seam allocate_run_dir uses. Production log() comes
# from lib/state-io.sh; here we just append to a file the assertions
# can grep.
LOG_CAPTURE="$TMPDIR/log.txt"
PR_ID="test/repo#1"
log() { echo "$*" >> "$LOG_CAPTURE"; }

echo "  scenario 1: clean RUN_DIR → success + agents/inputs created..."
RD="$TMPDIR/state/runs/clean-id"
if ! allocate_run_dir "$RD"; then
    echo "FAIL: clean allocation returned non-zero"
    exit 1
fi
for sub in agents inputs; do
    if [ ! -d "$RD/$sub" ]; then
        echo "FAIL: $RD/$sub not created"
        exit 1
    fi
done

echo "  scenario 2: pre-existing RUN_DIR → returns 1, logs collision..."
: > "$LOG_CAPTURE"
RD="$TMPDIR/state/runs/exists-id"
mkdir -p "$RD"
if allocate_run_dir "$RD"; then
    echo "FAIL: collision allocation should have returned non-zero"
    exit 1
fi
if ! grep -q "RUN_DIR collision" "$LOG_CAPTURE"; then
    echo "FAIL: collision was not logged with the 'collision' marker"
    cat "$LOG_CAPTURE"
    exit 1
fi
if ! grep -q "$RD" "$LOG_CAPTURE"; then
    echo "FAIL: collision log line did not include the dir path"
    cat "$LOG_CAPTURE"
    exit 1
fi

echo "  scenario 3: subdir mkdir partially fails → rollback removes RUN_DIR..."
: > "$LOG_CAPTURE"
RD="$TMPDIR/state/runs/rollback-id"

# Override mkdir to simulate a partial-success failure on the third call
# (the agents/inputs creation in allocate_run_dir): create the first arg,
# fail before the second. Calls 1 (mkdir -p parent) and 2 (mkdir $run_dir)
# go through unchanged.
mkdir_calls=0
mkdir() {
    mkdir_calls=$((mkdir_calls + 1))
    if [ "$mkdir_calls" -eq 3 ]; then
        command mkdir "$1" 2>/dev/null
        return 1
    fi
    command mkdir "$@"
}

if allocate_run_dir "$RD"; then
    echo "FAIL: subdir-mkdir-failure allocation should have returned non-zero"
    unset -f mkdir
    exit 1
fi
unset -f mkdir
if [ -e "$RD" ]; then
    echo "FAIL: $RD was not rolled back after subdir mkdir failure"
    ls -laR "$RD"
    exit 1
fi
if ! grep -q "rolling back" "$LOG_CAPTURE"; then
    echo "FAIL: rollback log line not emitted"
    cat "$LOG_CAPTURE"
    exit 1
fi

echo "  scenario 4: parent unwritable → returns 1, logs real failure (not 'collision')..."
: > "$LOG_CAPTURE"
RO_PARENT="$TMPDIR/readonly"
mkdir -p "$RO_PARENT"
chmod -w "$RO_PARENT"
RD="$RO_PARENT/runs/some-id"
if [ "$(id -u)" -eq 0 ]; then
    echo "  (skipping: running as root, chmod -w doesn't gate root)"
else
    if allocate_run_dir "$RD"; then
        echo "FAIL: unwritable-parent allocation should have returned non-zero"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    if grep -q "collision" "$LOG_CAPTURE"; then
        echo "FAIL: real mkdir failure was mislabeled as 'collision'"
        cat "$LOG_CAPTURE"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    if ! grep -q "failed to create" "$LOG_CAPTURE"; then
        echo "FAIL: parent-create failure not logged"
        cat "$LOG_CAPTURE"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    chmod +w "$RO_PARENT"
fi

# ---- discard_empty_run_dir ------------------------------------------------
# Inverse of allocate_run_dir: undoes an allocation for a review that then
# skipped cleanly. Deliberately non-recursive — the fence against destroying a
# real review's artifacts is `rmdir` refusing a non-empty dir, NOT the path
# check, so scenarios 6 and 7 are the load-bearing ones. Table-shaped: each
# scenario asks a different question (empty→gone, artifacts→kept, meta→kept,
# bad path→refused-and-untouched), not the same question with one input swapped.

echo "  scenario 5: freshly-allocated dir + run.log → removed, returns 0..."
RD="$TMPDIR/state/runs/discard-empty-id"
allocate_run_dir "$RD" || { echo "FAIL: setup allocation failed"; exit 1; }
echo "[ts] Reviewing test/repo#1" > "$RD/run.log"
if ! discard_empty_run_dir "$RD"; then
    echo "FAIL: discard returned non-zero on an empty run dir"
    exit 1
fi
if [ -e "$RD" ]; then
    echo "FAIL: run dir survived discard"
    ls -laR "$RD"
    exit 1
fi

# Both artifact scenarios carry a run.log, because that is the shape of every
# real run dir (review-one-pr.sh points LOG_FILE at RUN_DIR/run.log the moment
# it allocates). Sparing output.md/meta.json while stripping the log of the run
# that wrote them is a half-kept promise, so the log survival IS the assertion.
echo "  scenario 6: dir holding aggregator output → kept INTACT (incl. run.log), returns 1..."
RD="$TMPDIR/state/runs/discard-output-id"
allocate_run_dir "$RD" || { echo "FAIL: setup allocation failed"; exit 1; }
echo "[ts] Reviewing test/repo#1" > "$RD/run.log"
mkdir -p "$RD/agents/aggregator"
echo "review body" > "$RD/agents/aggregator/output.md"
if discard_empty_run_dir "$RD"; then
    echo "FAIL: discard returned 0 on a dir holding artifacts"
    exit 1
fi
if [ ! -f "$RD/agents/aggregator/output.md" ]; then
    echo "FAIL: discard destroyed a review's aggregator output"
    exit 1
fi
if [ ! -f "$RD/run.log" ]; then
    echo "FAIL: discard stripped run.log from a dir whose artifacts it spared"
    exit 1
fi

echo "  scenario 7: dir holding meta.json → kept INTACT (incl. run.log), returns 1..."
RD="$TMPDIR/state/runs/discard-meta-id"
allocate_run_dir "$RD" || { echo "FAIL: setup allocation failed"; exit 1; }
echo "[ts] Reviewing test/repo#1" > "$RD/run.log"
echo '{"pr_id":"test/repo#1"}' > "$RD/meta.json"
if discard_empty_run_dir "$RD"; then
    echo "FAIL: discard returned 0 on a dir holding meta.json"
    exit 1
fi
if [ ! -f "$RD/meta.json" ]; then
    echo "FAIL: discard destroyed meta.json"
    exit 1
fi
if [ ! -f "$RD/run.log" ]; then
    echo "FAIL: discard stripped run.log from a dir whose meta.json it spared"
    exit 1
fi

echo "  scenario 8: path fence — non-runs root, traversal, trailing slash, runs root, empty → all refused..."
OUTSIDE="$TMPDIR/not-a-run-root/somedir"
mkdir -p "$OUTSIDE"
echo "keepme" > "$OUTSIDE/run.log"
# The trailing-slash and bare-runs-root entries matter most: `*/runs/*` matches
# "<state>/runs/" with an empty tail, so without them the fence would admit the
# runs/ ROOT itself as a discard target.
EMPTY_RUNS_ROOT="$TMPDIR/fence/runs"
mkdir -p "$EMPTY_RUNS_ROOT"
for bad in "$OUTSIDE" "$TMPDIR/state/runs/../not-a-run-root/somedir" \
           "$EMPTY_RUNS_ROOT/" "$EMPTY_RUNS_ROOT" ""; do
    if discard_empty_run_dir "$bad"; then
        echo "FAIL: path fence accepted '$bad'"
        exit 1
    fi
done
if [ ! -f "$OUTSIDE/run.log" ]; then
    echo "FAIL: path fence refused but deleted run.log anyway"
    exit 1
fi
if [ ! -d "$EMPTY_RUNS_ROOT" ]; then
    echo "FAIL: path fence let the runs/ root itself be removed"
    exit 1
fi

echo "  scenario 9: '..' as a substring (not a path component) is NOT traversal..."
RD="$TMPDIR/state/runs/weird..slug__1__20260101T000000000Z__aaaaaaa"
allocate_run_dir "$RD" || { echo "FAIL: setup allocation failed"; exit 1; }
echo "[ts] Reviewing test/repo#1" > "$RD/run.log"
if ! discard_empty_run_dir "$RD"; then
    echo "FAIL: fence rejected a legitimate path containing '..' inside a component"
    exit 1
fi
if [ -e "$RD" ]; then
    echo "FAIL: run dir survived discard"
    exit 1
fi

echo "  PASS (9 scenarios: clean allocation, collision detected, subdir-failure rollback, real failure not mislabeled, discard empty/artifacts+log-kept/meta+log-kept/path-fenced/dotdot-substring-allowed)"
