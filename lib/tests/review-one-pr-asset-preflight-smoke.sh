#!/usr/bin/env bash
# Missing reviewer assets must abort before any GitHub read or visible side effect.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_TMP=$(mktemp -d -t review-one-pr-assets-XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

STUB_BIN="$TEST_TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
touch "$GH_MARKER"
printf '{}\n'
STUB
chmod +x "$STUB_BIN/gh"

run_worker() {
    local state="$1"
    shift
    mkdir -p "$state"
    : > "$state/state.json"
    STATE_DIR="$state" \
    STATE_FILE="$state/state.json" \
    REPOS_DIR="$state/repos" \
    WORKDIRS_DIR="$state/workdirs" \
    CANONICAL_LOCKS_DIR="$state/canonical-locks" \
    PR_REVIEW_LOCK_DIR="$state/locks" \
    HOME="$TEST_TMP/home" \
    PATH="$STUB_BIN:$PATH" \
    GH_MARKER="$state/gh-called" \
        "$@" bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        test-org/probe-repo 1 deadbeef feat/test "Asset preflight" false maintainer \
        >/dev/null 2>&1
}

echo "  scenario: missing prompt asset aborts before GitHub access..."
STATE_PROMPT="$TEST_TMP/state-prompt"
if run_worker "$STATE_PROMPT" env \
    REVIEWER_LIB_DIR="$PROJECT_ROOT/lib" \
    PROMPTS_DIR="$TEST_TMP/missing-prompts"; then
    echo "FAIL: missing prompt directory returned success"
    exit 1
fi
if [ -e "$STATE_PROMPT/gh-called" ]; then
    echo "FAIL: worker called GitHub before validating prompt assets"
    exit 1
fi
if ! grep -q "probe-schema.md missing" "$STATE_PROMPT/orchestrator.log"; then
    echo "FAIL: missing prompt asset was not identified in the log"
    cat "$STATE_PROMPT/orchestrator.log" 2>/dev/null || true
    exit 1
fi

echo "  scenario: missing pipeline prompt aborts before GitHub access..."
FIXTURE_PROMPTS="$TEST_TMP/prompts"
cp -R "$PROJECT_ROOT/prompts" "$FIXTURE_PROMPTS"
rm "$FIXTURE_PROMPTS/policy.md"
STATE_POLICY="$TEST_TMP/state-policy"
if run_worker "$STATE_POLICY" env \
    REVIEWER_LIB_DIR="$PROJECT_ROOT/lib" \
    PROMPTS_DIR="$FIXTURE_PROMPTS"; then
    echo "FAIL: incomplete prompt tree returned success"
    exit 1
fi
if [ -e "$STATE_POLICY/gh-called" ]; then
    echo "FAIL: worker called GitHub before validating the complete prompt tree"
    exit 1
fi
if ! grep -q "policy.md missing" "$STATE_POLICY/orchestrator.log"; then
    echo "FAIL: missing pipeline prompt was not identified in the log"
    cat "$STATE_POLICY/orchestrator.log" 2>/dev/null || true
    exit 1
fi

echo "  scenario: missing strict-typing checker aborts before GitHub access..."
FIXTURE_LIB="$TEST_TMP/lib"
cp -R "$PROJECT_ROOT/lib" "$FIXTURE_LIB"
rm "$FIXTURE_LIB/checks/python-strict-typing.sh"
STATE_CHECKER="$TEST_TMP/state-checker"
if run_worker "$STATE_CHECKER" env \
    REVIEWER_LIB_DIR="$FIXTURE_LIB" \
    PROMPTS_DIR="$PROJECT_ROOT/prompts"; then
    echo "FAIL: missing strict-typing checker returned success"
    exit 1
fi
if [ -e "$STATE_CHECKER/gh-called" ]; then
    echo "FAIL: worker called GitHub before validating strict-typing checkers"
    exit 1
fi
if ! grep -q "python-strict-typing.sh missing" "$STATE_CHECKER/orchestrator.log"; then
    echo "FAIL: missing strict-typing checker was not identified in the log"
    cat "$STATE_CHECKER/orchestrator.log" 2>/dev/null || true
    exit 1
fi

echo "  PASS (complete prompt and checker assets fail closed before GitHub access)"
