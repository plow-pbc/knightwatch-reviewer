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

# ---- shared helpers (deduplicate scenario setup) ----

# write_gh_stub <stub_path> <base_ref> <head_oid>
#   gh pr view <N> --json baseRefName,... → returns the supplied base_ref.
#   gh pr view <N> --json headRefOid       → returns head_oid.
#   Anything else (gh pr comment, etc.)    → no-op success.
write_gh_stub() {
    local stub_path="$1" base_ref="$2" head_oid="$3"
    cat > "$stub_path" <<STUB
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
        printf '{"baseRefName":"$base_ref","title":"Test PR","body":"","author":{"login":"test-user"},"closingIssuesReferences":{"nodes":[]}}\n'
        ;;
    *headRefOid*)
        printf '{"headRefOid":"$head_oid"}\n'
        ;;
    *)
        :
        ;;
esac
STUB
    chmod +x "$stub_path"
}

# write_probe_repos_conf <conf_path>
write_probe_repos_conf() {
    cat > "$1" <<'CONF'
REPOS=("test-org/probe-repo")
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
declare -A DEAD_CODE_CMDS=()
declare -A STRICT_TYPING_CMDS=()
CONF
}

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
#   gh pr view <N> --repo <repo> --json baseRefName,title,body,author,closingIssuesReferences
#   gh pr view <N> --repo <repo> --json headRefOid (later, for stale-head check)
# Stub returns baseRefName=main, author=test-user (matches BOT_USER).
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"

# ---- repos.conf with this repo declared (worker reads it) ----
write_probe_repos_conf "$STATE_DIR/repos.conf"

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
#
# Fixture topology:
#   M1 (main: main-init.txt)
#   ├── R1 (release-1.0: release-base.txt)            ← PR's actual base
#   │    └── P1 (PR head: feature.txt)
#   └── M2 (main: main-only.txt — added AFTER fork)   ← repo default branch
#
# A buggy worker that uses the repo default (main) instead of
# baseRefName (release-1.0) as the diff base would produce
# `main...HEAD` whose merge-base with HEAD is M1 — diff includes
# release-base.txt (which the correct release-1.0...HEAD diff
# excludes). The decisive assertion is therefore: the worker's
# full-diff.patch artifact MUST NOT contain "release base content".

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
    # M1: main's initial state, shared base for both branches.
    echo "main init" > main-init.txt
    git add main-init.txt
    git commit -qm "main: init"
    git push -q origin main
    # R1: release-1.0 forks from M1.
    git checkout -qb release-1.0
    echo "release base content" > release-base.txt
    git add release-base.txt
    git commit -qm "release-1.0: base"
    git push -q origin release-1.0
    # P1: PR forks from release-1.0.
    git checkout -qb feat/test
    echo "PR feature" > feature.txt
    git add feature.txt
    git commit -qm "PR feature"
)
PR_SHA2=$(git -C "$WORKING2" rev-parse HEAD)
git -C "$WORKING2" push -q origin feat/test:refs/pull/2/head
# M2: advance main with content NOT on release-1.0 — strengthens the
# regression fence. With main advanced post-fork, a buggy main-as-base
# diff would still leak release-base.txt; the assertion is unchanged
# but the fixture matches the production topology where main moves
# while a release line is in flight.
(
    cd "$WORKING2"
    git checkout -q main
    echo "main only content" > main-only.txt
    git add main-only.txt
    git commit -qm "main: drift after release fork"
    git push -q origin main
)

# Fresh sandbox — separate STATE_DIR so the runs from scenario 1 don't
# confuse the run-dir search.
STATE2="$TMPDIR/state-2"
mkdir -p "$STATE2/runs" "$STATE2/canonical-locks" "$STATE2/locks" "$STATE2/repos" "$STATE2/workdirs"
echo "{}" > "$STATE2/state.json"

CANONICAL2="$STATE2/repos/test-org_probe-repo"
mkdir -p "$(dirname "$CANONICAL2")"
git clone -q "$GITHUB_BARE2" "$CANONICAL2"

# Stub gh — same shape, but baseRefName is "release-1.0" not "main".
write_gh_stub "$HOME/.local/bin/gh" "release-1.0" "$PR_SHA2"

(
    export STATE_DIR="$STATE2"
    export STATE_FILE="$STATE2/state.json"
    export REPOS_DIR="$STATE2/repos"
    export WORKDIRS_DIR="$STATE2/workdirs"
    export CANONICAL_LOCKS_DIR="$STATE2/canonical-locks"
    export PR_REVIEW_LOCK_DIR="$STATE2/locks"
    write_probe_repos_conf "$STATE2/repos.conf"
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

# Decisive assertion: the worker's full-diff.patch artifact (written
# pre-specialist, so the missing-codex abort doesn't suppress it) must
# reflect $BASE_REF_SHA...$REVIEWED_SHA — release-base content
# excluded, PR feature included. Asserting against the workdir's own
# diff would be tautological (we'd be reproving git's own semantics);
# asserting against the worker artifact is the regression fence.
FULL_DIFF_PATCH="$RUN_DIR2/inputs/full-diff.patch"
if [ ! -f "$FULL_DIFF_PATCH" ]; then
    echo "FAIL: scenario 2 — worker did not write $FULL_DIFF_PATCH (expected pre-specialist artifact)"
    [ -f "$LOG2" ] && { echo "--- run.log ---"; cat "$LOG2"; }
    exit 1
fi
if grep -q "release base content" "$FULL_DIFF_PATCH"; then
    echo "FAIL: scenario 2 — full-diff.patch contains release-1.0 base content (worker used wrong base — main instead of release-1.0)"
    exit 1
fi
if ! grep -q "PR feature" "$FULL_DIFF_PATCH"; then
    echo "FAIL: scenario 2 — full-diff.patch missing PR-feature content"
    exit 1
fi

# Log line should NOT contain a "missing after canonical fetch" abort
# (the round-1 finding's failure mode for non-default-base PRs).
if grep -qF "refs/remotes/origin/release-1.0 missing after canonical fetch" "$LOG2"; then
    echo "FAIL: scenario 2 — worker hit the BASE_REF_SHA-not-found abort path"
    cat "$LOG2"
    exit 1
fi

# Second consumer fence: commits.md is also derived from the post-checkout
# snapshot (`git log $BASE_REF_SHA..$REVIEWED_SHA`) — round-2 finding
# closed by sourcing it from local git instead of pre-fetch PR_DATA.
# This assertion proves the new commits-from-git seam stays sourced
# from the same SHA contract as full-diff.patch — a regression that
# rewires commits.md back to PR_DATA would silently fail the diff
# fence above (contents still match) but trip THIS one (the PR-feature
# commit message would be missing for a release-1.0 base, since
# PR_DATA's commits list is whatever gh pr view returned). commits.md
# is written after `just test` and the workdir-prelude — gh stub +
# host `just` (no justfile in fixture → tests-not-run → continue) get
# us through that. If a future refactor moves it earlier or later in
# the worker, this assertion doubles as a tripwire.
COMMITS_MD="$RUN_DIR2/inputs/commits.md"
if [ ! -f "$COMMITS_MD" ]; then
    echo "FAIL: scenario 2 — worker did not write $COMMITS_MD (expected before specialist phase)"
    [ -f "$LOG2" ] && { echo "--- run.log ---"; tail -n 30 "$LOG2"; }
    exit 1
fi
if ! grep -q "PR feature" "$COMMITS_MD"; then
    echo "FAIL: scenario 2 — commits.md missing PR-feature commit message (range likely wider than $BASE_REF_SHA..$REVIEWED_SHA)"
    cat "$COMMITS_MD"
    exit 1
fi
if grep -q "release-1.0: base" "$COMMITS_MD"; then
    echo "FAIL: scenario 2 — commits.md contains release-1.0 base commit (range too wide; should be $BASE_REF_SHA..$REVIEWED_SHA)"
    cat "$COMMITS_MD"
    exit 1
fi

echo "  PASS (2 scenarios: orchestrator/worker SHA race + non-default-base canonical→workdir ref propagation; both diff and commits consumers fenced)"
