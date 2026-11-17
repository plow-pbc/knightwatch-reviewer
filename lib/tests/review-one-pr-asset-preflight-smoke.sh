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
fail() { echo "FAIL: $*"; exit 1; }

FIXTURE_PROMPTS="$TEST_TMP/prompts"
cp -R "$PROJECT_ROOT/prompts" "$FIXTURE_PROMPTS"
rm "$FIXTURE_PROMPTS/policy.md"
FIXTURE_LIB="$TEST_TMP/lib"
cp -R "$PROJECT_ROOT/lib" "$FIXTURE_LIB"
rm "$FIXTURE_LIB/checks/python-strict-typing.sh"

assert_preflight_failure() {
    local name="$1" lib="$2" prompts="$3" asset="$4" state="$TEST_TMP/state-$1"
    echo "  scenario: missing $name aborts before GitHub access..."
    if run_worker "$state" env REVIEWER_LIB_DIR="$lib" PROMPTS_DIR="$prompts"; then fail "missing $name returned success"; fi
    [ ! -e "$state/gh-called" ] || fail "worker accessed GitHub before validating $name"
    grep -q "$asset missing" "$state/orchestrator.log" || fail "missing $name was not identified in the log"
}

assert_preflight_failure "prompt directory" "$PROJECT_ROOT/lib" "$TEST_TMP/missing-prompts" "probe-schema.md"
assert_preflight_failure "pipeline prompt" "$PROJECT_ROOT/lib" "$FIXTURE_PROMPTS" "policy.md"
assert_preflight_failure "strict-typing checker" "$FIXTURE_LIB" "$PROJECT_ROOT/prompts" "python-strict-typing.sh"

echo "  PASS (complete prompt and checker assets fail closed before GitHub access)"
