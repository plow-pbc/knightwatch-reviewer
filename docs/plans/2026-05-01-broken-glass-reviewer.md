# Broken-Glass Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Broken-Glass voice posture + re-review loop-breaker mode in kw-reviewer. PRs that balloon across rounds (PR#534/#552 dynamics) get a dedicated structural callout and inquisitive-voice findings that name the cost of additive remedies.

**Architecture:** Eight prompt/standard edits across `vibe-engineering` and `knightwatch-reviewer` plus an orchestrator wire-in for `loc-trend.md` and the new `momentum` specialist. Voice posture (questions over prescriptions; cost-naming for scope creep) is enforced via a single canonical rule in `CODING_STANDARDS.md` § Broken-Glass Test, with thin pointers in each prompt that doesn't inherit `common-header.md`.

**Tech Stack:** Bash (orchestrator + smoke tests), Markdown (prompts + standards), `git ls-tree`/`git show` for `.knightwatch/` per-repo config (existing seam in `lib/knightwatch-config.sh`).

**Spec:** [`docs/specs/2026-05-01-broken-glass-reviewer-design.md`](../specs/2026-05-01-broken-glass-reviewer-design.md).

---

## Branch setup

This plan touches two repos (`vibe-engineering` for Tasks 1-2; `knightwatch-reviewer` for Tasks 3-12). Each repo gets one feature branch.

- [ ] **Step 0a: Create knightwatch-reviewer branch off main**

The spec was committed on `refactor/reviewed-snapshot-seam` as `9e100b73`. Two options for getting the spec onto the new branch:

```bash
cd ~/Hacking/knightwatch-reviewer
git fetch origin
git checkout -b feat/broken-glass-reviewer origin/main

# Option A (recommended) — cherry-pick the spec onto this branch, so the
# implementation PR ships the spec and the plan together:
git cherry-pick 9e100b73

# Option B — skip the cherry-pick. The spec arrives when
# refactor/reviewed-snapshot-seam merges to main. The plan tasks all
# reference the spec via filepath, not via git history, so they work
# either way.
```

Verify either: the spec exists at the expected path, OR the operator has chosen Option B and accepts that `docs/specs/2026-05-01-broken-glass-reviewer-design.md` won't be on this branch yet.

```bash
test -f docs/specs/2026-05-01-broken-glass-reviewer-design.md && echo "spec present" || echo "spec absent (Option B)"
```

- [ ] **Step 0b: Create vibe-engineering branch off main**

```bash
cd ~/Hacking/vibe-engineering
git fetch origin
git checkout -b feat/broken-glass-test origin/main
```

---

## Task 1: Add § Broken-Glass Test to `CODING_STANDARDS.md` (vibe-engineering)

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` (insert new section after § Anti-Bloat, before § Incremental Improvement)

This is the canonical home for the standard. Specialists, critic, aggregator, and the new momentum specialist all cite it by name.

- [ ] **Step 1.1: Read the current file to find the insertion point**

```bash
cd ~/Hacking/vibe-engineering
grep -n '^## ' claude-config/CODING_STANDARDS.md
```

Expected: `## Anti-Bloat` followed by `## Incremental Improvement`. The new section goes between them.

- [ ] **Step 1.2: Insert § Broken-Glass Test section**

Use the Edit tool to insert this section in `claude-config/CODING_STANDARDS.md` between `## Anti-Bloat` and `## Incremental Improvement`:

```markdown
## Broken-Glass Test

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels: for me to even send you an invitation, I'd first have to find out your 'workspace URL' which very few people knew." — Stewart Butterfield on Slack's shared-channels beta

At our scale (~10 users, pre-PMF — see `.knightwatch/review-priority.md`), the reviewer's job is to catch real bugs and push for elegant code that lets us discover product-market fit. It is *not* to push for handling user types, scale, or behaviors we don't have yet. Architecture complexity for hypothetical scenarios is broken-glass cleanup — calcified branches that have to be preserved through every future refactor — disguised as diligence.

### Voice posture: questions over prescriptions

Default voice on every non-bug finding is **inquisitive**. State the #1 assumption explicitly as a question. The reviewer is the team's "could-this-actually-happen" check, not its "you must address this" enforcer.

Declarative voice is reserved for high-confidence bugs only. The bar: *can you cite the failing path, the user-observable outcome, and the line where the contract breaks?* Examples that meet the bar — reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. Examples that don't meet the bar — "this could break if X," "this would scale poorly to N users," "this is missing a guard for Y."

### Question template

```
Will [user state X / data shape Y / scale Z]?
- If yes, [proposed action].
- If not, consider cutting [proposed action] — adds complexity and makes PMF iteration harder.
[Optional: recommendation given the operating point.]
```

The phrase **"adds complexity and makes PMF iteration harder"** is load-bearing for scope-creep findings. It names the *cost* of the additive remedy so the author chooses between two visible costs (broken-glass risk vs. complexity), not between "fix the issue" and "ignore the reviewer." Acceptable variants when the cost differs: "calcifies a branch the next refactor must preserve," "trades simple-and-fail-loud for layered defenses."

### Worked-example reframings

**Taxonomy demand for first-instance directory** — declarative version: *"`team-skills/` is a new repo storage class with no taxonomy or guard contract; the taxonomy and guard should name it."* Reframed:

> Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships `team-skills/` content into the runtime.

**Unrelated guard-update ask** — declarative version: *"`scripts/check_protected_paths.py` still omits `plow-local-token`; add it to the existing `user-state` rule."* Reframed:

> Has any agent task touched `plow-local-token` in the last fortnight? If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder.

**Demand for layer-by-layer regression tests** — declarative version: *"This bug-fix pass still ships without focused regression tests; 1-2 tests pinning `import_csv()`, `import_legacy_log()`, and `next_batch()` would cover the important paths."* Reframed:

> Has the upstream CSV format changed twice in the last quarter? If yes, 1-2 in-memory SQLite tests pinning the import path are worth ~10 LOC each. If not, fail-loud-on-bad-shape is acceptable; consider cutting the layer-by-layer coverage demand — adds complexity and makes PMF iteration harder.

**Review questions:**
- *Is this remedy solving for a user, user type, or behavior that doesn't yet exist? At our scale, would the failure even be visible in production today?*
- *Did this finding name its #1 assumption as a question, or was it asserted as if the assumption is settled?*
- *For scope-creep findings: did the question name the cost (adds complexity / calcifies a branch / makes PMF iteration harder)?*

For per-repo current operating points + concrete contrast pairs, see `.knightwatch/review-priority.md` in each tracked repo.
```

- [ ] **Step 1.3: Verify the section was inserted correctly**

```bash
grep -c '^## Broken-Glass Test' ~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md
grep -c '^## Anti-Bloat' ~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md
grep -c '^## Incremental Improvement' ~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md
```

Expected: `1` for each.

- [ ] **Step 1.4: Verify the symlink at `~/.claude/CODING_STANDARDS.md` resolves to the updated content**

```bash
grep -c '^## Broken-Glass Test' ~/.claude/CODING_STANDARDS.md
```

Expected: `1`. (The reviewer reads via this symlink path during `STANDARDS+=$(cat ~/.claude/CODING_STANDARDS.md)` in `lib/review-one-pr.sh:551`.)

---

## Task 2: Seed two entries into `COMMENT_REVIEW_MISTAKES.md` (vibe-engineering)

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md` (append two entries)

- [ ] **Step 2.1: Append two new numbered entries to the end of the list**

Read the file first to find the highest existing entry number:

```bash
tail -1 ~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md
```

Use Edit to append (after entry 11):

```markdown
12. Don't propose remedies that solve for users, scale, or behaviors we don't have yet. The product is small (see `.knightwatch/review-priority.md`); remedies should match that reality. The elegant + fail-loud version of a fix is preferred over the defensive version that silently handles a hypothetical population.
13. Lead non-bug findings with the #1 assumption as a question, not as an assertion. For scope-creep findings specifically, the question must name the cost: *"adds complexity and makes PMF iteration harder."* Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). When a finding is asserted but the assumption could go either way, that's a calibration miss — reframe it.
```

- [ ] **Step 2.2: Verify the two entries are present**

```bash
grep -c '^12\. Don.t propose remedies' ~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md
grep -c '^13\. Lead non-bug findings' ~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md
grep -c '^## Comment Review Mistakes\|^# Comment Review Mistakes' ~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md
```

Expected: `1`, `1`, `1`.

- [ ] **Step 2.3: Commit Tasks 1+2 in vibe-engineering**

```bash
cd ~/Hacking/vibe-engineering
git add claude-config/CODING_STANDARDS.md claude-config/COMMENT_REVIEW_MISTAKES.md
git commit -m "$(cat <<'EOF'
feat: add § Broken-Glass Test + voice-posture COMMENT_REVIEW_MISTAKES seeds

Two new entries:
- § Broken-Glass Test in CODING_STANDARDS.md — Butterfield quote +
  questions-over-prescriptions voice + cost-naming + worked-example
  reframings.
- Two new COMMENT_REVIEW_MISTAKES entries — Pre-PMF remedies + voice
  posture calibration.

Standard is citable by knightwatch-reviewer specialists/critic/aggregator
once the kw-reviewer side lands (see knightwatch-reviewer feat/broken-glass-reviewer).
EOF
)"
git status -s
```

Expected: nothing modified or staged after the commit.

---

## Task 3: Create `.knightwatch/review-priority.md` (knightwatch-reviewer)

**Files:**
- Create: `~/Hacking/knightwatch-reviewer/.knightwatch/review-priority.md`

This is the per-repo file. The default content (also embedded in the orchestrator script in Task 7) goes here as the knightwatch-reviewer-repo-specific copy.

- [ ] **Step 3.1: Create the file with the default content**

Use the Write tool to create `~/Hacking/knightwatch-reviewer/.knightwatch/review-priority.md`:

```markdown
# Review priority

**Stage:** ~10 users, pre-PMF.

**Cultural emphasis:** SIMPLIFY and FAIL LOUDLY to enable rapid iteration.

We are validating product-market fit. The reviewer's job is to:
- catch real bugs (things that have gone wrong, or will go wrong soon, for a real user),
- push for elegant code that lets us discover PMF faster.

The reviewer's job is **not** to:
- add architecture complexity for users, user types, scale, or behaviors we don't have today.
- ask for defensive code that handles scenarios we haven't observed in production.
- promote abstractions for one or two call sites "in case we add a third."

## Voice — questions over prescriptions

Default voice on every non-bug finding is inquisitive. State the #1 assumption as a question. Do not silence valid concerns by dropping them — surface them as questions that push the author to think hard about whether the broken-glass risk is real. The author is choosing between two costs (broken-glass risk vs. complexity), not being told what to do.

Question template:

```
Will [user state X / data shape Y / scale Z]?
- If yes, [proposed action].
- If not, consider cutting [proposed action] — adds complexity and makes PMF iteration harder.
```

The "adds complexity and makes PMF iteration harder" phrasing is the **cost-naming** muscle. Every scope-creep question must include it (or a near-equivalent — "calcifies a branch the next refactor must preserve," "trades simple-and-fail-loud for layered defenses"). The author is choosing between two visible costs.

Declarative voice is allowed only when the reviewer is *very confident* — reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. The bar: can you cite the failing path, the user-observable outcome, and the line where the contract breaks?

## Concrete contrast pairs (architecture bloat vs bugfix)

| Architecture bloat — DON'T (at our scale) | Bugfix — DO |
|---|---|
| Idempotency token for a hypothetical client double-send. | Code path that can charge a user twice today. |
| Thread pool / queue for an inline call running <10×/min. | Race where a webhook gets dropped under observed concurrency. |
| Multi-tenant scaffolding when there's one tenant. | Cross-tenant data leak when there are two tenants. |
| Wrapper dataclass / snapshot view so internal callers can't mutate state. | Function whose contract changed but two callers still crash. |
| Retry-with-backoff on an internal RPC that's never failed. | Retry on a flaky external API where you've seen the failure. |
| Pluggable provider abstraction for the second LLM you might use. | Bug in the one LLM call you're shipping. |
| Hand-rolled type validation on internal callers. | Validation at a real trust boundary (user input, webhook). |
| Feature flag for behavior nobody asked for. | Feature flag that's load-bearing for an in-flight migration. |
| State-reset / fallback writes for unobserved pollution. | Initialization bug actually causing dirty state in a reproduced path. |
| Companion test for a scenario that can't currently happen. | Regression test for the bug you just fixed. |

Dividing line: **fix what's actually broken or about to be; don't build defenses for users / scale / behaviors you don't have yet — fail loudly instead.**

## Worked-example reframings

These are real published findings reframed through the voice posture.

**Taxonomy demand for first-instance directory** — declarative version: *"`team-skills/` is a new repo storage class with no taxonomy or guard contract; the taxonomy and guard should name it."* Reframed:

> Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships `team-skills/` content into the runtime.

**Unrelated guard-update ask** — declarative version: *"`scripts/check_protected_paths.py` still omits `plow-local-token`; add it to the existing `user-state` rule."* Reframed:

> Has any agent task touched `plow-local-token` in the last fortnight? If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder.

**Demand for layer-by-layer regression tests** — declarative version: *"This bug-fix pass still ships without focused regression tests; 1-2 tests pinning `import_csv()`, `import_legacy_log()`, and `next_batch()` would cover the important paths."* Reframed:

> Has the upstream CSV format changed twice in the last quarter? If yes, 1-2 in-memory SQLite tests pinning the import path are worth ~10 LOC each. If not, fail-loud-on-bad-shape is acceptable; consider cutting the layer-by-layer coverage demand — adds complexity and makes PMF iteration harder.

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels: for me to even send you an invitation, I'd first have to find out your 'workspace URL' which very few people knew." — Stewart Butterfield on Slack's shared-channels beta. Validating PMF first; polishing later.
```

- [ ] **Step 3.2: Commit the file**

```bash
cd ~/Hacking/knightwatch-reviewer
git add .knightwatch/review-priority.md
git commit -m "$(cat <<'EOF'
feat: add .knightwatch/review-priority.md (per-repo operating point)

Stage / cultural emphasis / voice posture / contrast pairs / worked-example
reframings. Loaded by lib/review-one-pr.sh (Task 7+) and interpolated into
common-header.md (Task 8) so every specialist + critic + aggregator sees
the operating point.

Per-repo override seam — operators commit this file to each tracked repo's
base branch. Default content (used when ABSENT) is embedded in the
orchestrator (Task 7).
EOF
)"
```

---

## Task 4: Add `loc-trend.md` computation to `lib/run-dir.sh`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/lib/run-dir.sh` (add `compute_loc_trend()` next to the existing run-dir helpers)
- Modify: `~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh` (call site before specialist fan-out)
- Create: `~/Hacking/knightwatch-reviewer/lib/tests/loc-trend-smoke.sh`

The function reads `~/.pr-reviewer/runs/<repo>__<pr>__*` directories, computes `git diff --shortstat <base_tip>...<sha>` per round (three-dot, source-of-truth SHA from each run's `meta.json.sha`), and writes a markdown table to `.codex-scratch/loc-trend.md`.

- [ ] **Step 4.1: Write the smoke test first (TDD — token-level + behavior contract)**

Create `~/Hacking/knightwatch-reviewer/lib/tests/loc-trend-smoke.sh`:

```bash
#!/bin/bash
# Smoke for compute_loc_trend (lib/review-one-pr.sh).
#
# Three contracts:
#   1. Empty runs/ dir (first review, no prior rounds) → emits header
#      noting it's the first review, no table rows.
#   2. N>1 prior runs → emits a table with one row per run, sorted by
#      timestamp, each row carrying base..head shortstat.
#   3. Trajectory line classifies GROWING / STABLE / SHRINKING based on
#      ratio between first and last round's additions.

set -uo pipefail

TMPDIR=$(mktemp -d -t loc-trend-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Build a fake repo with two commits the function can shortstat against.
REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
echo seed > "$REPO/seed.txt"
git -C "$REPO" add seed.txt && git -C "$REPO" commit -qm "seed"
BASE_SHA=$(git -C "$REPO" rev-parse HEAD)

# round1: small diff
seq 1 10 > "$REPO/round1.txt"
git -C "$REPO" add round1.txt && git -C "$REPO" commit -qm "round1"
SHA1=$(git -C "$REPO" rev-parse HEAD)

# round2: larger diff vs base
seq 1 50 > "$REPO/round2.txt"
git -C "$REPO" add round2.txt && git -C "$REPO" commit -qm "round2"
SHA2=$(git -C "$REPO" rev-parse HEAD)

# Build a fake STATE_DIR/runs layout. compute_loc_trend reads SHA +
# started_at from each run's meta.json (the canonical source-of-truth
# file, written post-checkout with the REVIEWED_SHA), so the fixture
# writes one per round. Dir-name SHA suffixes are deliberately set to
# 7-char strings that do NOT match the meta.json SHA — this fences the
# function: if a future regression rewires it back to parsing the dir
# name, `git diff` would receive a non-existent SHA and the smoke
# would fail.
STATE_DIR="$TMPDIR/state"
mkdir -p "$STATE_DIR/runs"
mk_run_dir() {
    local dir="$1" started_at="$2" sha="$3"
    mkdir -p "$dir"
    jq -n --arg sha "$sha" --arg started_at "$started_at" \
        '{sha: $sha, started_at: $started_at}' > "$dir/meta.json"
}
mk_run_dir "$STATE_DIR/runs/cncorp_plow__999__20260501T000000000Z__deadbe1" \
    "2026-05-01T00:00:00Z" "$SHA1"
mk_run_dir "$STATE_DIR/runs/cncorp_plow__999__20260501T010000000Z__deadbe2" \
    "2026-05-01T01:00:00Z" "$SHA2"

OUT="$TMPDIR/loc-trend.md"

# Source lib/run-dir.sh — that's where compute_loc_trend lives, alongside
# stage_prior_reviews and the other run-dir helpers. The worker already
# sources lib/run-dir.sh, so production and the smoke share the same
# function (no copy, no --source-only guard on the 1200-line worker).
. "$PROJECT_ROOT/lib/run-dir.sh"

# Test 1: 2 prior runs → table with 2 rows + GROWING trajectory
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" > "$OUT"
grep -q '^# LOC trend' "$OUT" || { echo "FAIL: missing header"; exit 1; }
grep -qE 'Trajectory:.*GROWING' "$OUT" || { echo "FAIL: missing/wrong trajectory"; exit 1; }
grep -cE '^\| [0-9]+ \|' "$OUT" | grep -q '^2$' || { echo "FAIL: expected 2 table rows"; exit 1; }

# Test 2: empty runs/ dir → first-review header, no table rows
rm -rf "$STATE_DIR/runs"
mkdir -p "$STATE_DIR/runs"
compute_loc_trend "cncorp/plow" "999" "$REPO" "$BASE_SHA" "$STATE_DIR" > "$OUT"
grep -qE 'first review|no prior rounds' "$OUT" || { echo "FAIL: missing first-review header"; exit 1; }
grep -cE '^\| [0-9]+ \|' "$OUT" | grep -q '^0$' || { echo "FAIL: expected 0 table rows"; exit 1; }

echo "  PASS"
```

Run it:

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/loc-trend-smoke.sh
```

Expected: FAIL — `compute_loc_trend` is undefined in `lib/run-dir.sh`.

- [ ] **Step 4.2: Add `compute_loc_trend()` to `lib/run-dir.sh`**

`lib/run-dir.sh` is the existing run-dir-helpers seam — `allocate_run_dir`, `stage_prior_reviews`, `finalize_meta_json`, etc. all live there, and the worker already sources it at startup. New run-dir helpers go here, alongside their siblings; production and tests share the same definition. Append after the existing `stage_prior_reviews` function:

```bash
# compute_loc_trend <repo_slash> <pr_num> <repo_dir> <base_tip_sha> <state_dir>
#   stdout: markdown loc-trend.md content
#
# repo_slash is the GitHub slash-form (e.g. "cncorp/plow"), NOT the
# PR_ID (which carries a "#N" suffix). The function converts to
# underscore-form for filesystem matching.
#
# Iterates $state_dir/runs/<owner>_<repo>__<pr_num>__<ts>__<sha>/ entries
# (dir-name pattern is the filter — which runs belong to this PR),
# reads each run's meta.json for the canonical SHA + started_at, and
# computes git diff --shortstat <base_tip>...<sha> per round (three-dot
# semantics, matches GitHub's "Files changed" view). Emits a markdown
# table sorted by timestamp. Handles empty runs/ (first review) and
# pre-checkout abort dirs (no meta.json) without aborting.
#
# SHA source: meta.json.sha (REVIEWED_SHA, captured post-checkout) —
# NOT the dir name's SHA suffix, which encodes the orchestrator's
# enumeration PR_SHA prefix. When a push lands during the worker's
# fetch window, those two diverge; reading meta.json keeps loc-trend
# anchored to the SHA the worker actually reviewed (same source-of-
# truth contract as full-diff.patch / commits.md).
#
# Diff range: three-dot ($base_tip...$sha), NOT two-dot. The orchestrator
# passes BASE_REF_SHA (the current tip of the base branch). When base
# has advanced since the round was reviewed, two-dot would treat
# base-only changes as deletions in the shortstat; three-dot uses
# merge-base($base_tip, $sha) and reports only the PR's actual
# contributions.
compute_loc_trend() {
    local repo="$1" pr_num="$2" repo_dir="$3" base_tip="$4" state_dir="$5"
    local owner_repo="${repo//\//_}"
    local runs_dir="$state_dir/runs"

    echo "# LOC trend"
    echo

    if [ ! -d "$runs_dir" ]; then
        echo "(no prior rounds — first review)"
        return 0
    fi

    # Collect round data. Pre-checkout abort dirs leave no meta.json;
    # those didn't review anything so they're skipped from the trend.
    # A meta.json that DOES exist but is missing sha/started_at is
    # corruption — fail loud rather than silently dropping the round
    # from the trend (would mask a regression that wires loc-trend
    # back to a SHA source other than meta.json).
    #
    # Round entries are tab-delimited "ts<TAB>sha". ISO timestamps
    # contain colons, so a colon-delimited form would split wrong on
    # readback.
    local rounds=()
    while IFS= read -r d; do
        local meta="$d/meta.json"
        [ -f "$meta" ] || continue
        # Same author-visibility predicate as stage_prior_reviews:
        # only count runs the PR author actually saw on GitHub (gh
        # comment posted: posted_at set; or legacy preserved run:
        # status=="completed" — only flips on the success path AFTER
        # the comment has posted in production). Worker aborts that
        # wrote meta.json post-checkout but never reached gh-comment
        # are real runs but DIDN'T contribute a review the author
        # could see, so they shouldn't pad "reviewed N times" / the
        # trajectory ratio.
        local visible
        visible=$(jq -r 'if ((.posted_at // "") != "") or ((.status // "") == "completed") then "yes" else "no" end' "$meta" 2>/dev/null)
        [ "$visible" = "yes" ] || continue
        local ts sha
        ts=$(jq -r '.started_at // empty' "$meta")
        sha=$(jq -r '.sha // empty' "$meta")
        if [ -z "$ts" ] || [ -z "$sha" ]; then
            echo "compute_loc_trend: $meta missing .sha or .started_at — corruption, refusing to silently drop round" >&2
            return 1
        fi
        rounds+=("$(printf '%s\t%s' "$ts" "$sha")")
    done < <(find "$runs_dir" -maxdepth 1 -type d -name "${owner_repo}__${pr_num}__*" 2>/dev/null | sort)

    if [ ${#rounds[@]} -eq 0 ]; then
        echo "(no prior rounds — first review)"
        return 0
    fi

    # First-round and last-round shortstats for trajectory classification.
    # `git diff` is allowed to fail (SHA evicted by force-push, repo
    # corruption, etc.) — but a failure must NOT silently degrade to
    # 0 insertions and then to "STABLE", which would mimic a converged
    # trajectory and trip the aggregator's loop-breaker on a false
    # signal. Track exit status separately and emit explicit UNKNOWN.
    local first_round_adds=0 last_round_adds=0
    local first_shortstat last_shortstat first_ts first_sha last_ts last_sha
    local first_diff_ok=true last_diff_ok=true
    IFS=$'\t' read -r first_ts first_sha <<<"${rounds[0]}"
    IFS=$'\t' read -r last_ts last_sha <<<"${rounds[-1]}"
    first_shortstat=$(git -C "$repo_dir" diff --shortstat "$base_tip...$first_sha" 2>/dev/null) || first_diff_ok=false
    last_shortstat=$(git -C "$repo_dir" diff --shortstat "$base_tip...$last_sha" 2>/dev/null) || last_diff_ok=false

    local trajectory ratio
    if [ "$first_diff_ok" = "false" ] || [ "$last_diff_ok" = "false" ]; then
        echo "compute_loc_trend: git diff failed for first (${first_sha:0:7}) or last (${last_sha:0:7}) anchor — SHA likely unreachable in $repo_dir" >&2
        trajectory="UNKNOWN (anchor SHA unreachable; trend disabled)"
    else
        first_round_adds=$(echo "$first_shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
        last_round_adds=$(echo "$last_shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
        first_round_adds=${first_round_adds:-0}
        last_round_adds=${last_round_adds:-0}
        if [ "$first_round_adds" -eq 0 ]; then
            trajectory="STABLE"
        else
            # Use awk for float math.
            ratio=$(awk -v a="$last_round_adds" -v b="$first_round_adds" 'BEGIN{printf "%.2f", a/b}')
            if awk -v r="$ratio" 'BEGIN{exit !(r >= 1.5)}'; then
                trajectory="GROWING (${ratio}× from first review)"
            elif awk -v r="$ratio" 'BEGIN{exit !(r <= 0.66)}'; then
                trajectory="SHRINKING (${ratio}× from first review)"
            else
                trajectory="STABLE"
            fi
        fi
    fi

    echo "This PR has been reviewed ${#rounds[@]} times. Trajectory: $trajectory."
    echo
    echo "| Round | Timestamp | SHA | base...head |"
    echo "|---|---|---|---|"
    local i=1 round ts sha stat
    for round in "${rounds[@]}"; do
        IFS=$'\t' read -r ts sha <<<"$round"
        stat=$(git -C "$repo_dir" diff --shortstat "$base_tip...$sha" 2>/dev/null | sed 's/^ *//' | tr '\n' ' ')
        [ -z "$stat" ] && stat="(sha not in local history)"
        echo "| $i | $ts | ${sha:0:7} | $stat |"
        i=$((i + 1))
    done
}
```

- [ ] **Step 4.3: Run the smoke test, expect PASS**

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/loc-trend-smoke.sh
```

Expected: `PASS`. If it fails, debug the awk ratio comparison or the git invocation.

- [ ] **Step 4.4: Wire `compute_loc_trend` into the orchestrator's main body**

Find the section in `lib/review-one-pr.sh` that writes scratch files (around line 811: `write_scratch "$REPO_DIR" "standards.md" "$STANDARDS"`). Add immediately after that block:

```bash
# loc-trend.md — per-round LOC trajectory for the momentum specialist
# and aggregator's loop-breaker mode (see § Broken-Glass Test).
LOC_TREND=$(compute_loc_trend "$REPO" "$PR_NUM" "$REPO_DIR" "$BASE_REF_SHA" "$STATE_DIR")
write_scratch "$REPO_DIR" "loc-trend.md" "$LOC_TREND"
```

`$REPO`, `$PR_NUM`, `$REPO_DIR`, `$BASE_REF_SHA`, `$STATE_DIR` are all in scope at the point where `product-context.md` is loaded today (around line 862-882) — the new `loc-trend.md` block goes immediately after that. Verify with `grep -n` if uncertain.

- [ ] **Step 4.5: Wire smoke test into justfile**

Edit `~/Hacking/knightwatch-reviewer/justfile`. Find the existing test block (the area with `bash lib/tests/anti-bloat-contract-smoke.sh`). Add:

```
    echo ""
    echo "=== loc-trend smoke ==="
    bash lib/tests/loc-trend-smoke.sh
```

- [ ] **Step 4.6: Run `just test` to verify**

```bash
cd ~/Hacking/knightwatch-reviewer
just test 2>&1 | tail -20
```

Expected: all smoke tests pass, including `loc-trend smoke`.

- [ ] **Step 4.7: Commit**

```bash
git add lib/run-dir.sh lib/review-one-pr.sh lib/tests/loc-trend-smoke.sh justfile
git commit -m "$(cat <<'EOF'
feat: compute_loc_trend() + loc-trend.md scratch

Per-round LOC trajectory for momentum specialist + aggregator loop-breaker.

Reads ~/.pr-reviewer/runs/<repo>__<pr>__* listing, takes each run's
canonical SHA from meta.json.sha (REVIEWED_SHA), runs git diff
--shortstat with three-dot semantics against the base tip for each
prior SHA, emits a markdown table + trajectory classification
(GROWING / STABLE / SHRINKING).

Lives in lib/run-dir.sh next to the existing run-dir helpers
(allocate_run_dir, stage_prior_reviews, etc.) — production and the
loc-trend smoke share the same definition.
EOF
)"
```

---

## Task 5: Add `review-priority.md` load to `lib/review-one-pr.sh`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh` (add load block after the existing `product-context.md` load)
- Modify: `~/Hacking/knightwatch-reviewer/lib/tests/knightwatch-config-smoke.sh` (extend to cover the new file)

- [ ] **Step 5.1: Find where `product-context.md` is loaded today**

```bash
grep -n 'product-context' ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
```

- [ ] **Step 5.2: Add the `review-priority.md` load block, mirroring the existing `product-context.md` pattern**

Look at the existing `product-context.md` block at lines 862-882 for reference — it uses `case $?` after capturing the exit code from `read_knightwatch_file`. Mirror that pattern exactly. Insert the new block immediately after the `product-context.md` block:

```bash
# review-priority.md — per-repo operating point + voice posture
# (Broken-Glass Test in standards.md cites this file by name).
# Tri-state: PRESENT use file; ABSENT use embedded default; ERROR abort.
REVIEW_PRIORITY=""
REVIEW_PRIORITY=$(read_knightwatch_file "$REPO_DIR" "$BASE_REF_SHA" "review-priority.md")
case $? in
    0) : ;;  # PRESENT: use as-is
    1)
        # ABSENT: use embedded default (matches today's universal operating point)
        REVIEW_PRIORITY=$(cat <<'PRIORITY_EOF'
# Review priority

**Stage:** ~10 users, pre-PMF.

**Cultural emphasis:** SIMPLIFY and FAIL LOUDLY to enable rapid iteration.

We are validating product-market fit. The reviewer's job is to:
- catch real bugs (things that have gone wrong, or will go wrong soon, for a real user),
- push for elegant code that lets us discover PMF faster.

The reviewer's job is **not** to:
- add architecture complexity for users, user types, scale, or behaviors we don't have today.
- ask for defensive code that handles scenarios we haven't observed in production.
- promote abstractions for one or two call sites "in case we add a third."

## Voice — questions over prescriptions

Default voice on every non-bug finding is inquisitive. State the #1 assumption as a question. The author is choosing between two costs (broken-glass risk vs. complexity), not being told what to do.

Question template: Will [state X]? If yes, [Y]. If not, consider cutting [Y] — adds complexity and makes PMF iteration harder.

Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause).

Dividing line: fix what's actually broken or about to be; don't build defenses for users / scale / behaviors you don't have yet — fail loudly instead.

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels..." — Stewart Butterfield. Validating PMF first; polishing later.
PRIORITY_EOF
)
        log "$PR_ID: review-priority.md ABSENT in $BASE_REF_SHA — using default content"
        ;;
    *) log "$PR_ID: knightwatch-config error reading review-priority.md — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
write_scratch "$REPO_DIR" "review-priority.md" "$REVIEW_PRIORITY"
```

The default content here is the abridged version — full content lives in the per-repo file (Task 3). The default fires only on cold-start operator setups.

- [ ] **Step 5.3: Extend `knightwatch-config-smoke.sh` to verify `review-priority.md` round-trips**

Read the existing smoke file to find where it tests `product-context.md`:

```bash
grep -n 'product-context' ~/Hacking/knightwatch-reviewer/lib/tests/knightwatch-config-smoke.sh
```

Add a parallel test block for `review-priority.md`. The existing test follows a pattern: write the file on main, run `read_knightwatch_file` against main (expect content), then against feature-only (expect absent → exit 1). Mirror that pattern.

```bash
# review-priority.md — same trust model: only base-branch reads count.
echo "review-priority test content" > "$SOURCE/.knightwatch/review-priority.md"
git -C "$SOURCE" add .knightwatch/review-priority.md
git -C "$SOURCE" commit -qm "main: add review-priority"

# (Add the parallel base-vs-feature read assertion here, mirroring the
# product-context.md block above it.)
```

- [ ] **Step 5.4: Run smoke + verify pass**

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/knightwatch-config-smoke.sh
```

Expected: PASS.

- [ ] **Step 5.5: Commit**

```bash
git add lib/review-one-pr.sh lib/tests/knightwatch-config-smoke.sh
git commit -m "$(cat <<'EOF'
feat: load .knightwatch/review-priority.md into scratch

Tri-state load (PRESENT use file; ABSENT use embedded default;
ERROR abort) following the same pattern as product-context.md.

Default content embedded inline so cold-start operator setups (no
.knightwatch/review-priority.md in any tracked repo's base branch
yet) get a reasonable operating point automatically.

Smoke extended to cover the new file's PRESENT/ABSENT semantics.
EOF
)"
```

---

## Task 6: Add voice-posture pointer + review-priority reference to `prompts/common-header.md`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/prompts/common-header.md` (add voice-posture pointer at top + reference `review-priority.md` in inputs list)
- Modify: `~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh` (add token assertions)

**Note on substitution.** `lib/prompt-build.sh::substitute_placeholders` does NOT have a `{{REVIEW_PRIORITY}}` substitution today, and we deliberately don't add one. Specialists already read `.codex-scratch/<input>.md` files directly per common-header.md's existing `**Inputs already prepared for you:**` block. We're adding `review-priority.md` to that list and instructing specialists to read it FIRST. This keeps `prompt-build.sh` unchanged and avoids tying a prompt-time substitution to a runtime-resolved file.

- [ ] **Step 6.1: Read current common-header.md to find insertion point**

```bash
head -15 ~/Hacking/knightwatch-reviewer/prompts/common-header.md
```

The natural insertion point is right after `**Working directory:**` and before `**Inputs already prepared for you:**`.

- [ ] **Step 6.2: Add the voice-posture pointer block**

Insert immediately after the `**Working directory:**` paragraph, before the `**Inputs already prepared for you:**` block:

```markdown

**Operating point and voice posture (READ FIRST):** Read `.codex-scratch/review-priority.md` before any other input. It carries the per-repo operating point (stage / user count / cultural emphasis) and the voice-posture rules every finding you produce must follow. Apply `standards.md` § Broken-Glass Test on every finding: questions over prescriptions on every non-bug finding; declarative voice only when you can cite the failing path, the user-observable outcome, and the line where the contract breaks; scope-creep questions must name the cost ("adds complexity and makes PMF iteration harder").

```

- [ ] **Step 6.3: Add `review-priority.md` to the inputs list**

Find the `**Inputs already prepared for you:**` block in common-header.md. Add a new bullet near the top of the list (after `inferred-intent.md` is the natural slot):

```markdown
- `.codex-scratch/review-priority.md` — per-repo operating point (stage, cultural emphasis) and voice-posture rules. Read this FIRST. Cite `Broken-Glass Test` by name when applying its voice posture or contrast pairs.
```

- [ ] **Step 6.4: Extend `anti-bloat-contract-smoke.sh` with new token assertions**

Add to `lib/tests/anti-bloat-contract-smoke.sh` (after the existing `Rule 8` assertion block):

```bash
echo "  asserting voice-posture pointer in common-header.md..."
assert_grep "common-header.md should reference Broken-Glass Test" \
    "Broken-Glass Test" prompts/common-header.md
assert_grep "common-header.md should mandate cost-naming" \
    "adds complexity and makes PMF iteration harder" prompts/common-header.md
assert_grep "common-header.md should reference review-priority.md scratch input" \
    "review-priority.md" prompts/common-header.md
```

- [ ] **Step 6.5: Run smoke + verify pass**

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh
bash ~/Hacking/knightwatch-reviewer/lib/tests/build-specialist-prompt-smoke.sh
```

Expected: both PASS. (`build-specialist-prompt-smoke.sh` should still pass — we didn't touch `prompt-build.sh`.)

- [ ] **Step 6.6: Commit**

```bash
git add prompts/common-header.md lib/tests/anti-bloat-contract-smoke.sh
git commit -m "$(cat <<'EOF'
feat: voice-posture pointer + review-priority.md reference in common-header.md

Specialists now read .codex-scratch/review-priority.md FIRST and
apply standards.md § Broken-Glass Test on every finding.

No prompt-build.sh substitution change — specialists read the scratch
file directly, same pattern as product-context.md / inferred-intent.md /
file-history.md / etc. Avoids tying a prompt-time substitution to a
runtime-resolved file.

Smoke extended (token-level checks; no content pinning).
EOF
)"
```

---

## Task 7: Add voice-posture audit + REFRAME-AS-QUESTION to `prompts/critic.md`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/prompts/critic.md`
- Modify: `~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh`

- [ ] **Step 7.1: Add voice-posture pointer to the top of `critic.md`**

Find the existing top of critic.md (after `You are the devil's advocate...`) and insert:

```markdown

**Voice posture (apply on every finding you process):** Apply `standards.md` § Broken-Glass Test — every non-bug finding's #1 assumption must be stated as a question. Declarative voice is allowed only when the specialist can cite the failing path, the user-observable outcome, and the line where the contract breaks. For scope-creep findings (asking the PR to update unrelated infra, fix a long-pre-existing gap, expand into adjacent policy), reframe with the cost-naming clause: *"adds complexity and makes PMF iteration harder."*

```

- [ ] **Step 7.2: Add REFRAME-AS-QUESTION bucket to the status table**

Find the section in critic.md describing the status buckets (AGREE / FALSE POSITIVE / OVER-SPECIFIC / MISCALIBRATED / REMEDY-BLOAT / ALREADY ADDRESSED / DUPLICATE). Add an 8th bucket:

```markdown
8. **REFRAME-AS-QUESTION** — finding's underlying concern is real (so it's not FALSE POSITIVE), AND the proposed remedy is additive (adds defensive code, abstraction, validation, test, branch, file), AND the author could legitimately decide either way once the assumption is named. When applied, emit the reframed text inline so the aggregator can drop it directly into Open Questions:

   ```
   ### [<specialist>] Finding N — REFRAME-AS-QUESTION
   <one-line reason: what assumption is being asserted as if settled>
   Reframe:
   > Will [state X]? If yes, [Y]. If not, consider cutting [Y] — adds complexity and makes PMF iteration harder.
   > [Optional recommendation given operating point.]
   ```

   Scope-creep findings (asking the PR to update unrelated infra, fix a pre-existing gap, expand adjacent policy) MUST be REFRAME-AS-QUESTION'd if they survive — they are not bugs, the remedy is additive, and the cost-naming forces the author to weigh in. The reframe MUST include explicit cost language ("adds complexity and makes PMF iteration harder").
```

- [ ] **Step 7.3: Add Pre-PMF lens conditional**

Add a new section after the bucket descriptions in critic.md:

```markdown
**Pre-PMF lens (conditional).** If `.codex-scratch/loc-trend.md` shows GROWING and Bug-Class-Recurrence has fired in this round or any prior round (visible in `prior-reviews.md`), apply the lens to *every surviving finding*: would the failure mode the remedy is preventing be observed in production at our scale today? If no AND the remedy is additive without observed need → REMEDY-BLOAT (drop entirely). If no but the underlying concern is real → REFRAME-AS-QUESTION.
```

- [ ] **Step 7.4: Update the output schema example**

Find the output format example in critic.md (the `## Critic counterarguments` template). Update the listed status options to include `REFRAME-AS-QUESTION`:

```markdown
### [security] Finding N — <status: AGREE | FALSE POSITIVE | OVER-SPECIFIC | MISCALIBRATED | REMEDY-BLOAT | REFRAME-AS-QUESTION | ALREADY ADDRESSED | DUPLICATE OF [other-specialist] Finding M>
```

- [ ] **Step 7.5: Extend `anti-bloat-contract-smoke.sh`**

```bash
echo "  asserting REFRAME-AS-QUESTION bucket in critic.md..."
assert_grep "REFRAME-AS-QUESTION bucket missing from prompts/critic.md" \
    "REFRAME-AS-QUESTION" prompts/critic.md
echo "  asserting voice-posture pointer in critic.md..."
assert_grep "critic.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/critic.md
echo "  asserting Pre-PMF lens in critic.md..."
assert_grep "critic.md should reference Pre-PMF lens (loc-trend.md)" \
    "loc-trend.md" prompts/critic.md
```

- [ ] **Step 7.6: Run smoke + commit**

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh
git add prompts/critic.md lib/tests/anti-bloat-contract-smoke.sh
git commit -m "$(cat <<'EOF'
feat: voice-posture audit + REFRAME-AS-QUESTION + Pre-PMF lens (critic)

8th status bucket alongside REMEDY-BLOAT et al. — for findings whose
underlying concern is real but the proposed remedy is additive and the
author could legitimately decide either way. Critic emits reframed
question + cost-naming clause inline so aggregator can lift to Open
Questions.

Voice-posture pointer cites § Broken-Glass Test. Pre-PMF lens fires
when loc-trend.md shows GROWING and Bug-Class-Recurrence has fired.
EOF
)"
```

---

## Task 8: Add voice posture + Open Questions structure + loop-breaker to `prompts/aggregator.md`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/prompts/aggregator.md`
- Modify: `~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh`

This task has three sub-changes (G1 voice posture, G2 Open Questions structure, G3 loop-breaker). Apply them in order.

- [ ] **Step 8.1: Add voice-posture pointer to the top of aggregator.md**

Insert after `You are the aggregator in a multi-specialist PR review.`:

```markdown

**Voice posture (apply across published findings):** Apply `standards.md` § Broken-Glass Test on every published finding. Declarative voice is allowed only when the specialist (after critic stress-test) can cite the failing path, the user-observable outcome, and the line where the contract breaks. All other surviving findings lead with their #1 assumption as a question; scope-creep findings name the cost ("adds complexity and makes PMF iteration harder").

```

- [ ] **Step 8.2: Add (G1) voice posture handling to step 1**

In aggregator.md step 1 (where critic verdicts are applied), add a new sub-bullet:

```markdown
   - **Voice-posture audit:** before publishing each surviving finding, check whether it leads with the assumption-as-question. If declarative-but-not-high-confidence, rewrite the leading sentence as a question (template: *"Will [state X]? If yes, [Y]. If not, consider cutting [Y] — adds complexity and makes PMF iteration harder."*). Keep the file/line citation and standard reference. Do not water down the underlying concern; only the *posture* changes.
```

- [ ] **Step 8.3: Add (G2) Open Questions structured format**

Find the existing `**Open Questions**` section in aggregator.md (in the output template). Replace with:

```markdown
**Open Questions** — homes for legitimate concerns whose remedy is additive enough that the author should answer rather than absorb. Includes critic REFRAME-AS-QUESTION outputs verbatim. Format:

- **Q: <name the choice in 5-10 words>** — <state-trigger sentence>. <If-yes branch.> <If-not branch with cost-naming.> <Optional: recommendation given operating point.>

Example:

- **Q: Permanent fourth taxonomy class, or one-off?** — Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder.

Open Questions is no longer "padding" — it's the home for reviewer pushback that doesn't rise to a Finding. Don't drop these to keep the review short; questions are the unit of pushback. Cap at quality, not volume — questions that don't meet the template (state-trigger + if-not-branch with cost-naming + optional recommendation) get dropped, same bar as Findings.
```

- [ ] **Step 8.4: Add (G3) re-review loop-breaker mode to step 6**

Find existing aggregator.md step 6 (the first-review-only step-back signal). Modify the introduction:

```markdown
**Step-back signal — PR fundamentally not iterable.** Two trigger paths:

**Path 1 (first-review only — existing behavior).** If `previous-review.md` is empty AND surviving findings indicate the PR is too broken to converge through review iteration, switch to redirect mode: 200-400-word redirect, 3 most structural issues, recommend close + resubmit smaller. (No change from today.)

**Path 2 (re-review loop-breaker — NEW).** Fires when `previous-review.md` is non-empty AND any of:

- `.codex-scratch/loc-trend.md` shows GROWING (≥1.5×) AND Bug-Class-Recurrence has fired in this round or any prior round (visible in `prior-reviews.md`), OR
- Bug-Class-Recurrence has fired in 2+ prior rounds (regardless of LOC trajectory — catches the dynamic where the author held LOC stable but ignored the structural ask).

When Path 2 fires:

1. **Promote the momentum specialist's output verbatim** as a dedicated callout block at the top of the review, immediately after the intent line and before `**Overview**`. Format with visual weight:

   ```
   > **Why this PR isn't converging?**
   >
   > <full momentum specialist prose, including its closing question>
   ```

2. **Keep the local findings** in the numbered Findings list, ranked by severity, all subject to (G1) voice posture. Not dropped — but the structural callout has eaten the visual real estate.
3. **Add a closing question** in the Overview: *"Are we ready to commit to the structural direction in the callout above, or is continuing to patch leaves the better trade given X? Addressing the local findings below before the direction is settled is how PRs balloon."*
4. **Verdict stays `COMMENT`.**
```

- [ ] **Step 8.5: Add momentum.md to aggregator inputs list**

Find the inputs list in aggregator.md (the `**Inputs:**` block). Add:

```markdown
- `.codex-scratch/agents/momentum/output.md` — present *only* on re-reviews; prose-only meta-finding from the momentum specialist. Read this before drafting findings; if Path 2 of the step-back signal fires, this output becomes the structural callout verbatim.
- `.codex-scratch/loc-trend.md` — per-round LOC trajectory + GROWING/STABLE/SHRINKING classification. Used by Path 2 trigger.
```

- [ ] **Step 8.6: Extend smoke**

```bash
echo "  asserting voice-posture pointer in aggregator.md..."
assert_grep "aggregator.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/aggregator.md
echo "  asserting Open Questions structured format..."
assert_grep "aggregator.md should describe Q: question format" \
    "**Q:" prompts/aggregator.md
echo "  asserting re-review loop-breaker mode (Path 2)..."
assert_grep "aggregator.md should reference loc-trend.md trigger" \
    "loc-trend.md" prompts/aggregator.md
assert_grep "aggregator.md should reference momentum specialist" \
    "agents/momentum" prompts/aggregator.md
```

- [ ] **Step 8.7: Run smoke + commit**

```bash
bash ~/Hacking/knightwatch-reviewer/lib/tests/anti-bloat-contract-smoke.sh
git add prompts/aggregator.md lib/tests/anti-bloat-contract-smoke.sh
git commit -m "$(cat <<'EOF'
feat: voice posture + Open Questions structure + loop-breaker (aggregator)

Three sub-changes:
(G1) Voice-posture audit on every published finding — declarative
     only for high-confidence bugs; everything else leads with
     assumption-as-question + cost-naming for additive remedies.
(G2) Structured Open Questions format (**Q:** template) — home for
     critic REFRAME-AS-QUESTION outputs + reviewer pushback that
     shouldn't dictate a remedy.
(G3) Re-review loop-breaker (Path 2 of step-back signal) — fires on
     LOC trajectory + Bug-Class-Recurrence; promotes momentum prose
     to a top-of-review callout, keeps locals subordinate.

momentum.md + loc-trend.md added to aggregator inputs list.
EOF
)"
```

---

## Task 9: Create `prompts/momentum.md` specialist

**Files:**
- Create: `~/Hacking/knightwatch-reviewer/prompts/momentum.md`

The momentum specialist is a new prompt file. It runs only on re-reviews. Its output is prose-only and ends with a question.

- [ ] **Step 9.1: Create the file**

Use the Write tool to create `~/Hacking/knightwatch-reviewer/prompts/momentum.md`:

```markdown
You are the momentum specialist in a multi-specialist PR review. You run **only on re-reviews** (when `previous-review.md` is non-empty); on first reviews you should not be invoked.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**URL:** {{PR_URL}}

**Voice posture (load-bearing):** Apply `standards.md` § Broken-Glass Test. Your output is prose, not severity-tagged findings, but it MUST end with a question — your role is to surface the trajectory pattern and force the author to articulate whether continuing it is worth the cost. Do not direct; ask. The cost-naming clause ("adds complexity and makes PMF iteration harder," or near-equivalents) MUST appear when the trajectory is being driven by additive findings.

**Operating point (READ FIRST):** Read `.codex-scratch/review-priority.md` before any other input. It carries the per-repo stage, cultural emphasis, and voice-posture rules; cite `Broken-Glass Test` by name when applying.

**Inputs:**
- `.codex-scratch/review-priority.md` — operating point (read first; cite Broken-Glass Test).
- `.codex-scratch/prior-reviews.md` — concatenated prior aggregator outputs (most recent last). Read all of them.
- `.codex-scratch/commits.md` — commit subjects on this branch since the PR was opened.
- `.codex-scratch/loc-trend.md` — per-round LOC trajectory + GROWING/STABLE/SHRINKING classification.
- `.codex-scratch/inferred-intent.md` — pre-fan-out inferred end-user-facing intent.
- `.codex-scratch/diff.patch` — the current diff under review.

**Your job:** Produce 4–6 sentences naming the structural reason this PR isn't converging. Don't restate individual findings — that's the aggregator's job. Your job is to name the *why* and force a structural choice via a closing question.

**Output contract — exactly this shape, no preamble, no headers other than the H2:**

```markdown
## Momentum

<Sentence 1-2: name the trajectory — "N rounds, M LOC growth, structural ask of <X> unmoved since round Y." Be specific: cite the recurring class (from prior-reviews.md), the LOC delta (from loc-trend.md), and the round count.>

<Sentence 3-4: name the cost of continuing the current approach. Cite Broken-Glass Test when applicable. Use the standard's phrasing — "adds complexity and makes PMF iteration harder," or "calcifies <N> branches that future refactors must preserve." If the trajectory shows the author is patching local cases instead of doing the structural fix, name that explicitly.>

<Sentence 5-6 (closing question): a single, sharp question to the author. Examples: "Are we ready to commit to <structural alternative>, or is continuing to patch leaves the better trade given X?" / "Will the recurring pattern keep showing up at every push, or is there a structural move that makes the class disappear?" Do not direct; ask.>

<If the structural ask has been unmoved across 3+ rounds, append: "Findings 2-N below are local. Do not address them in this PR until the structural direction is settled — additive responses now are how PRs balloon.">
```

**Self-heal:** If `prior-reviews.md` is empty, you should not have been invoked; abort with output `(no prior reviews — momentum specialist should not run on first review)` and exit. If `loc-trend.md` is empty or shows only the current round, output `(insufficient trajectory data — first re-review)` instead of speculating.

**Discipline:**
- Output is prose, not findings. No severity tags. No file:line citations (the aggregator's findings carry those). No bulleted findings list.
- 4–6 sentences total. No preamble, no commentary outside the contract.
- Close with a question. Always.
- Cite Broken-Glass Test by name when the trajectory is being driven by additive findings that don't match the operating point.
```

- [ ] **Step 9.2: Verify the file builds correctly via the existing prompt-build pipeline**

```bash
ls -la ~/Hacking/knightwatch-reviewer/prompts/momentum.md
grep -c '^## Momentum' ~/Hacking/knightwatch-reviewer/prompts/momentum.md
```

Expected: file exists, the H2 marker is present.

- [ ] **Step 9.3: Commit**

```bash
git add prompts/momentum.md
git commit -m "$(cat <<'EOF'
feat: prompts/momentum.md — re-review meta-finding specialist

New specialist that runs only on re-reviews. Outputs prose-only
trajectory analysis + closing question. Voice posture (questions over
prescriptions) baked into the output contract.

Read by the aggregator (Path 2 loop-breaker) as the structural callout
when LOC trajectory + Bug-Class-Recurrence signal a loop.

Wired into orchestrator in next task.
EOF
)"
```

---

## Task 10: Wire momentum specialist into the orchestrator

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh`
- Create: `~/Hacking/knightwatch-reviewer/lib/tests/momentum-wire-smoke.sh`

- [ ] **Step 10.1: Find where the critic is invoked today**

```bash
grep -n 'run-specialist.sh.*critic\|CRITIC_PROMPT' ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
```

- [ ] **Step 10.2: Add the momentum invocation immediately before the critic invocation**

Conditional: skip on first reviews (when `previous-review.md` is empty). Add this block:

```bash
# Momentum specialist — runs only on re-reviews. Outputs prose-only
# trajectory meta-finding for the aggregator's loop-breaker (Path 2).
# Skipped on first reviews; aggregator handles its absence gracefully.
if [ -s "$RUN_DIR/inputs/previous-review.md" ]; then
    log "$PR_ID: launching momentum specialist (re-review)..."
    MOMENTUM_PROMPT=$(build_specialist_prompt "$REVIEWER_PROMPTS_DIR/momentum.md" "$REPO_DIR" "$PR_ID" "$PR_TITLE" "$PR_URL")
    "$_LIB_DIR/run-specialist.sh" "momentum" "$REPO_DIR" "$MOMENTUM_PROMPT" "$RUN_DIR/agents/momentum"
else
    log "$PR_ID: skipping momentum specialist (first review)"
fi
```

(Verify `$REVIEWER_PROMPTS_DIR` and `build_specialist_prompt` are defined and in scope at that point — adapt variable names to existing orchestrator conventions.)

- [ ] **Step 10.3: Write a smoke test for the wiring**

Create `~/Hacking/knightwatch-reviewer/lib/tests/momentum-wire-smoke.sh`:

```bash
#!/bin/bash
# Smoke for momentum specialist orchestrator wiring.
#
# Two contracts:
#   1. previous-review.md non-empty → momentum specialist runs (artifact
#      directory created with prompt.txt + log.txt + output.md).
#   2. previous-review.md empty → momentum specialist is skipped (no
#      artifact directory, log line says "skipping momentum").

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Token-level fence — the orchestrator's momentum invocation block must
# reference momentum.md, gate on previous-review.md, and call run-specialist.sh.

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

echo "  asserting momentum.md invocation in review-one-pr.sh..."
assert_grep "review-one-pr.sh missing momentum.md reference" \
    "momentum.md" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting momentum gate on previous-review.md..."
assert_grep "review-one-pr.sh missing previous-review.md gate around momentum" \
    'previous-review.md' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting momentum dispatch via run-specialist.sh..."
assert_grep "review-one-pr.sh missing run-specialist.sh dispatch for momentum" \
    'run-specialist.sh" "momentum"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  PASS"
```

- [ ] **Step 10.4: Wire smoke into justfile + run**

Edit `justfile` to add:

```
    echo ""
    echo "=== momentum-wire smoke ==="
    bash lib/tests/momentum-wire-smoke.sh
```

Run `just test`:

```bash
cd ~/Hacking/knightwatch-reviewer
just test 2>&1 | tail -10
```

Expected: all smokes pass, including `momentum-wire`.

- [ ] **Step 10.5: Commit**

```bash
git add lib/review-one-pr.sh lib/tests/momentum-wire-smoke.sh justfile
git commit -m "$(cat <<'EOF'
feat: wire momentum specialist into orchestrator

Run alongside the critic (after specialists fan out, before aggregator).
Conditional: skip on first reviews when previous-review.md is empty —
no trajectory to evaluate.

Output written to .codex-scratch/agents/momentum/output.md, consumed
by aggregator's loop-breaker mode (Path 2).

Smoke fences the wiring at token level (no behavior assertion — codex
invocation requires a real model + fixtures).
EOF
)"
```

---

## Task 11: End-to-end verification

- [ ] **Step 11.1: Run full `just test`**

```bash
cd ~/Hacking/knightwatch-reviewer
just test 2>&1 | tee /tmp/just-test-output
```

Expected: every smoke test passes. If any fail, debug and fix before proceeding.

- [ ] **Step 11.2: Manual verification — exercise momentum specialist on a synthetic re-review**

Pick a PR from `~/.pr-reviewer/runs/` that has 4+ rounds (e.g. `cncorp_plow__534`). Manually replay one round through the orchestrator with the new code:

```bash
# Inspect what the orchestrator would do for a re-review of plow#534
ls ~/.pr-reviewer/runs/cncorp_plow__534__* | head -3
# If you have a tracked-repo workdir, you can dry-run the relevant
# orchestrator section. Otherwise, this is an observational step:
# wait for the next live re-review and watch the run dir for
# agents/momentum/output.md.
```

(This step is observation-only; the next live re-review will be the real validation.)

- [ ] **Step 11.3: Verify Both repos are clean**

```bash
cd ~/Hacking/vibe-engineering && git status -s
cd ~/Hacking/knightwatch-reviewer && git status -s
```

Expected: clean working tree in both, with feature branches ahead of main by N commits.

- [ ] **Step 11.4: Push both branches and open PRs**

```bash
cd ~/Hacking/vibe-engineering
git push -u origin feat/broken-glass-test
gh pr create --title "feat: § Broken-Glass Test + voice-posture mistakes" --body "$(cat <<'EOF'
## Summary
- New § Broken-Glass Test in CODING_STANDARDS.md (Butterfield quote +
  voice posture + question template + worked-example reframings).
- Two new entries in COMMENT_REVIEW_MISTAKES.md (Pre-PMF remedies +
  voice-posture calibration).

Required by: cncorp/knightwatch-reviewer feat/broken-glass-reviewer.

## Test plan
- [ ] CI green on this repo
- [ ] knightwatch-reviewer side merges separately and produces
      question-shaped findings on the next re-review.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

```bash
cd ~/Hacking/knightwatch-reviewer
git push -u origin feat/broken-glass-reviewer
gh pr create --title "feat: Broken-Glass Reviewer (loop-breaker + voice posture)" --body "$(cat <<'EOF'
## Summary
- New `prompts/momentum.md` specialist (re-reviews only) — prose-only
  trajectory meta-finding ending in a question.
- Critic gains REFRAME-AS-QUESTION status + Pre-PMF lens.
- Aggregator gains voice posture + structured Open Questions + re-review
  loop-breaker mode (Path 2).
- New `.knightwatch/review-priority.md` per-repo file (default content
  embedded in orchestrator for cold-start operators).
- New `compute_loc_trend()` + `.codex-scratch/loc-trend.md` scratch input.

Spec: `docs/specs/2026-05-01-broken-glass-reviewer-design.md`.
Depends on: srosro/vibe-engineering feat/broken-glass-test.

## Test plan
- [ ] `just test` green
- [ ] All new smoke tests added to justfile
- [ ] First live re-review on a tracked PR produces a momentum specialist
      output and (if the trigger fires) the structural callout
- [ ] First live first-review on a tracked PR does NOT invoke momentum

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 11.5: Post-merge live observation**

After both PRs merge, watch the next 1–2 active re-reviews on `cncorp/plow`:

- Confirm the momentum specialist produces a prose section ending in a question.
- Confirm the structural callout appears at the top when LOC trajectory + Bug-Class-Recurrence trigger fires.
- Confirm REFRAME-AS-QUESTION items land in Open Questions.
- **Critically:** confirm a real high-confidence bug is *still* declarative — voice posture isn't over-applied.

If the voice posture is being over-applied (real bugs framed as questions), the threshold language in Change A needs to be sharper. File a follow-up.

If the loop-breaker isn't firing on PRs that obviously qualify, the trigger conditions in Change G may need tuning (e.g. the LOC ratio threshold).

A two-week follow-up is appropriate.

---

## Self-Review

After completing all tasks, run this checklist:

- [ ] **Spec coverage.** Cross-reference each Change A–H from the spec against the tasks. All 8 changes implemented? Verify by re-reading § Architecture in the spec.
- [ ] **Smoke coverage.** Every new prompt token + script function has a token-level or behavior-level smoke. The 04-29 spec discipline (no content pinning) is preserved.
- [ ] **No placeholders.** No "TBD", no "implement X later," no `<TODO>` markers in any committed file. Every file Edit and Create includes the full content.
- [ ] **Type/name consistency.** `compute_loc_trend` referenced consistently in tasks 4, 6, 8. `REFRAME-AS-QUESTION` token spelled identically in tasks 7, 8, smoke tests, and aggregator references. `review-priority.md` filename spelled identically in tasks 3, 5, 6, 9.
- [ ] **Standards file path.** Every reference to `CODING_STANDARDS.md` resolves to the symlink at `~/.claude/CODING_STANDARDS.md` → `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md`. Verified by `Step 1.4`.
- [ ] **Operating-point default.** The default `review-priority.md` content embedded in `lib/review-one-pr.sh` (Task 5) is structurally compatible with the per-repo file in Task 3. The reviewer should produce the same behavior whether the per-repo file is absent (default fires) or present (file content used).
