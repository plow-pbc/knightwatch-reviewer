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

# seed_state_dir <state_dir> — create the worker's state subdirs + empty
# state.json that every scenario needs. (The canonical clone varies per
# scenario — different paths, some skip it — so it stays explicit at the call
# site.)
seed_state_dir() {
    mkdir -p "$1/runs" "$1/canonical-locks" "$1/locks" "$1/repos" "$1/workdirs"
    echo "{}" > "$1/state.json"
}

# assert_no_probe_pr1_run_dir STATE_DIR LABEL — fail if the worker allocated a
# run dir for probe-repo#1 under STATE_DIR. The pre-allocation gates (issue #189)
# must skip/abort before allocate_run_dir, so a leaked runs/<id>/ is the
# regression. Name pins the hardcoded PR-1 glob so a future reuse for a different
# PR (#2 exists elsewhere in this file) can't pass vacuously. One helper for the
# repeated contract across the container-mode untrusted-skip, indeterminate-defer,
# and metadata-guard scenarios (was four hand-maintained copies).
assert_no_probe_pr1_run_dir() {
    # Capture once and test the string — NOT `find … | grep -q .`. Under this
    # script's `set -o pipefail`, grep -q exiting on the first match can SIGPIPE
    # find (pipeline status 141 → the `if` is false), silently PASSING the leak
    # assertion at the exact moment a leak exists — a false-pass in the one fence
    # whose job is catching #189. Capturing also drops the duplicate find.
    local leaked
    leaked=$(find "$1/runs" -maxdepth 1 -type d -name 'test-org_probe-repo__1__*')
    if [ -n "$leaked" ]; then
        echo "FAIL: $2 — worker allocated a run-dir (pre-allocation gate didn't fire; leak — issue #189)"
        printf '%s\n' "$leaked"
        exit 1
    fi
}

# run_worker_in_state <state_dir> <worker arg>... — one worker run against a
# state dir's standard layout (the six env exports + repos.conf that every
# scenario repeats). Per-scenario extras (PATH shims, REVIEWER_CONTAINER_MODE,
# KWR_CONFIG_*, ...) ride as env-prefixes on the call — bash's temporary
# environment is inherited by the worker. The worker's exit code propagates;
# append `|| true` at call sites that don't assert on it.
run_worker_in_state() {
    local state="$1"
    shift
    (
        export STATE_DIR="$state"
        export WORKER_ID="solo"   # the modeled account; WORKER_ID is part of the pool-state contract
        export STATE_FILE="$state/state.json"
        export REPOS_DIR="$state/repos"
        export WORKDIRS_DIR="$state/workdirs"
        export CANONICAL_LOCKS_DIR="$state/canonical-locks"
        export PR_REVIEW_LOCK_DIR="$state/locks"
        write_probe_repos_conf "$state/repos.conf"
        TRIGGER_COMMENT_FILE="" \
            bash "$PROJECT_ROOT/lib/review-one-pr.sh" "$@" \
            >/dev/null 2>&1
    )
}

# write_gh_stub <stub_path> <base_ref> <head_oid>
#   gh pr view <N> --json baseRefName,... → returns the supplied base_ref.
#   gh pr view <N> --json headRefOid       → returns head_oid.
#   Anything else (gh pr comment, etc.)    → no-op success.
write_gh_stub() {
    local stub_path="$1" base_ref="$2" head_oid="$3"
    cat > "$stub_path" <<STUB
#!/bin/bash
# Trust-permission endpoint: opt-in non-zero exit (simulates a 403 rate-limit on
# the collaborators/permission check → an INDETERMINATE trust result). Default
# unset → falls through to the no-output/exit-0 path below (a clean 200 with no
# push role = definitively-untrusted), preserving every existing scenario.
if [ -n "\${GH_STUB_PERMISSION_RC:-}" ]; then
    for arg in "\$@"; do
        case "\$arg" in
            */collaborators/*/permission)
                echo "gh: HTTP 403: API rate limit exceeded for user (simulated)" >&2
                exit "\$GH_STUB_PERMISSION_RC" ;;
        esac
    done
fi
# Clean 200 with an explicit push role → trusted author (is_trusted_repo_author
# reads --jq '.permission'; the stub already strips --jq so it prints the role).
if [ -n "\${GH_STUB_PERMISSION_ROLE:-}" ]; then
    for arg in "\$@"; do
        case "\$arg" in
            */collaborators/*/permission) printf '%s\n' "\$GH_STUB_PERMISSION_ROLE"; exit 0 ;;
        esac
    done
fi
# Issue-comments endpoint: opt-in JSON fixture (scenario 12's operator thread).
if [ -n "\${GH_STUB_ISSUE_COMMENTS_FILE:-}" ]; then
    for arg in "\$@"; do case "\$arg" in repos/*/issues/*/comments) cat "\$GH_STUB_ISSUE_COMMENTS_FILE"; exit 0 ;; esac; done
fi
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
        # Opt-in empty result → the BASE_REF/PR_AUTHOR fail-loud guard fires
        # (simulates a gh pr view that returns no usable metadata).
        if [ -n "\${GH_STUB_PRVIEW_EMPTY:-}" ]; then printf '{}\n'; else
        printf '{"baseRefName":"$base_ref","title":"Test PR","body":"","author":{"login":"test-user"},"closingIssuesReferences":{"nodes":[]}}\n'
        fi
        ;;
    *visibility*)
        printf 'PUBLIC\n'
        ;;
    *headRefOid*)
        # Real gh: --json headRefOid --jq '.headRefOid' (both call sites in
        # review-one-pr.sh use --jq). The stub doesn't run real jq, so — same
        # convention as the visibility/permission cases above — it prints the
        # already-extracted bare SHA, not the wrapped JSON.
        printf '%s\n' "$head_oid"
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
DISPATCHER_TICK_AT="$EXPECTED_TICK_AT" run_worker_in_state "$STATE_DIR" \
    "test-org/probe-repo" "1" "$OLD_PR_SHA" "feat/test" "$DIRTY_TITLE" "false" || true

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
seed_state_dir "$STATE2"

CANONICAL2="$STATE2/repos/test-org_probe-repo"
git clone -q "$GITHUB_BARE2" "$CANONICAL2"

# Stub gh — same shape, but baseRefName is "release-1.0" not "main".
write_gh_stub "$HOME/.local/bin/gh" "release-1.0" "$PR_SHA2"

run_worker_in_state "$STATE2" \
    "test-org/probe-repo" "2" "$PR_SHA2" "feat/test" "Release-base PR" "false" || true

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
# Fences the update-ref alignment (from cncorp/plow#568) and the
# --unshallow self-heal (issue #170).
#
# The live invariant: `git fetch origin $BASE_REF` advances only the
# remote-tracking ref, and `git clone --shared` maps the source's
# refs/heads/* into the workdir's origin/*. Without the worker's
# update-ref, the workdir silently diffs against a stale base. So after
# the worker runs, canonical's refs/heads/$BASE_REF MUST equal
# refs/remotes/origin/$BASE_REF — asserted below, alongside the
# self-heal check that a deliberately-shallow canonical ends complete.

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
    # M0: pre-history so the --depth=1 canonical clone below actually
    # truncates (a root commit at the depth cutoff wouldn't be marked
    # shallow — nothing got cut off).
    echo "main v0" > main-content.txt
    git add main-content.txt
    git commit -qm "main v0"
    # M1: main at canonical-clone time (what canonical's refs/heads/main
    # lands at on first clone). The PR forks from here.
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
seed_state_dir "$STATE3"

CANONICAL3="$STATE3/repos/test-org_probe-repo"
# Deliberately SHALLOW, mirroring a canonical cloned in the --depth=500
# era (pre-issue-#170 fix) — exercises the worker's one-time
# `fetch --unshallow` self-heal. file:// is load-bearing: --depth is
# silently ignored on plain local-path clones.
git clone -q --depth=1 --no-single-branch "file://$GITHUB_BARE3" "$CANONICAL3"
if [ "$(git -C "$CANONICAL3" rev-parse --is-shallow-repository)" != "true" ]; then
    echo "FAIL: scenario 3 fixture — canonical3 was expected to start shallow"
    exit 1
fi
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

run_worker_in_state "$STATE3" \
    "test-org/probe-repo" "3" "$PR_SHA3" "feat/test" "Shallow base PR" "false" || true

RUN_DIR3=$(find "$STATE3/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR3" ]; then
    echo "FAIL: scenario 3 — worker produced no run dir under $STATE3/runs"
    exit 1
fi
LOG3="$RUN_DIR3/run.log"

# --unshallow self-heal (issue #170): the fixture canonical started
# shallow (--depth=1 above); the worker must leave it complete.
if [ "$(git -C "$CANONICAL3" rev-parse --is-shallow-repository)" != "false" ]; then
    echo "FAIL: scenario 3 — canonical3 still shallow after the worker ran (--unshallow self-heal ineffective)"
    cat "$LOG3"
    exit 1
fi

# Decisive assertion: refs/heads/main == refs/remotes/origin/main
# (the update-ref alignment ran — see the scenario header).
HEADS_MAIN=$(git -C "$CANONICAL3" rev-parse refs/heads/main 2>/dev/null)
ORIGIN_MAIN=$(git -C "$CANONICAL3" rev-parse refs/remotes/origin/main 2>/dev/null)
if [ "$HEADS_MAIN" != "$ORIGIN_MAIN" ]; then
    echo "FAIL: scenario 3 — canonical refs/heads/main ($HEADS_MAIN) != refs/remotes/origin/main ($ORIGIN_MAIN)"
    echo "  the update-ref alignment didn't run; clone --shared would serve a stale base"
    echo "  SHA to the workdir, so the review would silently diff against an old base"
    cat "$LOG3"
    exit 1
fi

# Liveness anchor: the diff stage was actually reached — only a
# successful, non-empty diff writes the artifact (an empty-diff abort
# or any earlier failure leaves it absent). Content is scenario 2's
# contract — existence only here.
if [ ! -f "$RUN_DIR3/inputs/full-diff.patch" ]; then
    echo "FAIL: scenario 3 — worker never staged full-diff.patch (aborted at or before scratch staging)"
    cat "$LOG3"
    exit 1
fi

# --- Scenario 3b: a FAILED git diff is FATAL, never "empty diff" ------
# Fences issue #170's second flaw: the worker must distinguish a
# non-zero `git diff` exit (FATAL, error logged) from empty stdout
# (the genuine no-changes abort). PATH-shims git (the loc-trend-smoke
# pattern): any three-dot `diff` exits non-zero with empty stdout,
# everything else passes through. Fresh state dir so the dedup gate
# can't skip the run; gh stub from scenario 3 still applies.
STUB_DIR3B="$TMPDIR/stub-bin-3b"
mkdir -p "$STUB_DIR3B"
REAL_GIT=$(command -v git)
cat > "$STUB_DIR3B/git" <<STUB_EOF
#!/bin/bash
REAL_GIT='$REAL_GIT'
STUB_EOF
cat >> "$STUB_DIR3B/git" <<'STUB_EOF'
is_diff=0; three_dot=0
for arg in "$@"; do
    [ "$arg" = "diff" ] && is_diff=1
    case "$arg" in *...*) three_dot=1 ;; esac
done
if [ "$is_diff" = 1 ] && [ "$three_dot" = 1 ]; then
    echo "fatal: simulated three-dot diff failure" >&2
    exit 128
fi
exec "$REAL_GIT" "$@"
STUB_EOF
chmod +x "$STUB_DIR3B/git"

STATE3B="$TMPDIR/state-3b"
seed_state_dir "$STATE3B"
CANONICAL3B="$STATE3B/repos/test-org_probe-repo"
git clone -q "$GITHUB_BARE3" "$CANONICAL3B"

PATH="$STUB_DIR3B:$PATH" run_worker_in_state "$STATE3B" \
    "test-org/probe-repo" "3" "$PR_SHA3" "feat/test" "Failing diff PR" "false" || true

RUN_DIR3B=$(find "$STATE3B/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR3B" ]; then
    echo "FAIL: scenario 3b — worker produced no run dir under $STATE3B/runs"
    exit 1
fi
LOG3B="$RUN_DIR3B/run.log"
if ! grep -q "FATAL — git diff" "$LOG3B"; then
    echo "FAIL: scenario 3b — failed git diff did not produce the FATAL diagnostic"
    cat "$LOG3B"
    exit 1
fi
# State fence the log wording can't drift out from under: only a
# successful diff writes the artifact; a FATAL run must not.
if [ -f "$RUN_DIR3B/inputs/full-diff.patch" ]; then
    echo "FAIL: scenario 3b — full-diff.patch written despite the failed diff"
    cat "$LOG3B"
    exit 1
fi

echo "  PASS (4 scenarios: orchestrator/worker SHA race + non-default-base canonical→workdir ref propagation + canonical heads/main aligned + --unshallow self-heal + failed-diff FATAL fence)"

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

run_worker_in_state "$STATE_DIR" \
    "test-org/probe-repo" "1" "$OLD_PR_SHA" "feat/test" "Test PR" "false"
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
# A clean pre-checkout skip never wrote meta.json, so the EXIT trap's
# finalize_run must no-op (its `[ -f meta.json ]` self-guard) — NOT log a
# spurious finalize failure. Behavioral fence for the bug that spammed
# "finalize_run failed — meta.json left un-stamped" on every concurrent-skip.
if grep -q "finalize_run failed" "$GATE_LOG"; then
    echo "FAIL: scenario 4 — clean skip logged a spurious finalize_run failure"
    { echo "--- run.log ---"; cat "$GATE_LOG"; }
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
seed_state_dir "$STATE5"
write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"   # author=test-user; permission unset → untrusted
# The skip fires BEFORE allocate_run_dir (issue #189): a permanently-untrusted
# PR re-enumerated every ~30s must NOT leak a runs/<id>/ dir per poll. The
# behavioral contract is clean exit 0, no run dir, AND silence (no per-tick log
# line — see the silence assertion below). A regression that failed to skip
# would proceed to clone + allocate a run dir (like scenarios 1-4, same gh stub
# minus container mode), tripping the no-run-dir assertion. Run TWO ticks: a
# permanently-untrusted PR is polled indefinitely, so the skip must stay clean
# and dir-free every tick.
for _tick in 1 2; do
    REVIEWER_CONTAINER_MODE=1 run_worker_in_state "$STATE5" \
        "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Untrusted PR" "false"
    _ec=$?
    # Leak check FIRST: a gate that failed to fire proceeds to clone/allocate
    # (like scenarios 1-4) AND aborts downstream with a non-zero exit, so the
    # run-dir/#189 diagnostic is the informative one — the exit-code check would
    # otherwise mask it. Matches the indeterminate-defer / metadata-guard sites.
    assert_no_probe_pr1_run_dir "$STATE5" "scenario 5 tick $_tick — untrusted skip"
    if [ "$_ec" -ne 0 ]; then
        echo "FAIL: scenario 5 — untrusted tick $_tick exited $_ec (expected 0 from a clean container-mode skip)"
        [ -f "$STATE5/orchestrator.log" ] && { echo "--- orchestrator.log ---"; cat "$STATE5/orchestrator.log"; }
        exit 1
    fi
done
# Silence contract — the actual behavior this branch introduces: the container-
# mode untrusted skip must emit NO per-tick line. A re-added log line at the gate
# (the flood→marker→TTL regression this branch produced twice) would land on the
# shared 5 MB orchestrator.log and pass every other assertion here — so pin it.
# The worker reaches no log call before the gate on this path, so the file must
# be absent/empty; assert on SIZE (not a PR_ID grep) to catch a gate line of any
# shape. A non-empty log also discriminates this skip from the lock-contention
# skip at review-one-pr.sh:83 (which writes via tee -a to this same path),
# ruling out a false pass from a leaked tick-1 PR lock or a future exit-0 path
# added above the gate.
if [ -s "$STATE5/orchestrator.log" ]; then
    echo "FAIL: scenario 5 — untrusted skip wrote to orchestrator.log (silence contract broken → shared-log flood risk)"
    { echo "--- orchestrator.log ---"; cat "$STATE5/orchestrator.log"; }
    exit 1
fi

# ===== Scenario 6: container-mode gate DEFERS on an indeterminate trust check =====
# A 403/5xx/network failure of the collaborators/permission lookup (e.g. the
# shared account is rate-limited) must NOT read as "untrusted" — that would
# silently drop a genuinely-trusted author's PR. The worker defers (exit 1, like
# the gh pr view / gh repo view guards) so the next tick retries once the
# throttle clears. Same stub as scenario 5 but with the permission call forced to
# a 403 (GH_STUB_PERMISSION_RC), flipping the trust result untrusted→indeterminate.
echo "  scenario: container-mode gate DEFERS (exit 1) on an indeterminate trust check, no placeholder..."
STATE_IND="$TMPDIR/state-ind"   # distinct dir — must not collide with later scenarios' STATE6
seed_state_dir "$STATE_IND"
write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"
REVIEWER_CONTAINER_MODE=1 GH_STUB_PERMISSION_RC=1 run_worker_in_state "$STATE_IND" \
    "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Indeterminate PR" "false"
GATE_IND_EC=$?
# Like the untrusted skip, the indeterminate DEFER fires before allocate_run_dir
# (issue #189) — and it retries every tick, so a leaked dir per retry would be
# the worst offender. Assert NO run dir and the defer line on the orchestrator
# fallback log.
LOG_IND="$STATE_IND/orchestrator.log"
assert_no_probe_pr1_run_dir "$STATE_IND" "indeterminate-defer"
if [ "$GATE_IND_EC" -ne 1 ]; then
    echo "FAIL: indeterminate-defer — worker exited $GATE_IND_EC (expected 1 = defer on indeterminate trust)"
    [ -f "$LOG_IND" ] && { echo "--- orchestrator.log ---"; cat "$LOG_IND"; }
    exit 1
fi
if ! grep -q "trust check deferred" "$LOG_IND"; then
    echo "FAIL: indeterminate-defer — orchestrator.log missing the 'trust check deferred' line"
    [ -f "$LOG_IND" ] && { echo "--- orchestrator.log ---"; cat "$LOG_IND"; }
    exit 1
fi
# (No separate placeholder assertion — see scenario 5's note; the no-run-dir
# check above dominates it.)

# ===== Scenario 6b: metadata-lookup guard aborts BEFORE allocate_run_dir =====
# The gh pr view (BASE_REF/PR_AUTHOR) and gh repo view (REPO_VISIBILITY) guards
# moved above allocate_run_dir with the trust gate, so a metadata-lookup failure
# must also abort without leaking a run dir. Fences that half of the relocation
# (the trust-gate half is scenarios 5/6): a future re-shuffle that pushed the
# guards back below allocation would otherwise go undetected. gh pr view returns
# {} → empty BASE_REF/PR_AUTHOR → guard exit 1, no run dir, line on orchestrator.log.
echo "  scenario: metadata-lookup guard aborts before run-dir allocation (no leak)..."
STATE_MD="$TMPDIR/state-md"
seed_state_dir "$STATE_MD"
write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"
GH_STUB_PRVIEW_EMPTY=1 run_worker_in_state "$STATE_MD" \
    "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Metadata-fail PR" "false"
GATE_MD_EC=$?
LOG_MD="$STATE_MD/orchestrator.log"
assert_no_probe_pr1_run_dir "$STATE_MD" "metadata-guard (gh-pr-view abort before allocation)"
if [ "$GATE_MD_EC" -ne 1 ]; then
    echo "FAIL: metadata-guard — worker exited $GATE_MD_EC (expected 1 = abort on empty gh pr view)"
    [ -f "$LOG_MD" ] && { echo "--- orchestrator.log ---"; cat "$LOG_MD"; }
    exit 1
fi
if ! grep -q "gh pr view returned no baseRefName / author" "$LOG_MD"; then
    echo "FAIL: metadata-guard — orchestrator.log missing the gh-pr-view abort line"
    [ -f "$LOG_MD" ] && { echo "--- orchestrator.log ---"; cat "$LOG_MD"; }
    exit 1
fi

echo "  gate/leak scenarios ok (untrusted skip + dedupe + indeterminate defer + metadata-guard pre-allocation abort)"

# ===== Scenario 6: repeated transient aborts reuse one placeholder =====
# Fences the anti-spam reuse path in lib/review-one-pr.sh. During a transient
# outage (codex quota exhausted, specialist timeout) every 2-min orchestrator
# tick runs the worker, which posts a "👀 reviewing" placeholder, aborts at
# the pipeline (no codex here), and the EXIT trap edits the placeholder to a
# paused/aborted body. Before the fix each tick POSTed a NEW placeholder —
# one fresh comment per PR every 2 minutes (39 observed on a single PR). The
# fix: a later tick recognizes the prior tick's unresolved placeholder (it
# carries BOT_PLACEHOLDER_MARKER) and reuses it instead of stacking another.
#
# Behavior asserted (user-visible): after the worker runs TWICE on the same
# PR head, the PR has exactly ONE bot placeholder comment — not two. A
# stateful gh stub backs a real comment store (POST appends, --jq GET reads,
# PATCH edits, DELETE removes) so the assertion is on the resulting comment
# set, not on internal calls.
echo "  scenario: repeated transient aborts reuse a single placeholder (no per-tick spam)..."

COMMENT_STORE="$TMPDIR/comment-store.json"
echo "[]" > "$COMMENT_STORE"

# write_stateful_gh_stub <path> <store> <base_ref> <head_oid>
write_stateful_gh_stub() {
    local stub_path="$1" store="$2" base_ref="$3" head_oid="$4"
    cat > "$stub_path" <<STUB
#!/usr/bin/env bash
# Stateful gh: 'pr view' returns canned PR metadata; 'api .../comments'
# reads/writes \$STORE so the placeholder lifecycle (POST → PATCH → reuse)
# is observable in the resulting comment set.
STORE="$store"
BOT_LOGIN="${BOT_USER:-test-user}"

# --- gh pr view / gh repo view (canned, same shape as write_gh_stub) ---
if { [ "\$1" = "pr" ] || [ "\$1" = "repo" ]; } && [ "\$2" = "view" ]; then
    fields=""
    for ((i=1; i<=\$#; i++)); do
        if [ "\${!i}" = "--json" ]; then j=\$((i+1)); fields="\${!j}"; break; fi
    done
    case "\$fields" in
        *baseRefName*) printf '{"baseRefName":"$base_ref","title":"Test PR","body":"","author":{"login":"test-user"},"closingIssuesReferences":{"nodes":[]}}\n' ;;
        *visibility*)  printf 'PUBLIC\n' ;;
        *headRefOid*)  printf '%s\n' "$head_oid" ;;  # bare SHA — both call sites use --jq '.headRefOid'
    esac
    exit 0
fi

# --- gh api ---
if [ "\$1" = "api" ]; then
    endpoint=""; method="GET"; body=""; jqexpr=""
    args=("\$@"); n=\${#args[@]}
    for ((i=1; i<n; i++)); do
        a="\${args[i]}"
        case "\$a" in
            --method|-X) method="\${args[i+1]}"; ((i++)) ;;
            -f|-F|--raw-field|--field)
                v="\${args[i+1]}"; ((i++))
                [ "\${v#body=}" != "\$v" ] && body="\${v#body=}" ;;
            --jq) jqexpr="\${args[i+1]}"; ((i++)) ;;
            --paginate) : ;;
            -*) : ;;
            *) [ -z "\$endpoint" ] && endpoint="\$a" ;;
        esac
    done

    result="null"
    case "\$endpoint" in
        */issues/*/comments)   # list or create
            if [ "\$method" = "POST" ]; then
                newid=\$(jq '([.[].id] | max // 0) + 1' "\$STORE")
                result=\$(jq -n --argjson id "\$newid" --arg body "\$body" --arg login "\$BOT_LOGIN" \
                    '{id:\$id, body:\$body, user:{login:\$login}}')
                jq --argjson c "\$result" '. + [\$c]' "\$STORE" > "\$STORE.tmp" && mv "\$STORE.tmp" "\$STORE"
            else
                result=\$(cat "\$STORE")
            fi ;;
        */issues/comments/*)   # patch or delete a single comment
            cid="\${endpoint##*/}"
            if [ "\$method" = "DELETE" ]; then
                jq --argjson id "\$cid" 'map(select(.id != \$id))' "\$STORE" > "\$STORE.tmp" && mv "\$STORE.tmp" "\$STORE"
                result="{}"
            else
                jq --argjson id "\$cid" --arg body "\$body" 'map(if .id == \$id then .body = \$body else . end)' \
                    "\$STORE" > "\$STORE.tmp" && mv "\$STORE.tmp" "\$STORE"
                result=\$(jq -n --argjson id "\$cid" --arg body "\$body" --arg login "\$BOT_LOGIN" \
                    '{id:\$id, body:\$body, user:{login:\$login}}')
            fi ;;
    esac

    if [ -n "\$jqexpr" ]; then printf '%s\n' "\$result" | jq -r "\$jqexpr"; else printf '%s\n' "\$result"; fi
    exit 0
fi
exit 0
STUB
    chmod +x "$stub_path"
}

write_stateful_gh_stub "$HOME/.local/bin/gh" "$COMMENT_STORE" "main" "$NEW_PR_SHA"

STATE6="$TMPDIR/state-6"
seed_state_dir "$STATE6"
CANONICAL6="$STATE6/repos/test-org_probe-repo"
git clone -q "$GITHUB_BARE" "$CANONICAL6"

run_tick_6() {
    run_worker_in_state "$STATE6" \
        "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Test PR" "false" || true
}

run_tick_6   # tick 1: posts placeholder, aborts, EXIT trap edits to paused
run_tick_6   # tick 2: must reuse the same placeholder, not post a second

# Decisive assertion: exactly one bot placeholder comment survives two ticks.
PLACEHOLDER_COUNT=$(jq '[.[] | select(.body | contains("knightwatch-reviewer:placeholder"))] | length' "$COMMENT_STORE")
if [ "$PLACEHOLDER_COUNT" != "1" ]; then
    echo "FAIL: scenario 6 — $PLACEHOLDER_COUNT placeholder comments after two ticks (expected 1 — per-tick spam regressed)"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:80])"' "$COMMENT_STORE"
    exit 1
fi

echo "  placeholder-reuse anti-spam scenario ok"


# ===== Scenario 7: transient codex 429 → short backoff (not hard-abort+retry) =====
# Fences the WHOLE 429-backoff path end-to-end: a fake `codex` emits the
# first-party retry-exhaustion 429 on stderr → the real pipeline.py classifies
# it (_CODEX_RATE_LIMIT_RE) and writes $RUN_DIR/_codex_rate_limit.txt →
# review-one-pr.sh turns that sentinel into a future-epoch quota-pause + a
# "codex rate limit (429)" placeholder body (the consumer half the Python-level
# test can't reach). Originating incident: 2026-06-03 post-restart 429 storm,
# where a bare 429 hard-aborted + instantly retried into a self-sustaining loop.
#
# Behavior asserted (user-visible): the single placeholder says "codex rate
# limit (429)", and $STATE/pool/solo/quota-paused-until is a FUTURE epoch so the worker
# backs off instead of immediately re-claiming.
echo "  scenario: codex 429 → backoff (quota-pause + 429 placeholder), not hard-abort..."

# Full prompts so the pipeline reaches run_codex (Wave A intent) and the fake
# codex's 429 lands — not an early build_prompt abort.
cp -r "$PROJECT_ROOT/prompts/." "$HOME/.pr-reviewer/prompts/"

# Shared arrange/act for the codex stop-state abort scenarios (7 = transient
# 429, 7b = usage cap): a fake codex emitting one stderr line, fresh comment
# store + state dir (+ any sibling pool accounts), one worker run. Row-specific
# assertions stay at each call site.
run_codex_abort_scenario() {  # <state_dir> <store> <stderr_line> [sibling_account]...
    local state="$1" store="$2" line="$3"; shift 3
    { printf '#!/usr/bin/env bash\n'
      printf 'echo %s >&2\n' "$(printf '%q' "$line")"
      printf 'exit 1\n'; } > "$HOME/.local/bin/codex"
    chmod +x "$HOME/.local/bin/codex"
    echo "[]" > "$store"
    write_stateful_gh_stub "$HOME/.local/bin/gh" "$store" "main" "$NEW_PR_SHA"
    seed_state_dir "$state"
    git clone -q "$GITHUB_BARE" "$state/repos/test-org_probe-repo"
    mkdir -p "$state/pool/solo"   # review-loop's registration, done test-side
    local sib; for sib in "$@"; do mkdir -p "$state/pool/$sib"; done
    run_worker_in_state "$state" \
        "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Test PR" "false" || true
    rm -f "$HOME/.local/bin/codex"   # don't leak the fake codex past this scenario
}

# Row 1 — transient 429 (codex's first-party retry-exhaustion line; pipeline.py
# classifies it via _CODEX_RATE_LIMIT_RE into _codex_rate_limit.txt).
STORE7="$TMPDIR/comment-store-7.json"; STATE7="$TMPDIR/state-7"
run_codex_abort_scenario "$STATE7" "$STORE7" \
    "ERROR: exceeded retry limit, last status: 429 Too Many Requests, request id: 00000000-0000-0000-0000-000000000000"

if ! jq -e '[.[] | select(.body | contains("codex rate limit (429)"))] | length == 1' "$STORE7" >/dev/null; then
    echo "FAIL: scenario 7 — placeholder body missing 'codex rate limit (429)' (429 sentinel → backoff body not wired)"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:90])"' "$STORE7"
    exit 1
fi
PAUSE_UNTIL=$(head -n1 "$STATE7/pool/solo/quota-paused-until" 2>/dev/null || echo 0)
if [ "$PAUSE_UNTIL" -le "$(date +%s)" ]; then
    echo "FAIL: scenario 7 — quota-paused-until=$PAUSE_UNTIL is not a future epoch (worker would re-claim immediately, no backoff)"
    exit 1
fi

echo "  codex 429 backoff scenario ok"

# ===== Scenario 7b: codex usage cap → quota placeholder with whole-pool status =====
# The user-visible path this PR exists to correct: pipeline.py classifies the
# usage-cap stderr (_CODEX_QUOTA_RE) into _codex_quota.txt and review-one-pr.sh
# renders the per-account quota placeholder + pool_status. Bare-time reset
# ("6:26 PM", codex's rolling-window format) so the fixture never goes stale;
# the conservative-1h parse path stamps a future pause either way.
echo "  scenario: codex usage cap → quota placeholder (queued + account + pool status)..."

# Row 2 — usage cap, with a healthy sibling account (pool/1) so the pool clause
# renders mixed states.
STORE7B="$TMPDIR/comment-store-7b.json"; STATE7B="$TMPDIR/state-7b"
run_codex_abort_scenario "$STATE7B" "$STORE7B" \
    "ERROR: You've hit your usage limit. Please try again at 6:26 PM." 1

if ! jq -e '[.[] | select(.body
        | contains("reviewer account solo hit its codex quota (resets at 6:26 PM)")
          and contains("This PR stays queued")
          and contains("any active account picks it up")
          and contains("Pool:")
          and contains("account 1: ✅ active")
          and contains("account solo: ⏸ quota-paused"))] | length == 1' "$STORE7B" >/dev/null; then
    echo "FAIL: scenario 7b — quota placeholder missing the queued/account/pool-status contract"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:220])"' "$STORE7B"
    exit 1
fi
PAUSE_UNTIL7B=$(head -n1 "$STATE7B/pool/solo/quota-paused-until" 2>/dev/null || echo 0)
if [ "$PAUSE_UNTIL7B" -le "$(date +%s)" ]; then
    echo "FAIL: scenario 7b — quota-paused-until=$PAUSE_UNTIL7B is not a future epoch (capped account would keep claiming)"
    exit 1
fi

echo "  usage-cap quota placeholder scenario ok"

# ===== Scenario 8: BOTH 429 + fatal-auth sentinels → fatal-auth wins =====
# Fences the stop-state PRECEDENCE introduced by this branch: when a run leaves
# BOTH _codex_rate_limit.txt (429) AND _codex_auth_fatal.txt in $RUN_DIR,
# review-one-pr.sh must take the worker OFFLINE (auth-fatal) and must NOT also
# stamp a 120s quota-pause file — the 429-backoff block is guarded to skip when
# fatal-auth is present (review-one-pr.sh:1484/1491). Without that guard the 429
# block would race the auth-fatal block and leave a short timed pause that lets
# the worker re-claim PRs on a fatally-invalid token (re-running the 401 storm
# the offline path exists to stop).
#
# pipeline.py's classifier writes at most one sentinel per run (mutually-
# exclusive elif chain), so the combined state can't arise from a single fake-
# codex stderr line alone. The fake codex therefore writes _codex_rate_limit.txt
# directly into the run dir (derived from its -o output path) AND emits the
# fatal-auth stderr line so pipeline.py writes _codex_auth_fatal.txt — producing
# the both-present state the precedence guard exists to resolve.
#
# Behavior asserted (user-visible): the placeholder says the worker is OFFLINE
# (auth invalid), $STATE/pool/solo/auth-offline exists, and $STATE/pool/solo/quota-paused-until does
# NOT — i.e. fatal-auth won and no timed backoff was stamped.
echo "  scenario: BOTH 429 + fatal-auth sentinels → fatal-auth wins (offline, no quota-pause)..."

cat > "$HOME/.local/bin/codex" <<'CODEX'
#!/usr/bin/env bash
# Recover $RUN_DIR from the -o <run_dir>/agents/<name>/output.md arg pipeline.py
# passes, then seed the 429 sentinel directly (pipeline's elif chain writes only
# the auth-fatal one from the stderr line below, so both can't come from stderr).
out=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && out="$arg" && break
    prev="$arg"
done
# Fail loud if we can't establish the BOTH-sentinel state: without the 429
# seed the run degrades to auth-fatal-only (covered elsewhere) and the scenario
# would silently false-pass instead of fencing the precedence it exists for.
if [ -z "$out" ]; then
    echo "fake-codex: no -o arg found; cannot seed _codex_rate_limit.txt for combined-sentinel scenario" >&2
    exit 2
fi
run_dir="$(dirname "$(dirname "$(dirname "$out")")")"
printf 'codex 429 rate limit\n' > "$run_dir/_codex_rate_limit.txt"
echo "ERROR: Your access token could not be refreshed because your refresh token was already used (refresh_token_reused). Please log out and sign in again." >&2
exit 1
CODEX
chmod +x "$HOME/.local/bin/codex"

STORE8="$TMPDIR/comment-store-8.json"
echo "[]" > "$STORE8"
write_stateful_gh_stub "$HOME/.local/bin/gh" "$STORE8" "main" "$NEW_PR_SHA"

STATE8="$TMPDIR/state-8"
seed_state_dir "$STATE8"
git clone -q "$GITHUB_BARE" "$STATE8/repos/test-org_probe-repo"
# Seed a sibling account with an active quota pause so the abort body's
# pool_status rendering (multi-account, mixed states) is exercised — every
# other assertion in this file matches text before the "Pool:" clause.
mkdir -p "$STATE8/pool/2"
printf '%s\n' "$(( $(date +%s) + 7200 ))" > "$STATE8/pool/2/quota-paused-until"
# And a stale sibling (>2h since last tick) WITH a still-future pause: liveness
# must win the branch order — a dead account renders 💤, not its stale pause.
mkdir -p "$STATE8/pool/9"
printf '%s\n' "$(( $(date +%s) + 7200 ))" > "$STATE8/pool/9/quota-paused-until"
touch -d '3 hours ago' "$STATE8/pool/9"
mkdir -p "$STATE8/pool/solo"   # review-loop's registration, done test-side

run_worker_in_state "$STATE8" \
    "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Test PR" "false" || true

rm -f "$HOME/.local/bin/codex"   # don't leak the fake codex past this scenario

# Setup guard: prove the BOTH-sentinel state was actually established (the fake
# codex seeded _codex_rate_limit.txt AND pipeline.py wrote _codex_auth_fatal.txt
# from the stderr line). If the 429 seed silently no-op'd, the run is auth-fatal-
# only — covered elsewhere — and the precedence assertions below would false-pass.
if ! ls "$STATE8"/runs/*/_codex_rate_limit.txt >/dev/null 2>&1 \
   || ! ls "$STATE8"/runs/*/_codex_auth_fatal.txt >/dev/null 2>&1; then
    echo "FAIL: scenario 8 — both-sentinel state not established (rate_limit + auth_fatal must coexist in \$RUN_DIR); scenario is not exercising the precedence it claims"
    ls -la "$STATE8"/runs/*/ 2>/dev/null | grep -E '_codex_(rate_limit|auth_fatal)' || echo "  (no sentinels found)"
    exit 1
fi

if ! jq -e '[.[] | select(.body | contains("knightwatch offline") and contains("auth"))] | length == 1' "$STORE8" >/dev/null; then
    echo "FAIL: scenario 8 — placeholder body not the auth-offline message (fatal-auth did not win the both-sentinel race)"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:100])"' "$STORE8"
    exit 1
fi
# pool_status rendering: the body must show BOTH accounts with their real
# states — the aborting worker (solo, freshly marked offline) and the seeded
# sibling (2, active quota pause) — not just the aborting account's own state.
if ! jq -e '[.[] | select(.body | contains("Pool:") and contains("account 2: ⏸ quota-paused") and contains("account solo: 🔒 offline") and contains("account 9: 💤 not running"))] | length == 1' "$STORE8" >/dev/null; then
    echo "FAIL: scenario 8 — abort body missing the whole-pool status clause (Pool: / account 2 quota-paused / account solo offline / account 9 not-running despite future pause)"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:200])"' "$STORE8"
    exit 1
fi
if [ ! -f "$STATE8/pool/solo/auth-offline" ]; then
    echo "FAIL: scenario 8 — \$STATE/auth-offline missing (worker not taken offline despite fatal-auth sentinel)"
    exit 1
fi
if [ -f "$STATE8/pool/solo/quota-paused-until" ]; then
    echo "FAIL: scenario 8 — \$STATE/quota-paused-until exists ($(head -n1 "$STATE8/pool/solo/quota-paused-until")); the 429 block stamped a timed pause despite fatal-auth precedence"
    exit 1
fi

# ===== Scenario 9: convention repo (kwr-config binding, no justfile) — staging =====
# resolve_binding has unit coverage (conventions-smoke.sh), but nothing proved the
# WORKER actually stages what Codex consumes for a convention repo:
#   - inputs/convention.md (so specialists review by that convention's grammar)
#   - inputs/test-results.md carrying the convention's test-note (the gate is the
#     convention's own — here ref/verify.sh — NOT a missing justfile)
# The operator's kwr-config (a local fixture here) binds org `test-org` + a root
# `SEED.md` marker → conventions/seed.md. Detection reads the marker at the
# TRUSTED base ref; the fixture has no justfile so the convention's test-note fires.
echo "  scenario: convention repo (kwr-config binding, SEED.md@base, no justfile) — convention.md + test-note staged into inputs/..."

# kwr-config fixture: a binding (marker SEED.md in org test-org) → a convention
# doc whose frontmatter declares the test gate. The worker reads this cache; only
# org-sync pulls it, so a fixture dir + KWR_CONFIG_REPO/_DIR env is enough.
KWRCFG9="$TMPDIR/kwr-config-9"
mkdir -p "$KWRCFG9/conventions"
cat > "$KWRCFG9/config.json" <<'JSON'
{ "bindings": [ { "match": {"org":"test-org","marker":"SEED.md"}, "doc":"conventions/seed.md" } ] }
JSON
cat > "$KWRCFG9/conventions/seed.md" <<'MD'
---
test-note: "`just test` is N/A; the gate is the `## Verification` prompts / `ref/verify.sh`. Evaluate prose↔ref correspondence by reading."
test-header: "gate is `## Verification` / `ref/verify.sh` (no `just test`)"
---
# SEED-convention repo — how to review this PR

Review by the SEED grammar: the prose spec is authoritative.
MD

GITHUB_BARE9="$TMPDIR/github-side-9.git"
git init -q --bare -b main "$GITHUB_BARE9"

WORKING9="$TMPDIR/working-9"
git clone -q "$GITHUB_BARE9" "$WORKING9"
(
    cd "$WORKING9"
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    # SEED.md at base → the binding's marker detector trips (read from the trusted
    # base ref). No justfile anywhere → the convention's no-justfile test note.
    printf '# A SEED\n\n## Verification\n\nRun `ref/verify.sh`.\n' > SEED.md
    echo "readme" > README.md
    git add SEED.md README.md
    git commit -qm "init: SEED repo"
    git push -q origin main
    git checkout -qb feat/test
    echo "feature" > feature.txt
    git add feature.txt
    git commit -qm "PR feature on a SEED repo"
)
PR_SHA9=$(git -C "$WORKING9" rev-parse HEAD)
git -C "$WORKING9" push -q origin feat/test:refs/pull/9/head

STATE9="$TMPDIR/state-9"
seed_state_dir "$STATE9"
git clone -q "$GITHUB_BARE9" "$STATE9/repos/test-org_probe-repo"

write_gh_stub "$HOME/.local/bin/gh" "main" "$PR_SHA9"

# codex stub: observe .codex-scratch at the EXACT moment specialists read it
# (codex runs `codex exec -C <workdir>`), record the dir listing, then exit
# non-zero so the worker aborts like an absent LLM (as the other scenarios rely
# on). This is the only honest observation point for the staging-order bug — the
# worker tears down the workdir on abort, so inspecting it afterwards can't tell a
# staged-then-wiped convention.md (bug) from a correctly-staged one.
CODEX_STUB_DIR="$TMPDIR/codex-stub-9"; mkdir -p "$CODEX_STUB_DIR"
SCRATCH_SNAPSHOT9="$STATE9/scratch-at-codex.txt"
cat > "$CODEX_STUB_DIR/codex" <<STUB
#!/bin/bash
d=""; prev=""
for a in "\$@"; do [ "\$prev" = "-C" ] && d="\$a"; prev="\$a"; done
[ -n "\$d" ] && ls "\$d/.codex-scratch" > "$SCRATCH_SNAPSHOT9" 2>/dev/null || true
exit 1
STUB
chmod +x "$CODEX_STUB_DIR/codex"

# Wire the operator kwr-config: non-empty REPO marks it active; DIR points at
# the local fixture cache (no pull — that's org-sync's job).
PATH="$CODEX_STUB_DIR:$PATH" \
KWR_CONFIG_REPO="https://example.invalid/test-org/kwr-config.git" \
KWR_CONFIG_DIR="$KWRCFG9" \
    run_worker_in_state "$STATE9" \
    "test-org/probe-repo" "9" "$PR_SHA9" "feat/test" "SEED PR" "false" || true

RUN_DIR9=$(find "$STATE9/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR9" ]; then
    echo "FAIL: scenario 9 — worker produced no run dir under $STATE9/runs"
    exit 1
fi
LOG9="$RUN_DIR9/run.log"

# convention.md must be staged so specialists review by the convention's grammar.
if [ ! -s "$RUN_DIR9/inputs/convention.md" ]; then
    echo "FAIL: scenario 9 — $RUN_DIR9/inputs/convention.md not staged (binding detection or staging regressed)"
    [ -f "$LOG9" ] && { echo "--- run.log ---"; tail -n 30 "$LOG9"; }
    exit 1
fi
# Frontmatter must be stripped from the staged body (it's prose for the specialists).
if grep -q '^test-note:' "$RUN_DIR9/inputs/convention.md"; then
    echo "FAIL: scenario 9 — convention.md still carries frontmatter (convention_body did not strip it)"
    exit 1
fi

# test-results.md must carry the convention's test-note — the gate is the
# convention's own (ref/verify.sh), NOT the generic "no justfile" coverage gap.
TEST_RESULTS_MD9="$RUN_DIR9/inputs/test-results.md"
if [ ! -f "$TEST_RESULTS_MD9" ]; then
    echo "FAIL: scenario 9 — $TEST_RESULTS_MD9 not staged"
    [ -f "$LOG9" ] && { echo "--- run.log ---"; tail -n 30 "$LOG9"; }
    exit 1
fi
if ! grep -q "ref/verify.sh" "$TEST_RESULTS_MD9"; then
    echo "FAIL: scenario 9 — test-results.md does not name the convention's gate (ref/verify.sh)"
    cat "$TEST_RESULTS_MD9"
    exit 1
fi

# The .codex-scratch ENTRY (what specialists actually read) must be present when
# codex runs. Regression fence for the staging-order bug: staging convention.md at
# detection time (before the redirect-safe `.codex-scratch` reset) leaves
# inputs/convention.md intact — so the inputs/ checks above still pass — but wipes
# the staged entry, so specialists never see it. The codex stub captured the dir listing
# at specialist-run time; standards.md is the control (always staged post-reset).
if [ ! -f "$SCRATCH_SNAPSHOT9" ]; then
    echo "FAIL: scenario 9 — codex stub never ran (worker aborted before specialists) — can't verify convention.md visibility"
    [ -f "$LOG9" ] && { echo "--- run.log ---"; tail -n 30 "$LOG9"; }
    exit 1
fi
grep -qx "standards.md" "$SCRATCH_SNAPSHOT9" || { echo "FAIL: scenario 9 — control standards.md not in .codex-scratch at codex-time (snapshot invalid)"; cat "$SCRATCH_SNAPSHOT9"; exit 1; }
if ! grep -qx "convention.md" "$SCRATCH_SNAPSHOT9"; then
    echo "FAIL: scenario 9 — convention.md NOT in .codex-scratch at codex-time (staged before the redirect-safe reset → specialists never see it)"
    cat "$SCRATCH_SNAPSHOT9"
    exit 1
fi

# ===== Scenario 10: repo-env seed → trusted-author .env mirror (durable creds) =====
# Fences the fresh-container live-cred recovery path end-to-end through the real
# worker: an operator file at REPO_ENV_DIR/<slug>/<relpath> must (1) be seeded
# into the canonical clone, then (2) be delivered into the per-PR workdir by the
# existing trust-gated .env mirror (because the repo ships the matching
# .env*.example AND the author is trusted). The compose-mount smoke only proves
# the mount exists; this proves the mount→canonical→trusted-workdir flow.
echo "  scenario: repo-env seed → trusted-author .env mirror (live-cred recovery path)..."

GITHUB_BARE10="$TMPDIR/github-side-10.git"
git init -q --bare -b main "$GITHUB_BARE10"
WORKING10="$TMPDIR/working-10"
git clone -q "$GITHUB_BARE10" "$WORKING10"
(
    cd "$WORKING10"
    git config user.email t@t; git config user.name t; git config commit.gpgsign false
    # The repo SHIPS the example (tracked) — the mirror keys off it; the real
    # .env.test-live is untracked and arrives via the seed → mirror, not the clone.
    echo "ANTHROPIC_API_KEY=" > .env.test-live.example
    echo "readme" > README.md
    git add .env.test-live.example README.md
    git commit -qm "init: ships .env.test-live.example"
    git push -q origin main
    git checkout -qb feat/test
    echo "feature" > feature.txt
    git add feature.txt
    git commit -qm "PR feature"
)
PR_SHA10=$(git -C "$WORKING10" rev-parse HEAD)
git -C "$WORKING10" push -q origin feat/test:refs/pull/10/head

STATE10="$TMPDIR/state-10"
seed_state_dir "$STATE10"
git clone -q "$GITHUB_BARE10" "$STATE10/repos/test-org_probe-repo"

# Operator secret store (the read-only /root/.kwr/repo-env mount in prod): one
# real env file under the repo slug, the seed source.
REPO_ENV10="$TMPDIR/repo-env-10"
mkdir -p "$REPO_ENV10/test-org_probe-repo"
echo "ANTHROPIC_API_KEY=sk-test-live-fixture" > "$REPO_ENV10/test-org_probe-repo/.env.test-live"

write_gh_stub "$HOME/.local/bin/gh" "main" "$PR_SHA10"

REPO_ENV_DIR="$REPO_ENV10" GH_STUB_PERMISSION_ROLE=write run_worker_in_state "$STATE10" \
    "test-org/probe-repo" "10" "$PR_SHA10" "feat/test" "Live-cred PR" "false" || true

RUN_DIR10=$(find "$STATE10/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
[ -n "$RUN_DIR10" ] || { echo "FAIL: scenario 10 — worker produced no run dir"; exit 1; }
LOG10="$RUN_DIR10/run.log"

# Decisive: the seed wrote the real file into canonical, AND the trust-gated
# mirror then copied it into the workdir — both observable in run.log.
if ! grep -q "seeded 1 operator repo-env file(s) into canonical" "$LOG10"; then
    echo "FAIL: scenario 10 — run.log missing the repo-env seed line (seed step didn't fire)"
    [ -f "$LOG10" ] && { echo "--- run.log ---"; tail -n 30 "$LOG10"; }
    exit 1
fi
if ! grep -qE "mirrored 1 env file\(s\) from canonical .*trusted" "$LOG10"; then
    echo "FAIL: scenario 10 — run.log missing the trusted-author .env mirror line (seeded file didn't reach the workdir)"
    [ -f "$LOG10" ] && { echo "--- run.log ---"; tail -n 30 "$LOG10"; }
    exit 1
fi
# Belt-and-suspenders: the seeded file really landed in canonical (not just logged).
if [ ! -s "$STATE10/repos/test-org_probe-repo/.env.test-live" ]; then
    echo "FAIL: scenario 10 — .env.test-live not present in canonical clone after seed"
    exit 1
fi

# Negative case: a seed that can't be written must FAIL LOUD (the probe-3 fix) —
# abort before the mirror, never run the test with missing/stale creds. Induce a
# deterministic failure with `mkdir` over a pre-created FILE at the target's
# parent (fails even as root, so it holds in the container self-review too).
echo "  scenario: repo-env seed failure aborts loud (no silent continue to the test)..."
STATE10B="$TMPDIR/state-10b"
seed_state_dir "$STATE10B"
git clone -q "$GITHUB_BARE10" "$STATE10B/repos/test-org_probe-repo"
# Block the seed: source uses an api/ subdir, but canonical's `api` is a FILE.
touch "$STATE10B/repos/test-org_probe-repo/api"
REPO_ENV10B="$TMPDIR/repo-env-10b"
mkdir -p "$REPO_ENV10B/test-org_probe-repo/api"
echo "ANTHROPIC_API_KEY=sk-test-live-fixture" > "$REPO_ENV10B/test-org_probe-repo/api/.env.test-live"
write_gh_stub "$HOME/.local/bin/gh" "main" "$PR_SHA10"
REPO_ENV_DIR="$REPO_ENV10B" GH_STUB_PERMISSION_ROLE=write run_worker_in_state "$STATE10B" \
    "test-org/probe-repo" "10" "$PR_SHA10" "feat/test" "Live-cred PR" "false" || true
RUN_DIR10B=$(find "$STATE10B/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
[ -n "$RUN_DIR10B" ] || { echo "FAIL: scenario 10b — worker produced no run dir"; exit 1; }
LOG10B="$RUN_DIR10B/run.log"
if ! grep -q "FATAL — repo-env seed of 'api/.env.test-live' failed" "$LOG10B"; then
    echo "FAIL: scenario 10b — run.log missing the fail-loud seed abort (silent-continue regressed)"
    [ -f "$LOG10B" ] && { echo "--- run.log ---"; tail -n 30 "$LOG10B"; }
    exit 1
fi
if grep -q "mirrored .* env file(s) from canonical" "$LOG10B"; then
    echo "FAIL: scenario 10b — worker reached the .env mirror despite a failed seed (didn't abort at the seam)"
    exit 1
fi

# ===== Scenario 11: pre-spend stale-head gate — mismatch → abort before specialists =====
# The ONLY coverage of the pre-spend gate (the decision is inline in the
# worker): when gh reports a headRefOid that differs from the
# checked-out HEAD at the pre-spend gate (review-one-pr.sh, right before
# pipeline.py — the token boundary), the run must abort BEFORE any LLM
# specialist runs, PATCH the placeholder to the superseded body (naming both
# short SHAs), and stamp meta.json status=aborted — which keeps the run out of
# KNOWN_SHA dedup so the next tick reviews the new head.
#
# Fixture note: the stateful gh stub serves ONE fixed headRefOid for the whole
# scenario. That's fine — the checkout comes from git (refs/pull/1/head →
# NEW_PR_SHA → REVIEWED_SHA), so pinning the stub to OLD_PR_SHA makes the
# gate-time gh answer ≠ REVIEWED_SHA without time-varying stub state. Only the
# pre-spend abort contract is asserted.
echo "  scenario: pre-spend stale-head gate — gh head ≠ REVIEWED_SHA → abort before specialists..."

STORE11="$TMPDIR/comment-store-11.json"
echo "[]" > "$STORE11"
write_stateful_gh_stub "$HOME/.local/bin/gh" "$STORE11" "main" "$OLD_PR_SHA"

STATE11="$TMPDIR/state-11"
seed_state_dir "$STATE11"
git clone -q "$GITHUB_BARE" "$STATE11/repos/test-org_probe-repo"

# Codex stub drops a marker if it EVER runs (inverse of scenario 9's snapshot):
# the gate must fire before the pipeline, so the marker must stay absent. Full
# prompts are still staged from scenario 7 ($HOME/.pr-reviewer/prompts), so a
# regressed gate WOULD reach run_codex and write the marker — an honest fence,
# not a vacuous pass on an early build_prompt abort.
CODEX_RAN11="$STATE11/codex-ran.marker"
cat > "$HOME/.local/bin/codex" <<STUB
#!/usr/bin/env bash
touch "$CODEX_RAN11"
exit 1
STUB
chmod +x "$HOME/.local/bin/codex"

run_worker_in_state "$STATE11" \
    "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Test PR" "false" || true

rm -f "$HOME/.local/bin/codex"   # don't leak the fake codex past this scenario

RUN_DIR11=$(find "$STATE11/runs" -type d -name 'test-org_probe-repo__*__*' | head -1)
if [ -z "$RUN_DIR11" ]; then
    echo "FAIL: scenario 11 — worker produced no run dir under $STATE11/runs"
    exit 1
fi
LOG11="$RUN_DIR11/run.log"

# (a) Aborted BEFORE the specialists: the codex stub never ran, so no tokens
# would have been spent. This is the whole point of the pre-spend gate.
if [ -f "$CODEX_RAN11" ]; then
    echo "FAIL: scenario 11 — codex ran despite the stale head (pre-spend gate did not abort before the specialists)"
    [ -f "$LOG11" ] && { echo "--- run.log ---"; tail -n 30 "$LOG11"; }
    exit 1
fi

# (b) Placeholder PATCHed to the superseded body via the EXIT trap, naming both
# short SHAs (reviewed → current) so the human sees why this run cancelled.
if ! jq -e --arg new "${NEW_PR_SHA:0:7}" --arg old "${OLD_PR_SHA:0:7}" \
        '[.[] | select((.body | contains("review superseded")) and (.body | contains($new)) and (.body | contains($old)))] | length == 1' \
        "$STORE11" >/dev/null; then
    echo "FAIL: scenario 11 — placeholder not PATCHed to the superseded body naming ${NEW_PR_SHA:0:7} → ${OLD_PR_SHA:0:7}"
    jq -r '.[] | "  id=\(.id) body=\(.body | gsub("\n";" ") | .[0:90])"' "$STORE11"
    [ -f "$LOG11" ] && { echo "--- run.log ---"; tail -n 30 "$LOG11"; }
    exit 1
fi

# (c) meta.json stamped aborted — the run stays OUT of KNOWN_SHA dedup
# (stage_prior_reviews includes only posted_at/completed runs), so the next
# orchestrator tick sees the new head as unreviewed and re-runs it.
META11="$RUN_DIR11/meta.json"
if [ ! -f "$META11" ]; then
    echo "FAIL: scenario 11 — $META11 not written"
    exit 1
fi
meta_status11=$(jq -r '.status' "$META11")
if [ "$meta_status11" != "aborted" ]; then
    echo "FAIL: scenario 11 — meta.json.status = $meta_status11 (expected 'aborted' — a superseded run must not enter KNOWN_SHA dedup)"
    exit 1
fi

# ===== Scenario 12: whole-PR re-review (FORCE_WHOLE_PR=true) keeps memory =====
# Fences the plow#1032 fix: /srosro-review used to blank PREV_BODY, skip
# prior-reviews.md, stage a pr-comments.md sentinel, and suppress REEVAL-LOC-
# TRIGGER; whole-PR mode must now differ from incremental ONLY in diff scope.
echo "  scenario: whole-PR re-review keeps memory (previous/prior reviews, pr-comments, REEVAL-LOC-TRIGGER)..."

STATE12="$TMPDIR/state-12"
seed_state_dir "$STATE12"
git clone -q "$GITHUB_BARE" "$STATE12/repos/test-org_probe-repo"

# Seed a prior posted round + an operator decline (the dropped memory).
SEED12_ID="test-org_probe-repo__1__20260101T000000000Z__oldpr12"
mkdir -p "$STATE12/runs/$SEED12_ID/agents/aggregator"
printf 'Prior round probe: seed-marker-unbounded-retry\n\nVERDICT: COMMENT\n' > "$STATE12/runs/$SEED12_ID/agents/aggregator/output.md"
printf '{"pr_id":"test-org/probe-repo#1","reviewed_sha":"%s","status":"completed","posted_at":"2026-01-01T00:00:00Z"}' \
    "$OLD_PR_SHA" > "$STATE12/runs/$SEED12_ID/meta.json"
COMMENTS12="$TMPDIR/issue-comments-12.json"
printf '[{"user":{"login":"test-user"},"body":"Declining seed-marker-unbounded-retry: the retry bound is intentional.","created_at":"2026-01-02T00:00:00Z"}]' > "$COMMENTS12"

write_gh_stub "$HOME/.local/bin/gh" "main" "$NEW_PR_SHA"
GH_STUB_ISSUE_COMMENTS_FILE="$COMMENTS12" run_worker_in_state "$STATE12" \
    "test-org/probe-repo" "1" "$NEW_PR_SHA" "feat/test" "Whole-PR memory" "true" || true

RUN12=$(find "$STATE12/runs" -maxdepth 1 -type d -name 'test-org_probe-repo__1__*' ! -name "$SEED12_ID" | head -1)
[ -n "$RUN12" ] || { echo "FAIL: scenario 12 — worker produced no run dir"; exit 1; }
IN12="$RUN12/inputs"

# Memory surfaces staged with real content ("file:required text").
for want in \
    "previous-review.md:seed-marker-unbounded-retry" \
    "prior-reviews.md:seed-marker-unbounded-retry" \
    "pr-comments.md:the retry bound is intentional" \
    "review-task.md:FULL PR diff"; do
    if ! grep -q "${want#*:}" "$IN12/${want%%:*}" 2>/dev/null; then
        echo "FAIL: scenario 12 — ${want%%:*} missing '${want#*:}' (whole-PR path dropped this memory surface)"
        [ -f "$RUN12/run.log" ] && { echo "--- run.log ---"; tail -n 30 "$RUN12/run.log"; }
        exit 1
    fi
done
# reeval-status.md must carry loc-trend.md's computed REEVAL-LOC-TRIGGER line
# verbatim — any worker-side override (incl. the retired one) breaks equality.
LOC_LINE12=$(grep -m1 '^REEVAL-LOC-TRIGGER:' "$IN12/loc-trend.md")
[ -z "$LOC_LINE12" ] && LOC_LINE12="REEVAL-LOC-TRIGGER: unknown (no flag emitted)"
if ! grep -qF "$LOC_LINE12" "$IN12/reeval-status.md"; then
    echo "FAIL: scenario 12 — reeval-status.md lost loc-trend's computed '$LOC_LINE12' (whole-PR override regressed)"
    exit 1
fi

echo "  PASS (16 scenarios: SHA race + non-default-base + canonical alignment + worker dedup gate + container-mode untrusted-author skip + container-mode indeterminate-trust defer + metadata-lookup guard pre-allocation abort + placeholder reuse anti-spam + codex 429 backoff + usage-cap quota placeholder w/ pool status + both-sentinel fatal-auth precedence + convention-repo scratch staging + repo-env seed→trusted mirror + repo-env seed fail-loud + pre-spend superseded abort + whole-PR re-review keeps memory)"
