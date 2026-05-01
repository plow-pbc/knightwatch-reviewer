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

# ===== Scenario 2: non-default-base PR =====
# Closes the round-1 [blocking] finding: when the PR's base is NOT the
# canonical's checked-out default branch, `git fetch origin "$BASE_REF"`
# updates canonical's `refs/remotes/origin/$BASE_REF` (a remote-tracking
# ref). `git clone --shared` does NOT propagate that as `origin/<ref>`
# in the workdir — only `refs/heads/*` does. Capturing BASE_REF_SHA
# from canonical (immutable SHA, reachable in the workdir via shared
# objects) before the clone is the fix; the smoke proves it works on a
# release-base fixture.

echo "  scenario: non-default-base PR (base=release-1.0, canonical default=main)..."

GITHUB_BARE2="$TMPDIR/github-side-2.git"
git init -q --bare -b main "$GITHUB_BARE2"

WORKING2="$TMPDIR/working-2"
git clone -q "$GITHUB_BARE2" "$WORKING2"
(
    cd "$WORKING2"
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    # main: has main-only content (must NOT leak into the PR diff).
    echo "main-only content" > main-only.txt
    git add main-only.txt
    git commit -qm "main: init"
    git push -q origin main
    # release-1.0: branched from main but evolved separately.
    git checkout -qb release-1.0
    echo "release base content" > release-base.txt
    git add release-base.txt
    git commit -qm "release-1.0: base"
    git push -q origin release-1.0
    # PR branch: forks from release-1.0.
    git checkout -qb feat/test
    echo "PR feature" > feature.txt
    git add feature.txt
    git commit -qm "PR feature"
)
PR_SHA2=$(git -C "$WORKING2" rev-parse HEAD)
RELEASE_BASE_SHA=$(git -C "$WORKING2" rev-parse release-1.0)
git -C "$WORKING2" push -q origin feat/test:refs/pull/2/head

# Fresh sandbox — separate STATE_DIR so the runs from scenario 1 don't
# confuse the run-dir search.
STATE2="$TMPDIR/state-2"
mkdir -p "$STATE2/runs" "$STATE2/canonical-locks" "$STATE2/locks" "$STATE2/repos" "$STATE2/workdirs"
echo "{}" > "$STATE2/state.json"

CANONICAL2="$STATE2/repos/test-org_probe-repo"
mkdir -p "$(dirname "$CANONICAL2")"
git clone -q "$GITHUB_BARE2" "$CANONICAL2"

# Stub gh — same shape, but baseRefName is "release-1.0" not "main".
cat > "$HOME/.local/bin/gh" <<STUB
#!/bin/bash
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
        printf '{"baseRefName":"release-1.0","title":"Release-base PR","body":"","author":{"login":"test-user"},"commits":{"nodes":[]},"closingIssuesReferences":{"nodes":[]}}\n'
        ;;
    *headRefOid*)
        printf '{"headRefOid":"$PR_SHA2"}\n'
        ;;
    *)
        :
        ;;
esac
STUB

(
    export STATE_DIR="$STATE2"
    export STATE_FILE="$STATE2/state.json"
    export REPOS_DIR="$STATE2/repos"
    export WORKDIRS_DIR="$STATE2/workdirs"
    export CANONICAL_LOCKS_DIR="$STATE2/canonical-locks"
    export PR_REVIEW_LOCK_DIR="$STATE2/locks"
    cat > "$STATE2/repos.conf" <<'CONF'
REPOS=("test-org/probe-repo")
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
declare -A DEAD_CODE_CMDS=()
declare -A STRICT_TYPING_CMDS=()
CONF
    TRIGGER_COMMENT_FILE="" \
        bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        "test-org/probe-repo" "2" "$PR_SHA2" "feat/test" "Release-base PR" "false" \
        >/dev/null 2>&1 || true
)

RUN_DIR2=$(find "$STATE2/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR2" ]; then
    echo "FAIL: scenario 2 — worker produced no run dir under $STATE2/runs"
    exit 1
fi
META2="$RUN_DIR2/meta.json"
LOG2="$RUN_DIR2/run.log"

if [ ! -f "$META2" ]; then
    echo "FAIL: scenario 2 — $META2 not written; worker aborted before BASE_REF_SHA capture"
    [ -f "$LOG2" ] && { echo "--- run.log ---"; cat "$LOG2"; }
    exit 1
fi

meta_base2=$(jq -r '.base_ref' "$META2")
if [ "$meta_base2" != "release-1.0" ]; then
    echo "FAIL: scenario 2 — meta.json.base_ref = $meta_base2 (expected 'release-1.0')"
    exit 1
fi

# The decisive assertion: BASE_REF_SHA (captured from canonical after
# fetch, used as the diff base) must equal the SHA of release-1.0 in
# the bare repo — proving the worker resolved the non-default base
# correctly across the canonical→workdir boundary.
WORKDIR2="$STATE2/workdirs/test-org_probe-repo__2"
if [ -d "$WORKDIR2" ]; then
    workdir_diff=$(git -C "$WORKDIR2" diff "$RELEASE_BASE_SHA"...HEAD 2>/dev/null)
    if printf '%s' "$workdir_diff" | grep -q "main-only"; then
        echo "FAIL: scenario 2 — FULL_PR_DIFF range includes main-only content (should be release-1.0...HEAD)"
        exit 1
    fi
    if ! printf '%s' "$workdir_diff" | grep -q "PR feature"; then
        echo "FAIL: scenario 2 — FULL_PR_DIFF range missing PR-feature content"
        exit 1
    fi
fi

# Log line should NOT contain a "could not resolve" abort (the round-1
# finding's failure mode for non-default-base PRs).
if grep -qF "could not resolve canonical's release-1.0 SHA" "$LOG2"; then
    echo "FAIL: scenario 2 — worker hit the BASE_REF_SHA-not-found abort path"
    cat "$LOG2"
    exit 1
fi

echo "  PASS (2 scenarios: orchestrator/worker SHA race + non-default-base canonical→workdir ref propagation)"
