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

echo "  comments_have_reviewed_sha: matches a bot auto-post comment carrying the head's marker..."
HEAD_SHA="deadbeefcafe1234"
COMMENTS=$(jq -n --arg m "$(reviewed_sha_marker "$HEAD_SHA")" '[
  {body: "<!-- knightwatch-reviewer:auto-post -->\n\($m)\n\n📋 Re-review …\nVERDICT: COMMENT"},
  {body: "/srosro-review"}
]')
comments_have_reviewed_sha "$COMMENTS" "$HEAD_SHA" || { echo "FAIL: should match present marker"; exit 1; }

echo "  comments_have_reviewed_sha: no match when the marker SHA differs (head moved)..."
comments_have_reviewed_sha "$COMMENTS" "0000000000000000" && { echo "FAIL: should not match a different head"; exit 1; } || true

echo "  comments_have_reviewed_sha: no match when no bot comment carries a marker..."
PLAIN=$(jq -n '[{body: "looks good to me"}, {body: "/srosro-review"}]')
comments_have_reviewed_sha "$PLAIN" "$HEAD_SHA" && { echo "FAIL: should not match without a marker"; exit 1; } || true

echo "  PASS (4 scenarios: clean allocation, collision detected, subdir-failure rollback, real failure not mislabeled + 3 comments_have_reviewed_sha)"
