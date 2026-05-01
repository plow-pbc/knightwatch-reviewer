#!/bin/bash
# Smoke for lib/review-one-pr.sh — fences the orchestrator/worker SHA race.
#
# When the orchestrator enumerates a PR via `gh pr list` it captures
# headRefOid as PR_SHA, then dispatches the worker. If a new push lands
# on the PR between enumeration and the worker's `git fetch
# refs/pull/N/head`, the worker checks out a DIFFERENT SHA than
# PR_SHA. The worker must use the checked-out SHA (REVIEWED_SHA) — not
# the orchestrator's enumeration SHA — when writing meta.json,
# state.json, and the posted review's "git diff X..Y" reproduction
# command. Otherwise the posted bot output describes a diff the bot
# never actually evaluated.
#
# This smoke stubs `gh` via PATH, sets up a real canonical clone whose
# `refs/pull/N/head` contains a NEWER commit than PR_SHA, runs the
# worker, and asserts:
#   - meta.json.sha equals the checked-out HEAD (REVIEWED_SHA), not PR_SHA
#   - meta.json.base_ref equals the PR's actual base (from gh pr view --json baseRefName)
#   - run.log records the "orchestrator enumerated X, worker checked out Y" mismatch
#
# state.json verification would require running the full worker through
# specialists + aggregator + gh pr comment, which is heavy scaffolding;
# meta.json is written immediately after REVIEWED_SHA capture, so it's
# the canonical signal that the post-checkout snapshot semantics held.
# The worker is allowed to abort downstream (missing codex, etc.) — the
# meta.json invariant is verified before that abort.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t review-one-pr-sha-flow-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ---- sandbox env ----
export STATE_DIR="$TMPDIR/state"
export STATE_FILE="$STATE_DIR/state.json"
export REPOS_DIR="$STATE_DIR/repos"
export WORKDIRS_DIR="$STATE_DIR/workdirs"
export CANONICAL_LOCKS_DIR="$STATE_DIR/canonical-locks"
export PR_REVIEW_LOCK_DIR="$STATE_DIR/locks"
mkdir -p "$STATE_DIR" "$REPOS_DIR" "$WORKDIRS_DIR" "$CANONICAL_LOCKS_DIR" "$PR_REVIEW_LOCK_DIR"
echo "{}" > "$STATE_FILE"
export BOT_USER="test-user"
export REVIEWER_LIB_DIR="$PROJECT_ROOT/lib"

# ---- "GitHub-side" bare repo + canonical clone ----
# Two SHAs in flight:
#   OLD_PR_SHA: what the orchestrator enumerated (passed to worker as PR_SHA arg).
#   NEW_PR_SHA: a later commit pushed to refs/pull/1/head AFTER enumeration.
#               The worker's `git fetch refs/pull/1/head` receives this; checkout
#               makes HEAD == NEW_PR_SHA; REVIEWED_SHA == NEW_PR_SHA.
GITHUB_BARE="$TMPDIR/github-side.git"
git init -q --bare -b main "$GITHUB_BARE"

WORKING="$TMPDIR/working"
git clone -q "$GITHUB_BARE" "$WORKING"
(
    cd "$WORKING"
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo "base" > README.md
    git add README.md
    git commit -qm "init"
    git push -q origin main
    git checkout -qb feat/test
    echo "feature1" > feature.txt
    git add feature.txt
    git commit -qm "feature 1"
)
OLD_PR_SHA=$(git -C "$WORKING" rev-parse HEAD)
git -C "$WORKING" push -q origin feat/test:refs/pull/1/head
# Simulate "operator pushed another commit AFTER orchestrator enum".
(
    cd "$WORKING"
    echo "feature2" > feature.txt
    git add feature.txt
    git commit -qm "feature 2 — landed AFTER orchestrator enum"
)
NEW_PR_SHA=$(git -C "$WORKING" rev-parse HEAD)
git -C "$WORKING" push -q origin feat/test:refs/pull/1/head

# Canonical: clone of the bare repo. Worker will fetch into here.
# Path matches the worker's REPO_SLUG (review-one-pr.sh:249: tr '/' '_').
CANONICAL="$REPOS_DIR/test-org_probe-repo"
mkdir -p "$(dirname "$CANONICAL")"
git clone -q "$GITHUB_BARE" "$CANONICAL"

# ---- gh stub via PATH ----
# Worker calls (in order):
#   gh pr view <N> --repo <repo> --json baseRefName,title,body,author,commits,closingIssuesReferences
#   gh pr view <N> --repo <repo> --json headRefOid (later, for stale-head check)
# Stub returns baseRefName=main, author=test-user (matches BOT_USER).
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
cat > "$HOME/.local/bin/gh" <<STUB
#!/bin/bash
# Walk args to find --json (the only thing we case on).
fields=""
for ((i=1; i<=\$#; i++)); do
    if [ "\${!i}" = "--json" ]; then
        j=\$((i+1))
        fields="\${!j}"
        break
    fi
done
case "\$fields" in
    *baseRefName*)
        # Full PR_DATA blob. headRefOid not requested in this call shape.
        printf '{"baseRefName":"main","title":"Test PR","body":"","author":{"login":"test-user"},"commits":{"nodes":[]},"closingIssuesReferences":{"nodes":[]}}\n'
        ;;
    *headRefOid*)
        # Stale-head probe — return NEW_PR_SHA so no stale warning fires.
        printf '{"headRefOid":"$NEW_PR_SHA"}\n'
        ;;
    *)
        # Anything else (gh pr comment, etc.): no-op success.
        :
        ;;
esac
STUB
chmod +x "$HOME/.local/bin/gh"

# ---- repos.conf with this repo declared (worker reads it) ----
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=("test-org/probe-repo")
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
declare -A DEAD_CODE_CMDS=()
declare -A STRICT_TYPING_CMDS=()
CONF

# ---- run the worker ----
# Pass OLD_PR_SHA as PR_SHA — simulating "this is what the orchestrator
# enumerated." The worker's fetch will receive NEW_PR_SHA, checkout
# makes HEAD that, REVIEWED_SHA captures it, meta.json records it.
#
# The worker may abort downstream (no codex on PATH, no actual LLM
# infrastructure, etc.) — that's fine. We verify meta.json BEFORE
# that abort.
echo "  scenario: PR_SHA != REVIEWED_SHA — meta.json must record REVIEWED_SHA..."
TRIGGER_COMMENT_FILE="" \
    bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
    "test-org/probe-repo" "1" "$OLD_PR_SHA" "feat/test" "Test PR" "false" \
    >/dev/null 2>&1 || true

# ---- assertions ----
# Find the run dir produced by this invocation.
RUN_DIR=$(find "$STATE_DIR/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR" ]; then
    echo "FAIL: worker produced no run dir under $STATE_DIR/runs"
    exit 1
fi

META="$RUN_DIR/meta.json"
LOG="$RUN_DIR/run.log"

if [ ! -f "$META" ]; then
    echo "FAIL: $META not written — worker aborted before meta.json"
    [ -f "$LOG" ] && { echo "--- run.log ---"; cat "$LOG"; }
    exit 1
fi

meta_sha=$(jq -r '.sha' "$META")
if [ "$meta_sha" != "$NEW_PR_SHA" ]; then
    echo "FAIL: meta.json.sha = $meta_sha (expected REVIEWED_SHA $NEW_PR_SHA — orchestrator-enumerated $OLD_PR_SHA leaked through)"
    exit 1
fi

meta_base=$(jq -r '.base_ref' "$META")
if [ "$meta_base" != "main" ]; then
    echo "FAIL: meta.json.base_ref = $meta_base (expected 'main' from gh pr view --json baseRefName)"
    exit 1
fi

# Mismatch log line: must record both SHAs (catches regressions where
# the diagnostic log silently disappears).
expected_log="orchestrator enumerated ${OLD_PR_SHA:0:7}, worker checked out ${NEW_PR_SHA:0:7}"
if ! grep -qF "$expected_log" "$LOG"; then
    echo "FAIL: run.log missing SHA-mismatch diagnostic"
    echo "  expected substring: $expected_log"
    echo "--- run.log ---"
    cat "$LOG"
    exit 1
fi

echo "  PASS (1 scenario: orchestrator-enumerated SHA != checked-out SHA → meta.json + log use REVIEWED_SHA)"
