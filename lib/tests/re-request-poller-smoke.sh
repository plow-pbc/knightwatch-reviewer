#!/bin/bash
# Smoke test for re-request-poller.sh.
#
# Closes the runtime-coverage gap on the manifest consumer that
# translates GitHub "Re-request review" timeline events into
# /srosro-review trigger comments. Same shape as the other
# per-consumer smokes (approve-from-replies-smoke, learn-from-replies-smoke,
# orchestrator-skip-smoke): sandbox STATE_DIR, stub gh via PATH,
# exercise the script end-to-end, assert log lines + seen-file state.
#
# Scenarios:
#   1. No review_requested events → no /srosro-review trigger; seen file unchanged.
#   2. New review_requested event targeting BOT_USER → exactly 1 trigger
#      comment posted, seen marker advances to that event's timestamp.
#   3. Already-seen event (LATEST <= LAST_SEEN) → no second trigger.
#   4. REPOS override via config.env honored (regression coverage matching
#      the same class fixed for approve-from-replies and learn-from-replies).
#   5. review_requested targeting a non-BOT user → ignored.
#   6. gh pr comment fails on the trigger post → no seen advance, so a
#      future tick re-attempts the trigger (at-most-once-per-tick model).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t re-request-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export LOG_FILE="$STATE_DIR/re-request.log"
export SEEN_FILE="$STATE_DIR/re-request-seen.json"
mkdir -p "$STATE_DIR"
export BOT_USER="srosro"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

export STUB_PR_LIST_LOG="$STATE_DIR/gh-pr-list.log"
export STUB_COMMENT_LOG="$STATE_DIR/gh-pr-comment.log"
export MOCK_TIMELINE_FILE="$TMPDIR/timeline.json"
echo "[]" > "$MOCK_TIMELINE_FILE"

# Stub gh — same shape as the sibling smokes.
#   pr list --repo X      → [{"number":1}] only for STUB_TRACKED_REPO.
#   api .../timeline      → cat $MOCK_TIMELINE_FILE.
#   pr comment ...        → log to STUB_COMMENT_LOG; exit 1 if MOCK_PR_COMMENT_FAIL=1.
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
    repo=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--repo" ]; then
            j=$((i+1))
            repo="${!j}"
            break
        fi
    done
    echo "PR_LIST repo=$repo" >> "${STUB_PR_LIST_LOG:-/dev/null}"
    if [ "$repo" = "${STUB_TRACKED_REPO:-test-org/probe-repo}" ]; then
        echo '[{"number":1}]'
    else
        echo '[]'
    fi
elif [ "$1" = "pr" ] && [ "$2" = "comment" ]; then
    repo="" body=""
    for ((i=1; i<=$#; i++)); do
        if [ "${!i}" = "--repo" ]; then
            j=$((i+1)); repo="${!j}"
        elif [ "${!i}" = "--body" ]; then
            j=$((i+1)); body="${!j}"
        fi
    done
    echo "COMMENT repo=$repo body=$body" >> "${STUB_COMMENT_LOG:-/dev/null}"
    [ -n "${MOCK_PR_COMMENT_FAIL:-}" ] && exit 1
    echo "https://github.com/$repo/issues/1#issuecomment-fake"
elif [ "$1" = "api" ]; then
    cat "$MOCK_TIMELINE_FILE"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Sandbox lib dir: only tracked-repos.sh is needed; the script itself
# uses jq directly (no lib helpers).
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"

# REPOS override via config.env. test-org/probe-repo is NOT in the
# canonical repos.conf (cncorp/plow, ...), so honoring the override
# means polling probe-repo only; clobbering the override means polling
# the canonical list and missing the probe entirely.
cat > "$STATE_DIR/config.env" <<'CONF'
REPOS=("test-org/probe-repo")
CONF
export STUB_TRACKED_REPO="test-org/probe-repo"

run_poller() {
    : > "$STUB_PR_LIST_LOG"
    : > "$STUB_COMMENT_LOG"
    : > "$LOG_FILE"
    bash "$PROJECT_ROOT/re-request-poller.sh" >/dev/null 2>&1 || true
}

count_comments() {
    # `grep -c` prints the count even when zero; only its exit code
    # is non-zero on no matches. `|| true` swallows the exit; we keep
    # grep's "0" output. Without this, an `|| echo 0` fallback fires
    # in addition to grep's print and yields "0\n0".
    grep -c '^COMMENT ' "$STUB_COMMENT_LOG" 2>/dev/null || true
}

# Scenario 1: no review_requested events → nothing posted, seen unchanged.
echo "  scenario 1: no review_requested events — no trigger posted..."
echo '[]' > "$MOCK_TIMELINE_FILE"
echo '{}' > "$SEEN_FILE"
run_poller
n=$(count_comments)
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 comments, got $n"; cat "$STUB_COMMENT_LOG"; exit 1; }
# REPOS override regression: the script polled probe-repo, not the canonical list.
grep -q 'PR_LIST repo=test-org/probe-repo' "$STUB_PR_LIST_LOG" || { echo "FAIL scenario 1: expected probe-repo poll (REPOS override clobbered?)"; cat "$STUB_PR_LIST_LOG"; exit 1; }
grep -q 'PR_LIST repo=cncorp/plow' "$STUB_PR_LIST_LOG" && { echo "FAIL scenario 1: canonical list polled — REPOS override clobbered"; cat "$STUB_PR_LIST_LOG"; exit 1; }

# Scenario 2: new review_requested for BOT_USER → 1 trigger, seen advances.
echo "  scenario 2: new review_requested for BOT_USER — 1 trigger posted, seen advances..."
cat > "$MOCK_TIMELINE_FILE" <<'TL'
[{"event":"review_requested","requested_reviewer":{"login":"srosro"},"created_at":"2026-04-29T10:00:00Z"}]
TL
echo '{}' > "$SEEN_FILE"
run_poller
n=$(count_comments)
[ "$n" -eq 1 ] || { echo "FAIL scenario 2: expected 1 comment, got $n"; cat "$STUB_COMMENT_LOG"; exit 1; }
grep -q 'body=/srosro-review' "$STUB_COMMENT_LOG" || { echo "FAIL scenario 2: comment body missing /srosro-review trigger"; cat "$STUB_COMMENT_LOG"; exit 1; }
seen=$(jq -r '."test-org/probe-repo#1" // empty' "$SEEN_FILE")
[ "$seen" = "2026-04-29T10:00:00Z" ] || { echo "FAIL scenario 2: seen timestamp not advanced (got [$seen])"; cat "$SEEN_FILE"; exit 1; }

# Scenario 3: already-seen event → no second trigger.
echo "  scenario 3: already-seen event — no duplicate trigger..."
# Same timeline, seen file already at that timestamp.
run_poller
n=$(count_comments)
[ "$n" -eq 0 ] || { echo "FAIL scenario 3: expected 0 comments (event already seen), got $n"; cat "$STUB_COMMENT_LOG"; exit 1; }

# Scenario 4: review_requested targeting a non-BOT user → ignored.
echo "  scenario 4: review_requested for non-BOT user — ignored..."
cat > "$MOCK_TIMELINE_FILE" <<'TL'
[{"event":"review_requested","requested_reviewer":{"login":"someone-else"},"created_at":"2026-04-29T11:00:00Z"}]
TL
echo '{}' > "$SEEN_FILE"
run_poller
n=$(count_comments)
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 comments (non-BOT reviewer), got $n"; cat "$STUB_COMMENT_LOG"; exit 1; }

# Scenario 5: gh pr comment fails → no seen advance, so a retry on the
# next tick re-attempts the post.
echo "  scenario 5: gh pr comment fails — no seen advance, retry on next tick..."
cat > "$MOCK_TIMELINE_FILE" <<'TL'
[{"event":"review_requested","requested_reviewer":{"login":"srosro"},"created_at":"2026-04-29T12:00:00Z"}]
TL
echo '{}' > "$SEEN_FILE"
MOCK_PR_COMMENT_FAIL=1 run_poller
seen=$(jq -r '."test-org/probe-repo#1" // empty' "$SEEN_FILE")
[ -z "$seen" ] || { echo "FAIL scenario 5: seen advanced despite failed comment (got [$seen])"; exit 1; }
grep -q 'failed to post /srosro-review trigger comment' "$LOG_FILE" || { echo "FAIL scenario 5: expected log line about failed post"; cat "$LOG_FILE"; exit 1; }

# Scenario 6: canonical repos.conf (no override) — confirms the loader
# falls through to the canonical list when config.env doesn't set REPOS.
# We swap config.env to empty so the loader's repos.conf source path
# is the only producer of REPOS.
echo "  scenario 6: canonical repos.conf path (no config.env override)..."
: > "$STATE_DIR/config.env"   # empty — no REPOS override
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("canonical/repo")
declare -A KID_PATHS=()
CONF
echo '[]' > "$MOCK_TIMELINE_FILE"
echo '{}' > "$SEEN_FILE"
STUB_TRACKED_REPO="canonical/repo" run_poller
grep -q 'PR_LIST repo=canonical/repo' "$STUB_PR_LIST_LOG" || { echo "FAIL scenario 6: canonical repos.conf not honored"; cat "$STUB_PR_LIST_LOG"; exit 1; }

echo "  PASS (6 scenarios: empty-timeline-respects-override, new-event-triggers, already-seen-deduped, non-bot-ignored, post-failure-no-seen-advance, canonical-repos.conf-path)"
