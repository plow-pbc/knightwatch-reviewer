#!/usr/bin/env bash
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
. "$SCRIPT_DIR/tests/worker-smoke-helpers.sh"

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

write_worker_flock_stub_if_missing "$HOME/.local/bin"

write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"

# Stage installed prompts the worker fail-fast-checks for. probe-schema.md
# is the only one currently required (lib/review-one-pr.sh:962); install.sh
# would symlink the whole prompts/ dir on a real host.
mkdir -p "$HOME/.pr-reviewer/prompts"
cp "$PROJECT_ROOT/prompts/probe-schema.md" "$HOME/.pr-reviewer/prompts/probe-schema.md"

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
# Fixed DISPATCHER_TICK_AT (real worker invocation) so the meta.json
# started_at assertion below proves lib/review-one-pr.sh honors the
# env var. orchestrator-skip-smoke scenario 19 fences the orchestrator
# pass-through; this fences the worker write.
EXPECTED_TICK_AT="2026-04-30T16:14:23Z"
# Title with embedded LF + DEL byte to fence the worker-boundary
# control-byte normalization (review-one-pr.sh:19). Without the strip,
# `Bad\nTitle\177X` would land in meta.json.title and the prompt
# {{PR_TITLE}} header, injecting prompt content past the read-only fence.
DIRTY_TITLE=$'Bad\nTitle\177X'
TRIGGER_COMMENT_FILE="" \
DISPATCHER_TICK_AT="$EXPECTED_TICK_AT" \
    bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
    "test-org/probe-repo" "1" "$OLD_PR_SHA" "feat/test" "$DIRTY_TITLE" "false" \
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

# probe-schema.md staging gate: the worker MUST stage the canonical probe
# contract under inputs/ — silent omission would let the prompt-build
# pipeline run without the schema and the smoke wouldn't notice. Asserts
# write_scratch's probe-schema.md write at lib/review-one-pr.sh:959.
if [ ! -s "$RUN_DIR/inputs/probe-schema.md" ]; then
    echo "FAIL: $RUN_DIR/inputs/probe-schema.md not staged — worker skipped probe-schema write_scratch"
    exit 1
fi

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

meta_started_at=$(jq -r '.started_at' "$META")
if [ "$meta_started_at" != "$EXPECTED_TICK_AT" ]; then
    echo "FAIL: meta.json.started_at = $meta_started_at (expected $EXPECTED_TICK_AT from DISPATCHER_TICK_AT env var — worker fell back to script-entry time, reopening the slash-cutoff race the PR fixes)"
    exit 1
fi

# Title sanitizer fence: control bytes from the worker-arg title must be
# replaced with spaces before meta.json.title is written. A regression
# that drops the `tr '\000-\037\177' ' '` at lib/review-one-pr.sh:19
# would land literal LF / DEL in meta.json.title and reopen the prompt-
# injection vector at prompts/common-header.md.
meta_title=$(jq -r '.title' "$META")
expected_title="Bad Title X"
if [ "$meta_title" != "$expected_title" ]; then
    echo "FAIL: meta.json.title = [$meta_title] (expected [$expected_title] — control bytes should be normalized to space at the worker boundary)"
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
# Also covers the post-update-ref variant of the same abort message.
if grep -qE "refs/(remotes/origin|heads)/release-1.0 missing after canonical fetch" "$LOG2"; then
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

# ===== Scenario 3: align canonical refs/heads/$BASE_REF with refs/remotes =====
# Reproduces the production bug from cncorp/plow#568 (post-PR #36 deploy).
#
# The bug: PR #36 captures BASE_REF_SHA from canonical's
# `refs/remotes/origin/$BASE_REF` (advanced by the just-completed
# `git fetch origin $BASE_REF`). For SHALLOW canonical clones (cncorp/plow
# uses --depth=500), `git clone --shared` does NOT set up
# `objects/info/alternates` in the workdir — git silently falls back to a
# non-local clone path with `warning: source repository is shallow,
# ignoring --local`. The workdir can only reach objects via refs propagated
# from canonical's `refs/heads/*` → workdir's `refs/remotes/origin/*`.
# Anything reachable only from canonical's `refs/remotes/origin/*` is NOT
# in the workdir's object set. So `git diff $BASE_REF_SHA...$REVIEWED_SHA`
# errors with "Invalid symmetric difference expression" but bash captures
# the empty stdout and the bot reads "empty diff" → aborts. Every
# cncorp/plow PR review aborted at the diff stage post-deploy.
#
# Fix: align canonical's `refs/heads/$BASE_REF` with `refs/remotes/origin/
# $BASE_REF` via `update-ref` BEFORE the clone. Then the workdir's
# `refs/remotes/origin/$BASE_REF` (mirrored from canonical's heads)
# holds the fresh SHA — and its objects are now reachable in the workdir.
#
# Assertion strategy: a smoke fixture can't faithfully reproduce the
# empty-diff abort (the worker's --depth=500 fetch deepens the test's
# tiny canonical past its shallow boundary, undoing shallow-ness — which
# doesn't happen in production where the real history is much deeper than
# 500). What we CAN reliably assert is the invariant the fix establishes:
# after the worker runs, canonical's refs/heads/$BASE_REF MUST equal
# refs/remotes/origin/$BASE_REF. Without the fix, a default `git fetch`
# only updates the remote-tracking ref; refs/heads/main would stay at
# whatever it was when canonical was first cloned. With the fix, the
# update-ref propagates the fresh SHA so clone --shared (which mirrors
# canonical's heads to workdir's remotes) gives the workdir a usable
# base ref regardless of shallow state.

echo "  scenario: canonical refs/heads/main aligned with refs/remotes/origin/main..."

GITHUB_BARE3="$TMPDIR/github-side-3.git"
git init -q --bare -b main "$GITHUB_BARE3"

WORKING3="$TMPDIR/working-3"
git clone -q "$GITHUB_BARE3" "$WORKING3"
(
    cd "$WORKING3"
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    # M1: initial main (what canonical's refs/heads/main lands at on
    # first clone). The PR forks from here.
    echo "main v1" > main-content.txt
    git add main-content.txt
    git commit -qm "main v1"
    git push -q origin main
    # PR branch off M1.
    git checkout -qb feat/test
    echo "PR feature content" > feature.txt
    git add feature.txt
    git commit -qm "PR feature on M1 main"
    git push -q origin feat/test
    git push -q origin "+refs/heads/feat/test:refs/pull/3/head"
)
PR_SHA3=$(git -C "$WORKING3" rev-parse refs/heads/feat/test)

STATE3="$TMPDIR/state-3"
mkdir -p "$STATE3/runs" "$STATE3/canonical-locks" "$STATE3/locks" "$STATE3/repos" "$STATE3/workdirs"
echo "{}" > "$STATE3/state.json"

CANONICAL3="$STATE3/repos/test-org_probe-repo"
mkdir -p "$(dirname "$CANONICAL3")"
git clone -q "$GITHUB_BARE3" "$CANONICAL3"
# Move HEAD off main onto a synthetic pr-2 branch so the worker's
# update-ref of refs/heads/main has the same shape as production
# (where canonical's HEAD is on a leftover pr-N branch from a prior
# review, not on main). This isn't strictly required for the
# invariant assertion, but matches the production topology.
git -C "$CANONICAL3" checkout -qb pr-leftover

# M2: main lands on GITHUB-side AFTER canonical clone — drives the
# refs/heads vs refs/remotes/origin staleness in canonical post-fetch.
(
    cd "$WORKING3"
    git checkout -q main
    echo "main v2" >> main-content.txt
    git add main-content.txt
    git commit -qm "main v2 (lands after canonical clone — drives staleness)"
    git push -q origin main
)

# Stub gh — base is "main", PR head is the feat/test SHA.
write_gh_stub "$HOME/.local/bin/gh" "main" "$PR_SHA3"

(
    export STATE_DIR="$STATE3"
    export STATE_FILE="$STATE3/state.json"
    export REPOS_DIR="$STATE3/repos"
    export WORKDIRS_DIR="$STATE3/workdirs"
    export CANONICAL_LOCKS_DIR="$STATE3/canonical-locks"
    export PR_REVIEW_LOCK_DIR="$STATE3/locks"
    write_probe_repos_conf "$STATE3/repos.conf"
    TRIGGER_COMMENT_FILE="" \
        bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        "test-org/probe-repo" "3" "$PR_SHA3" "feat/test" "Shallow base PR" "false" \
        >/dev/null 2>&1 || true
)

RUN_DIR3=$(find "$STATE3/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR3" ]; then
    echo "FAIL: scenario 3 — worker produced no run dir under $STATE3/runs"
    exit 1
fi
LOG3="$RUN_DIR3/run.log"

# Worker MUST NOT abort with the empty-diff message — that's the
# production failure mode (cncorp/plow#568). Belt-and-suspenders check;
# unlikely to trip in a non-shallow fixture but loud-fail if it does.
if grep -qE "local git diff origin/main\.{3}.* returned empty" "$LOG3"; then
    echo "FAIL: scenario 3 — worker hit empty-diff abort (the cncorp/plow#568 bug not fixed)"
    cat "$LOG3"
    exit 1
fi

# Decisive assertion: after the worker runs, canonical's
# refs/heads/$BASE_REF MUST equal refs/remotes/origin/$BASE_REF.
# That's the invariant the fix establishes via update-ref. Without the
# fix, `git fetch origin main` only updates the remote-tracking ref;
# refs/heads/main stays at whatever it was when canonical was first
# cloned. With the fix, update-ref propagates the fresh SHA.
HEADS_MAIN=$(git -C "$CANONICAL3" rev-parse refs/heads/main 2>/dev/null)
ORIGIN_MAIN=$(git -C "$CANONICAL3" rev-parse refs/remotes/origin/main 2>/dev/null)
if [ "$HEADS_MAIN" != "$ORIGIN_MAIN" ]; then
    echo "FAIL: scenario 3 — canonical refs/heads/main ($HEADS_MAIN) != refs/remotes/origin/main ($ORIGIN_MAIN)"
    echo "  the update-ref alignment didn't run; clone --shared from this canonical would"
    echo "  serve a stale base SHA to the workdir, breaking the diff for shallow canonicals"
    exit 1
fi

# Note: the "update-ref BEFORE clone --shared" ordering can't be
# directly fenced here. A smoke fixture's canonical gets deepened by
# the worker's --depth=500 fetch and ends up non-shallow, so
# clone --shared sets up alternates and the workdir reaches the
# post-update-ref SHA via alternates regardless of timing. The
# production-relevant failure mode requires a deeper-than-500-commit
# shallow canonical. The canonical-state assertion above + the
# full-diff.patch content check below cover the production-relevant
# failure modes — an unreachable BASE_REF_SHA produces an empty diff,
# tripping the content check.

# Positive consumer: the worker should have produced a non-empty
# full-diff.patch whose contents include the PR feature.
FULL_DIFF3="$RUN_DIR3/inputs/full-diff.patch"
if [ ! -f "$FULL_DIFF3" ]; then
    echo "FAIL: scenario 3 — worker did not write $FULL_DIFF3 (likely aborted before diff stage)"
    cat "$LOG3"
    exit 1
fi
if ! grep -q "PR feature content" "$FULL_DIFF3"; then
    echo "FAIL: scenario 3 — full-diff.patch missing PR-feature content"
    cat "$FULL_DIFF3"
    exit 1
fi

echo "  PASS (3 scenarios: orchestrator/worker SHA race + non-default-base canonical→workdir ref propagation + canonical heads/main aligned with origin/main; both diff and commits consumers fenced)"

# ===== Scenario 4: worker dedup gate fires on fetched head =====
# Fences the gate at lib/review-one-pr.sh (post canonical fetch, pre
# placeholder POST). Setup reuses scenario 1's bare repo so refs/pull/1/
# head is NEW_PR_SHA; we seed a prior author-visible run with
# reviewed_sha = NEW_PR_SHA AND invoke the worker with PR_SHA =
# OLD_PR_SHA (stale dispatcher). The worker fetches refs/pull/1/head →
# FETCHED_HEAD_SHA = NEW_PR_SHA, matches reviewed_sha → gate fires.
# Observable: run.log contains the skip line AND does NOT contain a
# "posted reviewing placeholder" log line.
#
# Specifically fencing the FETCHED-head comparison (not just any
# PR_SHA == reviewed_sha equivalence) is what catches regressions that
# would skip the gate when the dispatcher's PR_SHA disagrees with the
# truth post-fetch.
echo "  scenario: worker dedup gate fires when fetched head matches prior author-visible reviewed_sha..."

GATE_RUN_ID="test-org_probe-repo__1__20260101T000000000Z__newpr12"
GATE_RUN_DIR="$STATE_DIR/runs/$GATE_RUN_ID"
mkdir -p "$GATE_RUN_DIR"
cat > "$GATE_RUN_DIR/meta.json" <<EOF
{
  "pr_id": "test-org/probe-repo#1",
  "reviewed_sha": "$NEW_PR_SHA",
  "posted_at": "2026-01-01T00:00:00Z"
}
EOF

TRIGGER_COMMENT_FILE="" \
    bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
    "test-org/probe-repo" "1" "$OLD_PR_SHA" "feat/test" "Test PR" "false" \
    >/dev/null 2>&1
GATE_EC=$?

# The worker DOES allocate a run-dir before the gate fires; find the new
# one (excluding the seeded fake run-dir and scenario 1's run-dir).
GATE_RUN=$(find "$STATE_DIR/runs" -maxdepth 1 -type d -name 'test-org_probe-repo__1__*' -newer "$GATE_RUN_DIR" | head -1)
if [ -z "$GATE_RUN" ]; then
    echo "FAIL: scenario 4 — worker allocated no run-dir (aborted before allocate_run_dir)"
    exit 1
fi
GATE_LOG="$GATE_RUN/run.log"

if [ "$GATE_EC" -ne 0 ]; then
    echo "FAIL: scenario 4 — worker exited $GATE_EC (expected 0 from clean gate skip)"
    [ -f "$GATE_LOG" ] && { echo "--- run.log ---"; cat "$GATE_LOG"; }
    exit 1
fi
if ! grep -q "fetched head .* already reviewed by concurrent worker" "$GATE_LOG"; then
    echo "FAIL: scenario 4 — run.log missing the post-fetch dedup-gate skip line"
    [ -f "$GATE_LOG" ] && { echo "--- run.log ---"; cat "$GATE_LOG"; }
    exit 1
fi
if grep -q "posted reviewing placeholder" "$GATE_LOG"; then
    echo "FAIL: scenario 4 — placeholder WAS posted (gate fired too late / not at all)"
    cat "$GATE_LOG"
    exit 1
fi

# ===== Scenario 5: container-mode gate skips untrusted-author PRs =====
# codex review agents run sandbox-bypassed and share the privileged dind
# daemon's netns, so reviewing an UNTRUSTED-author PR risks prompt-injection →
# host root. In REVIEWER_CONTAINER_MODE the worker must skip an untrusted author
# entirely — before any placeholder, clone, or codex. The decisive contrast:
# scenarios 1-4 use the SAME gh stub (author test-user, `gh api …permission`
# → empty → untrusted) but WITHOUT container mode, and the worker proceeds to
# clone/meta.json. Flipping only REVIEWER_CONTAINER_MODE must flip to a skip.
echo "  scenario: container-mode gate skips untrusted-author PR before placeholder/clone..."
STATE5="$TMPDIR/state-5"
mkdir -p "$STATE5/runs" "$STATE5/canonical-locks" "$STATE5/locks" "$STATE5/repos" "$STATE5/workdirs"
echo "{}" > "$STATE5/state.json"
write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"   # author=test-user; permission unset → untrusted
(
    export STATE_DIR="$STATE5" STATE_FILE="$STATE5/state.json" REPOS_DIR="$STATE5/repos" \
           WORKDIRS_DIR="$STATE5/workdirs" CANONICAL_LOCKS_DIR="$STATE5/canonical-locks" \
           PR_REVIEW_LOCK_DIR="$STATE5/locks" REVIEWER_CONTAINER_MODE=1
    write_probe_repos_conf "$STATE5/repos.conf"
    TRIGGER_COMMENT_FILE="" \
        bash "$PROJECT_ROOT/lib/review-one-pr.sh" \
        "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Untrusted PR" "false" \
        >/dev/null 2>&1
)
GATE5_EC=$?
RUN5=$(find "$STATE5/runs" -maxdepth 1 -type d -name 'test-org_probe-repo__1__*' | head -1)
if [ -z "$RUN5" ]; then
    echo "FAIL: scenario 5 — worker allocated no run-dir"
    exit 1
fi
LOG5="$RUN5/run.log"
if [ "$GATE5_EC" -ne 0 ]; then
    echo "FAIL: scenario 5 — worker exited $GATE5_EC (expected 0 from clean container-mode untrusted skip)"
    [ -f "$LOG5" ] && { echo "--- run.log ---"; cat "$LOG5"; }
    exit 1
fi
if ! grep -q "skipping review — untrusted author" "$LOG5"; then
    echo "FAIL: scenario 5 — run.log missing the container-mode untrusted-author skip line"
    [ -f "$LOG5" ] && { echo "--- run.log ---"; cat "$LOG5"; }
    exit 1
fi
if grep -q "posted reviewing placeholder" "$LOG5"; then
    echo "FAIL: scenario 5 — placeholder WAS posted (untrusted PR reached the pipeline in container mode)"
    cat "$LOG5"
    exit 1
fi

echo "  PASS (5 scenarios: SHA race + non-default-base + canonical alignment + worker dedup gate + container-mode untrusted-author skip)"
