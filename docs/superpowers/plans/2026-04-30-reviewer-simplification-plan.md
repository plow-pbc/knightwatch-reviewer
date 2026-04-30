# Reviewer Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `lib/diff-scope.sh` machinery with a single `gh pr diff` default + clean-incremental optimization, and drop the cross-repo auth-gate in favor of the existing `SOURCE_PATHS` whitelist. ~330 lines net deleted.

**Architecture:** Section 1 simplifies `lib/search-roots.sh` to two statuses (`included` | `missing`) — `SOURCE_PATHS` in `repos.conf` is the trust boundary. Section 2 replaces all the `build_pr_diff` / `build_incremental_diff` / `compute_authored_files` machinery with: one `gh pr diff` call up front, plus a small `is_clean_incremental_available` predicate that decides whether to override KID_INPUT_DIFF with a local `git diff KNOWN_SHA..HEAD`. Both checks (`merge-base --is-ancestor` AND `log --merges` empty) must hold; otherwise fall back with a deterministic ⚠️ warning at the top of the review via the existing `SKIPPED_CHECKS` array.

**Tech Stack:** bash, git, gh CLI, smoke-test framework in `lib/tests/`. No new dependencies.

**File structure (final state):**
- **Created:** `lib/diff-build.sh` (just `is_clean_incremental_available`), `lib/tests/diff-build-smoke.sh`
- **Deleted:** `lib/diff-scope.sh`, `lib/tests/diff-scope-smoke.sh`
- **Modified:** `lib/search-roots.sh` (→ ~30 lines), `lib/tests/search-roots-smoke.sh` (→ 2 scenarios), `lib/review-one-pr.sh` (replace diff-build block + file-history loop, source new helper, drop old, add SKIPPED_CHECKS line + TODOs), `prompts/common-header.md` (+1 paragraph), `prompts/consumers.md` + `prompts/dead-code-search.md` (replace search-roots format paragraphs), `justfile` (rename smoke entry), `repos.conf` (TODO note about /.knightwatch/ direction)

**Repo conventions to respect:**
- Pre-merge gate is `just test`. Every helper file has a corresponding `lib/tests/<helper>-smoke.sh` and the smoke is added to the `justfile`.
- Smoke tests `set -euo pipefail`, use `mktemp -d`, trap-cleanup, and stub external commands via `PATH` injection when needed.
- Production runs from `~/Hacking/knightwatch-reviewer/` (symlinked into `~/.pr-reviewer/`); this repo (`knightwatch-reviewer3`) is the dev checkout. **All work happens here**, lands as a continuation of PR #28 on `srosro/knightwatch-reviewer`. The current branch is `fix/merge-attribution-and-path-leak`.

---

### Task 1: Update `search-roots-smoke.sh` to assert new whitelist-only contract

**Files:**
- Modify: `lib/tests/search-roots-smoke.sh` (rewrite — drop 5 scenarios, keep 2 with new format)

The new contract: `stage_search_roots` takes one arg (`<repo>`), no longer needs `<pr_author>`, no longer makes any `gh api` calls. Two statuses: `included .siblings/<slug>` (whitelisted in `SOURCE_PATHS` AND on-disk) | `missing` (whitelisted BUT absent on-disk).

- [ ] **Step 1: Verify clean working tree + we're on the PR branch**

```bash
cd /home/odio/Hacking/knightwatch-reviewer3
git status
git branch --show-current
```

Expected: `working tree clean` (untracked `.claude/` and `docs/superpowers/` are session artifacts and OK), branch = `fix/merge-attribution-and-path-leak`.

- [ ] **Step 2: Write the failing smoke**

Replace the entire contents of `lib/tests/search-roots-smoke.sh` with:

```bash
#!/bin/bash
# Smoke for lib/search-roots.sh — whitelist-only contract.
#
# Whitelist = SOURCE_PATHS in repos.conf. If a sibling slug has an
# entry there, the operator has affirmed it's safe to reference in
# this base repo's PR comments. No runtime auth check, no per-sibling
# permission lookup. Two statuses:
#   included .siblings/<slug>   — slug in SOURCE_PATHS AND its
#                                  checkout exists on disk
#   missing                     — slug in SOURCE_PATHS BUT its
#                                  checkout absent on disk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t search-roots-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Provide checkouts for two of three siblings; the third is intentionally absent.
mkdir -p "$TMPDIR/repos/foo" "$TMPDIR/repos/bar"
# (sibling "qux" has no directory — drives the `missing` path.)

REPOS=("acme/self" "acme/foo" "acme/bar" "acme/qux")
declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/repos/self"
    ["acme/foo"]="$TMPDIR/repos/foo"
    ["acme/bar"]="$TMPDIR/repos/bar"
    ["acme/qux"]="$TMPDIR/repos/qux"
)

. "$PROJECT_ROOT/lib/search-roots.sh"

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $label"
        echo "  did not find: $needle"
        echo "  in: $(printf '%s' "$haystack" | head -c 400)"
        exit 1
    fi
}

# --- scenario 1: all whitelisted siblings have checkouts on disk -----
echo "  scenario 1: all whitelisted siblings present..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
OUT=$(stage_search_roots "acme/self")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 1: header full" "# coverage: full" "$OUT"
assert_contains "scenario 1: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 1: bar included" "acme/bar included .siblings/acme/bar" "$OUT"

# --- scenario 2: one whitelisted sibling missing on disk -------------
echo "  scenario 2: one whitelisted sibling missing on disk..."
OUT=$(stage_search_roots "acme/self")
assert_contains "scenario 2: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 2: included=2" "included=2" "$OUT"
assert_contains "scenario 2: missing=1" "missing=1" "$OUT"
assert_contains "scenario 2: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 2: bar included" "acme/bar included .siblings/acme/bar" "$OUT"
assert_contains "scenario 2: qux missing" "acme/qux missing" "$OUT"

echo "  PASS (2 scenarios: full-coverage, missing-on-disk)"
```

- [ ] **Step 3: Run the smoke; confirm it fails**

```bash
bash lib/tests/search-roots-smoke.sh
```

Expected: failure on scenario 1's `acme/foo included .siblings/acme/foo` assertion (current impl still does the `gh api` permission check, which the smoke no longer stubs, so the call fails and the gate falls through to `same-repo-only` instead).

- [ ] **Step 4: No commit yet** — Task 2 implements the simplification that makes this smoke pass.

---

### Task 2: Rewrite `lib/search-roots.sh` (whitelist-only); update caller signature

**Files:**
- Modify: `lib/search-roots.sh` (rewrite — drop `gh api` blocks, single arg)
- Modify: `lib/review-one-pr.sh` (caller — drop `$PR_AUTHOR` second arg from `stage_search_roots` call)

- [ ] **Step 1: Replace `lib/search-roots.sh` contents**

Replace the entire contents of `lib/search-roots.sh` with:

```bash
#!/bin/bash
# Coverage-state seam for cross-repo grep — whitelist-only.
#
# stage_search_roots is the single worker-owned helper that classifies
# every sibling repo from the SOURCE_PATHS whitelist into one of two
# explicit statuses, builds the .codex-scratch/search-roots.md content,
# and returns it on stdout. The dead-code-search and consumers prompts
# read this content as the sole source of truth for "which siblings
# did we cover, and why?". No silent coverage loss, no per-prompt
# rediscovery.
#
# Trust model: SOURCE_PATHS in repos.conf IS the whitelist. If the
# operator listed cncorp/plow-content there, that's affirmative
# consent to reference plow-content code in any PR review on a base
# repo whose entry includes it. No runtime gh-api permission check —
# the operator decides out-of-band, in repos.conf, with full context.
#
# Per-sibling status:
#   included      — slug in SOURCE_PATHS AND its checkout exists on
#                   disk. The .siblings/<slug> path is the workdir-
#                   relative symlink materialized by sibling-symlinks.sh
#                   after this helper runs.
#   missing       — slug in SOURCE_PATHS BUT its checkout absent on
#                   this host (operator-config gap, not a security
#                   boundary).
#
# Output format:
#   # coverage: full | partial | same-repo-only
#   <repo-slug> included .siblings/<repo-slug>
#   <repo-slug> missing
#   ...
#
# coverage: full           — every sibling with a SOURCE_PATHS entry has its checkout on disk
# coverage: same-repo-only — zero whitelisted siblings, OR none have their checkouts on disk
# coverage: partial        — at least one included AND at least one missing

stage_search_roots() {
    local repo="$1"
    local sibling_repo sibling_path
    local body=""
    local included=0 missing=0

    for sibling_repo in "${REPOS[@]}"; do
        [ "$sibling_repo" = "$repo" ] && continue
        sibling_path="${SOURCE_PATHS[$sibling_repo]:-}"
        # No SOURCE_PATHS entry = sibling not whitelisted at all (not a
        # coverage gap, just not configured). Skip silently.
        [ -z "$sibling_path" ] && continue
        if [ ! -d "$sibling_path" ]; then
            body+="$sibling_repo missing"$'\n'
            missing=$((missing + 1))
            continue
        fi
        body+="$sibling_repo included .siblings/$sibling_repo"$'\n'
        included=$((included + 1))
    done

    local total=$((included + missing))
    local header
    if [ "$total" -eq 0 ]; then
        header="# coverage: same-repo-only — no sibling SOURCE_PATHS in scope"
    elif [ "$included" -eq "$total" ]; then
        header="# coverage: full"
    elif [ "$included" -eq 0 ]; then
        header="# coverage: same-repo-only — included=0 missing=$missing"
    else
        header="# coverage: partial — included=$included missing=$missing"
    fi
    printf '%s\n%s' "$header" "$body"
}
```

- [ ] **Step 2: Update the single caller in `lib/review-one-pr.sh`**

Find the call site:

```bash
grep -n 'stage_search_roots' lib/review-one-pr.sh
```

Expected: one match at the site that reads roughly:

```bash
SEARCH_ROOTS=$(stage_search_roots "$REPO" "$PR_AUTHOR")
```

Replace with the single-arg form:

```bash
SEARCH_ROOTS=$(stage_search_roots "$REPO")
```

- [ ] **Step 3: Run smoke; confirm it passes**

```bash
bash lib/tests/search-roots-smoke.sh
```

Expected: `PASS (2 scenarios: full-coverage, missing-on-disk)`.

- [ ] **Step 4: bash -n + just test**

```bash
bash -n lib/search-roots.sh && bash -n lib/review-one-pr.sh && echo syntax-ok
just test
```

Expected: clean syntax; `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/search-roots.sh lib/tests/search-roots-smoke.sh lib/review-one-pr.sh
git commit -m "$(cat <<'EOF'
search-roots: drop auth-gate, treat SOURCE_PATHS as the whitelist

The bot's recurring "auth-based not visibility-based" finding had a
real point: collaborator-permission checks were the wrong primitive
for "what's safe to reference in a public PR comment." The right
primitive was already there — SOURCE_PATHS in repos.conf, the
operator's affirmative whitelist of siblings to expose for cross-repo
grep on this base repo.

Drop the gh-api permission checks (per-sibling AND base-repo). 4
statuses → 2: included (whitelisted + on-disk) | missing (whitelisted
but absent on disk). No more excluded/lookup-error — the gates that
produced them are gone.

stage_search_roots signature drops $pr_author (no longer used).
Caller in review-one-pr.sh updated. Smoke shrinks from 7 scenarios
to 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Update prompts for new search-roots format

**Files:**
- Modify: `prompts/consumers.md`
- Modify: `prompts/dead-code-search.md`

The "Search-roots coverage" / "search-roots.md format" paragraphs in both prompts described the old 4-status world (excluded, lookup-error). Replace with the simpler 2-status reality. The "downgrade to uncertain when sibling has non-included status" guidance simplifies — `missing` is still a coverage gap (the helper isn't on disk so we can't grep it), but there's no longer any concept of "excluded by trust" or "lookup failed."

- [ ] **Step 1: Update `prompts/consumers.md`**

Find the paragraph that begins with `**Search-roots coverage.**`:

```bash
grep -n '^\*\*Search-roots coverage' prompts/consumers.md
```

Replace that entire paragraph (one line in the file) with:

```
**Search-roots coverage.** First line of `.codex-scratch/search-roots.md` is a `# coverage:` marker. Each subsequent line classifies one whitelisted sibling: `<repo-slug> included .siblings/<repo-slug>` (grep this workdir-relative path) or `<repo-slug> missing` (operator-config gap — checkout absent on this host; treat as a coverage gap for any modified public symbol that plausibly has consumers there). When ANY sibling is `missing` AND a modified public symbol plausibly has consumers in that sibling's domain, downgrade the verdict for that symbol from `dead`/`stale-caller`/`clean` to `uncertain` and name the gap in the finding. Be aware of dynamic dispatch — a zero-grep result is a signal, not proof.
```

Then find the bullet that mentions grepping the `included` siblings:

```bash
grep -n 'For each symbol, ` *grep' prompts/consumers.md
```

Update it to clarify the new path form (this bullet currently mentions `.siblings/cncorp/plow-content` — the example is fine, just confirm the surrounding text reads right):

(No edit needed if the bullet already says "The `included` value is now a workdir-relative path (e.g. `.siblings/cncorp/plow-content`); grep against that." Confirm it does, and move on.)

- [ ] **Step 2: Update `prompts/dead-code-search.md`**

Find the bullet list under `**search-roots.md format.**`:

```bash
grep -n '^- `<repo-slug>' prompts/dead-code-search.md
```

Expected: 4 bullets currently (included, excluded, missing, lookup-error). Replace the entire bullet block with just two bullets:

```
- `<repo-slug> included .siblings/<repo-slug>` — whitelisted in SOURCE_PATHS AND its checkout exists on this host; grep this workdir-relative path. The `.siblings/` directory is a tree of symlinks pointing at the operator's local checkouts of each whitelisted sibling repo.
- `<repo-slug> missing` — whitelisted in SOURCE_PATHS BUT its checkout is absent on this host (operator-config gap). Treat as a coverage gap for any modified public symbol that plausibly has consumers there.
```

Find the paragraph beginning `**When ANY sibling has a non-`included` status**`:

```bash
grep -n '^\*\*When ANY sibling has a non-' prompts/dead-code-search.md
```

Replace with the simpler version:

```
**When ANY sibling is `missing`** (i.e. coverage is `partial` or `same-repo-only`) AND a modified public symbol plausibly has consumers in that sibling's domain, downgrade the verdict for that symbol from `dead`/`stale-caller`/`clean` to `uncertain` and name the gap in the evidence (e.g. "verdict uncertain — `cncorp/plow-content` checkout missing on host"). This applies equally to all three verdict classes: a `clean` verdict from same-repo grep is just as misleading as a `stale-caller` one when the relevant sibling wasn't checked.
```

- [ ] **Step 3: just test**

```bash
just test
```

Expected: `all checks passed` (prompts are markdown, no smoke covers them; verifying the suite still runs).

- [ ] **Step 4: Commit**

```bash
git add prompts/consumers.md prompts/dead-code-search.md
git commit -m "$(cat <<'EOF'
prompts: 2-status search-roots format (included | missing)

Pairs with the search-roots.sh simplification. The old 4-status
guidance described excluded / lookup-error states that no longer
exist — the gh-api gates that produced them are gone. The remaining
guidance about coverage gaps still applies, just only for the
`missing` status (whitelisted sibling absent on disk).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Write `diff-build-smoke.sh` (TDD failing test)

**Files:**
- Create: `lib/tests/diff-build-smoke.sh`

The new helper `is_clean_incremental_available` is a small predicate. The smoke exercises the four conditions that determine its return code: clean (ancestor + no merges), merges-in-range, rebased-away, nonexistent SHA.

- [ ] **Step 1: Write the smoke**

Create `lib/tests/diff-build-smoke.sh`:

```bash
#!/bin/bash
# Smoke for lib/diff-build.sh::is_clean_incremental_available.
#
# Predicate: returns success (exit 0) iff
#   (a) prior reviewed SHA is still an ancestor of HEAD (no force-push
#       evicted it), AND
#   (b) no merge commits exist in known_sha..HEAD (no merge-from-main
#       between then and now to pollute attribution).
# Any other condition → exit 1, caller falls back to full PR diff
# with a deterministic warning at the top of the review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPDIR=$(mktemp -d -t diff-build-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

. "$SCRIPT_DIR/diff-build.sh"

REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

echo a > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init

git -C "$REPO" remote add origin "$REPO/.git"
git -C "$REPO" fetch -q origin main

git -C "$REPO" checkout -qb feature
echo f > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -qm "B1"
PRIOR=$(git -C "$REPO" rev-parse HEAD)

# --- scenario 1: SHA is ancestor, no merges in range -----------------
echo "  scenario 1: clean incremental (ancestor + no merges)..."
echo f2 > "$REPO/feature2.txt"
git -C "$REPO" add feature2.txt
git -C "$REPO" commit -qm "B2"
if ! is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 1: should be clean (PRIOR is ancestor, no merges in range)"
    exit 1
fi

# --- scenario 2: SHA is ancestor, merge commit in range --------------
echo "  scenario 2: merge commit in range -> not clean..."
git -C "$REPO" checkout -q main
echo m > "$REPO/main-only.txt"
git -C "$REPO" add main-only.txt
git -C "$REPO" commit -qm "M1"
git -C "$REPO" fetch -q origin main
git -C "$REPO" checkout -q feature
git -C "$REPO" merge --no-ff -q -m "merge main" origin/main
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 2: merge commit in range should fail clean check"
    exit 1
fi

# --- scenario 3: rebased-away SHA (not ancestor of HEAD) -------------
# Capture HEAD and reset to a SHA before PRIOR; then PRIOR's branch
# point is no longer an ancestor of (the new) HEAD. Use checkout -B
# to a fresh-rooted history to simulate a force-push.
echo "  scenario 3: rebased-away SHA -> not clean..."
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qB feature main
echo orphaned > "$REPO/orphaned.txt"
git -C "$REPO" add orphaned.txt
git -C "$REPO" commit -qm "post-rebase HEAD"
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 3: orphaned SHA should fail clean check (PRIOR not ancestor of new HEAD)"
    exit 1
fi

# --- scenario 4: SHA doesn't exist at all ----------------------------
echo "  scenario 4: nonexistent SHA -> not clean..."
if is_clean_incremental_available "$REPO" "0000000000000000000000000000000000000000"; then
    echo "FAIL scenario 4: nonexistent SHA should fail clean check"
    exit 1
fi

echo "  PASS (4 scenarios: clean, merges-in-range, rebased-away, nonexistent)"
```

- [ ] **Step 2: Run the smoke; confirm it fails**

```bash
bash lib/tests/diff-build-smoke.sh
```

Expected: failure on the source line — `lib/diff-build.sh: No such file or directory`. Task 5 creates that file.

- [ ] **Step 3: No commit yet** — TDD intermediate.

---

### Task 5: Create `lib/diff-build.sh`; add smoke to `justfile`

**Files:**
- Create: `lib/diff-build.sh`
- Modify: `justfile`

- [ ] **Step 1: Create `lib/diff-build.sh`**

Write `lib/diff-build.sh`:

```bash
#!/bin/bash
# Diff-build helper for the reviewer worker.
#
# is_clean_incremental_available <repo_dir> <known_sha>
#   exit 0 if a local incremental diff (`git diff $known_sha..HEAD`)
#   would faithfully represent "what's new on the branch since
#   $known_sha":
#     (a) $known_sha is still an ancestor of HEAD — no force-push or
#         rebase has evicted it from the branch's current history
#     (b) no merge commits exist in $known_sha..HEAD — no merge-from-
#         main commits to pollute the incremental scope (the bot's
#         round 2 same-file leak finding)
#   exit 1 otherwise — caller falls back to the full PR diff with a
#   deterministic warning at the top of the review.
#
# This is the only helper from the deleted lib/diff-scope.sh that
# survived. The rest of that machinery — build_pr_diff,
# build_incremental_diff, compute_authored_files, has_traceable_history,
# DIFF_EXCLUDES tracking — was layers of trying to reinvent what
# `gh pr diff` (server-side three-dot) already does correctly. The
# worker now defaults to gh pr diff and only takes the local
# incremental optimization when this predicate confirms it's safe.
is_clean_incremental_available() {
    local repo_dir="$1" known_sha="$2"
    git -C "$repo_dir" merge-base --is-ancestor "$known_sha" HEAD 2>/dev/null \
        && [ -z "$(git -C "$repo_dir" log --merges --pretty=format:%H "$known_sha..HEAD" 2>/dev/null)" ]
}
```

- [ ] **Step 2: Run the smoke; confirm it passes**

```bash
bash lib/tests/diff-build-smoke.sh
```

Expected: `PASS (4 scenarios: clean, merges-in-range, rebased-away, nonexistent)`.

- [ ] **Step 3: Add the new smoke to `justfile`** — find the `=== diff-scope smoke test ===` block:

```bash
grep -n 'diff-scope smoke test' justfile
```

Expected: one block. Replace that entire block (3 lines) with:

```
    echo ""
    echo "=== diff-build smoke test ==="
    bash lib/tests/diff-build-smoke.sh
```

(Renaming smoke entry from "diff-scope" to "diff-build". The old smoke file `lib/tests/diff-scope-smoke.sh` is deleted in Task 7; until then, we keep the file but stop running it from justfile. That's intentional — Task 6 stops sourcing diff-scope.sh, Task 7 deletes the now-orphaned files.)

- [ ] **Step 4: Run full suite**

```bash
just test
```

Expected: `all checks passed`. The output should now show `=== diff-build smoke test ===` instead of `=== diff-scope smoke test ===`.

- [ ] **Step 5: Commit**

```bash
git add lib/diff-build.sh lib/tests/diff-build-smoke.sh justfile
git commit -m "$(cat <<'EOF'
diff-build: add is_clean_incremental_available predicate

The only piece worth keeping from the deleted lib/diff-scope.sh
machinery: a small predicate that decides whether a local incremental
diff would faithfully represent "what's new on the branch since the
prior reviewed SHA." Two conditions must hold:

  (a) prior_sha is still an ancestor of HEAD (no force-push evicted it)
  (b) no merge commits exist in prior_sha..HEAD (no merge-from-main
      to pollute attribution)

Either failing → caller falls back to gh pr diff (the canonical
server-side full-PR view) with a deterministic warning at the top of
the review.

Smoke covers all 4 cases: clean, merges-in-range, rebased-away (force-
push), nonexistent SHA. The next commit wires this into review-one-pr.sh
in place of the build_pr_diff / build_incremental_diff machinery.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Replace diff-build block + file-history loop in `lib/review-one-pr.sh`

**Files:**
- Modify: `lib/review-one-pr.sh` (replace `~50` lines with `~15` for the diff-build block, replace the file-history input source, swap `lib/diff-scope.sh` source line for `lib/diff-build.sh`)

This is the load-bearing change. After this task, the worker no longer references `lib/diff-scope.sh` at runtime; the file is orphaned but not yet deleted (Task 7 deletes it). Smoke for `diff-scope-smoke.sh` is also orphaned (no longer in justfile after Task 5; the file still exists until Task 7).

- [ ] **Step 1: Swap the source line**

Find the diff-scope source:

```bash
grep -n 'diff-scope.sh' lib/review-one-pr.sh
```

Expected: one match (the `. "$_LIB_DIR/diff-scope.sh"` line, with its preceding comment). Replace the comment + source line with:

```bash
# --- diff-build helper (clean-incremental-vs-fallback predicate) ---
. "$_LIB_DIR/diff-build.sh"
```

- [ ] **Step 2: Replace the diff-build block**

Find the start of the diff-build block:

```bash
grep -n '^# build_pr_diff produces' lib/review-one-pr.sh
```

Then locate the END of the block — it ends with `fi` after the `else USED_FALLBACK=true` branch. The block today runs from the `# build_pr_diff produces ...` comment down through the closing `fi` of the outer `if [ -z "$KNOWN_SHA" ]` (about 70 lines). Read it to confirm extent:

```bash
sed -n '<start_line>,<end_line>p' lib/review-one-pr.sh | tail -20
```

Replace the entire block (from `# build_pr_diff produces ...` through the closing `fi` of the outer if-else, inclusive) with:

```bash
# Single gh pr diff call up front — the canonical "what's in this PR"
# view, same one humans see on the PR's "Files changed" tab. Used for
# both KID_INPUT_DIFF (the diff specialists review) by default, and
# FULL_PR_DIFF (the aggregator's "verify prior findings against
# current state" reference) always.
FULL_PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
KID_INPUT_DIFF="$FULL_PR_DIFF"
DIFF_FALLBACK=false

KNOWN_SHA=$(state_get "$PR_ID" "sha")
PREV_BODY=""
PREV_APPROVED=""

# Optimization: use a local incremental diff for KID_INPUT_DIFF ONLY
# when (a) the prior reviewed SHA is still on the branch's history AND
# (b) no merge commits exist in the incremental range. Any other
# condition (rebase/force-push, OR branch merged main between then and
# now) would leak merge-from-main content or misframe an off-branch
# SHA — leave KID_INPUT_DIFF as the full PR diff and let SKIPPED_CHECKS
# emit a deterministic ⚠️ warning at the top of the review.
if [ -n "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" != "true" ]; then
    PREV_BODY=$(state_get "$PR_ID" "body")
    PREV_APPROVED=$(state_get "$PR_ID" "approved")
    if is_clean_incremental_available "$REPO_DIR" "$KNOWN_SHA"; then
        KID_INPUT_DIFF=$(git -C "$REPO_DIR" diff "$KNOWN_SHA..HEAD")
        log "$PR_ID: clean incremental diff since ${KNOWN_SHA:0:7}"
    else
        DIFF_FALLBACK=true
        log "$PR_ID: incremental not clean (rebased or merged-from-main since ${KNOWN_SHA:0:7}); using full PR diff"
    fi
fi
```

- [ ] **Step 3: Verify the empty-diff abort still works**

The existing empty-diff abort (`if [ -z "$KID_INPUT_DIFF" ]; then ... aborting ...`) lives just after the diff-build block. Confirm it's still in place after the replacement:

```bash
grep -n 'empty diff — gh pr diff' lib/review-one-pr.sh
```

Expected: one match. The abort message currently mentions "gh pr diff / git diff returned nothing"; that's still accurate under the new design.

- [ ] **Step 4: Replace the file-history loop's input source**

Find the file-history block:

```bash
grep -n 'compute_authored_files' lib/review-one-pr.sh
```

Expected: one match in the file-history block. Read 6 lines of context to find the `done < <(...)` line. Replace the current `done < <(compute_authored_files ...)` line with the diff-parse:

```bash
done < <(printf '%s' "$KID_INPUT_DIFF" \
    | grep -E '^diff --git a/' \
    | sed -E 's|^diff --git a/(.*) b/.*$|\1|' \
    | sort -u | head -30)
```

Also remove the `DIFF_EXCLUDES` setup block earlier in the file (since file-history no longer uses it):

```bash
grep -n 'DIFF_EXCLUDES' lib/review-one-pr.sh
```

Expected: matches at the comment block defining `DIFF_EXCLUDES=("origin/${DEFAULT_BRANCH}")` and the line that appends `KNOWN_SHA` in the incremental branch. Both are now unused. Delete the comment-block + the array setup line + the conditional append.

- [ ] **Step 5: bash -n + just test**

```bash
bash -n lib/review-one-pr.sh && echo syntax-ok
just test
```

Expected: clean syntax, `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "$(cat <<'EOF'
review-one-pr: use gh pr diff default + clean-incremental optimization

Replaces the entire build_pr_diff / build_incremental_diff /
DIFF_EXCLUDES machinery with the simpler design from the spec:

  1. Single gh pr diff call up front. KID_INPUT_DIFF = FULL_PR_DIFF
     by default. Both populated from the same canonical server-side
     three-dot view that humans see on the PR's "Files changed" tab.

  2. Incremental optimization: override KID_INPUT_DIFF with local
     `git diff KNOWN_SHA..HEAD` only when is_clean_incremental_available
     returns true (prior SHA is still on the branch's history AND no
     merge commits in range). Any other condition leaves KID_INPUT_DIFF
     as the full PR diff and sets DIFF_FALLBACK=true.

  3. File-history.md is now derived by parsing `^diff --git a/` headers
     out of $KID_INPUT_DIFF directly. Same scope as the diff specialists
     see, regardless of full-PR or incremental. Replaces the
     compute_authored_files invocation that depended on DIFF_EXCLUDES.

This commit removes references to lib/diff-scope.sh; the file itself
is deleted in the next commit (kept here so review-one-pr.sh and the
diff-scope deletion land as separate, easily-reverted units).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Delete orphaned `lib/diff-scope.sh` and its smoke

**Files:**
- Delete: `lib/diff-scope.sh`
- Delete: `lib/tests/diff-scope-smoke.sh`

After Task 6, both files are unreferenced. The justfile entry was already updated in Task 5. This task just removes the dead files.

- [ ] **Step 1: Confirm nothing references the files**

```bash
grep -rn 'diff-scope\|compute_authored_files\|build_authored_diff\|has_traceable_history\|build_pr_diff\|build_incremental_diff\|compute_pr_authored_files' lib/ prompts/ justfile docs/ 2>/dev/null | grep -v '^docs/' | grep -v 'docs/superpowers' || echo "no references"
```

Expected: `no references`. (The spec and plan in `docs/superpowers/` may mention the deleted symbols historically; that's fine.)

- [ ] **Step 2: Delete the files**

```bash
git rm lib/diff-scope.sh lib/tests/diff-scope-smoke.sh
```

- [ ] **Step 3: just test**

```bash
just test
```

Expected: `all checks passed`. The diff-scope smoke entry was already removed from justfile in Task 5.

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
diff-scope: delete orphaned helper + smoke

After review-one-pr.sh stopped sourcing it, lib/diff-scope.sh and its
smoke had no remaining references. Net deletion: ~225 lines.

The is_clean_incremental_available predicate (the only piece of
diff-scope.sh that survived as a real abstraction) lives in
lib/diff-build.sh, with its own focused smoke.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Add deterministic ⚠️ warning + attribution prompt + TODO notes

**Files:**
- Modify: `lib/review-one-pr.sh` (one SKIPPED_CHECKS line + one TODO comment)
- Modify: `prompts/common-header.md` (+1 paragraph)
- Modify: `repos.conf` (TODO note about `/.knightwatch/` direction)

- [ ] **Step 1: Add the SKIPPED_CHECKS warning line**

Find the existing `SKIPPED_CHECKS` setup:

```bash
grep -n 'SKIPPED_CHECKS' lib/review-one-pr.sh
```

Expected: declarations like:

```bash
SKIPPED_CHECKS=()
[ "$TESTS_RAN" = "false" ] && SKIPPED_CHECKS+=("🧪 Tests")
[ "$KID_RAN" = "false" ] && SKIPPED_CHECKS+=("🔍 Prior-art (KID)")
```

Add one line right after the `KID` line:

```bash
[ "$DIFF_FALLBACK" = "true" ] && SKIPPED_CHECKS+=("⚠️ Clean incremental unavailable; reviewed full PR diff")
```

- [ ] **Step 2: Add the REVIEW_NOTES rename TODO comment**

Just above the `SKIPPED_CHECKS=()` declaration line, add:

```bash
# TODO(future): rename SKIPPED_CHECKS -> REVIEW_NOTES — the array now
# carries warnings (e.g. "Clean incremental unavailable"), not just
# skipped checks. The signature of prepend_review_header should also
# absorb review_scope and stale_head as additional notes in the same
# array. Mechanical refactor; lands cleaner as its own focused PR.
```

- [ ] **Step 3: Add the attribution paragraph in `prompts/common-header.md`**

Find the bullet describing `.codex-scratch/diff.patch`:

```bash
grep -n 'codex-scratch/diff.patch' prompts/common-header.md
```

Expected: one match. Right after that bullet (inserting between it and the next bullet), add a new paragraph (NOT a bullet — it's a free-standing paragraph that gives attribution guidance):

```

**Attribution for merged-in content.** `diff.patch` is what GitHub considers part of this PR — including any content the branch pulled in via `git merge origin/<base>` commits. If you flag a finding about content that came in via a `Merge ... into <branch>` commit (visible in `commits.md`), attribute it factually as "this PR carries forward [content from the merged-in change]; the merge resolution may need re-checking" rather than as authored-from-scratch by the PR author.

```

(Note the leading and trailing blank lines for paragraph separation in markdown.)

- [ ] **Step 4: Add the `/.knightwatch/` TODO note in `repos.conf`**

Find the SOURCE_PATHS declaration:

```bash
grep -n 'declare -A SOURCE_PATHS' repos.conf
```

Expected: one match. In the comment block immediately above that declaration (or just below it if the comments are below), add a paragraph:

```

# TODO(future): per-repo config in <each-repo>/.knightwatch/. Move
# product context, dead-code command, and per-base sibling-grep
# wishlist into a .knightwatch/config.toml inside each tracked repo,
# so the repo's own committers control what cross-repo signals their
# PRs get. The operator's repos.conf shrinks to "which repos to watch
# + where their checkouts live on disk." Has its own design surface
# (file format, trust model — read from base branch vs PR head,
# bootstrap, backwards-compat); deferred from PR #28's seam-fix.

```

- [ ] **Step 5: bash -n + just test**

```bash
bash -n lib/review-one-pr.sh && echo syntax-ok
just test
```

Expected: clean syntax, `all checks passed`.

- [ ] **Step 6: Commit**

```bash
git add lib/review-one-pr.sh prompts/common-header.md repos.conf
git commit -m "$(cat <<'EOF'
review-one-pr: ⚠️ warning when falling back to full PR diff

Adds the deterministic top-of-review note for the case where the
clean-incremental optimization couldn't be taken — either the prior
SHA was rebased away, or the branch merged main between then and now.
Uses the existing SKIPPED_CHECKS array (the same DRY mechanism that
already carries 🧪 Tests not run / 🔍 Prior-art (KID) not run).

Plus:

  - prompts/common-header.md: paragraph telling specialists to
    attribute merged-in content factually ("this PR carries forward
    [X]; merge resolution may need re-checking") rather than as
    authored-from-scratch by the PR author. Backstops the change to
    trust gh pr diff as the canonical view.

  - repos.conf: TODO note pointing at the /.knightwatch/ per-repo
    config direction, so the next person editing it sees the trajectory.

  - review-one-pr.sh: TODO note on the SKIPPED_CHECKS array pointing
    at the eventual REVIEW_NOTES rename + signature consolidation.
    Both follow-ups are mechanical and best as their own focused PRs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: End-to-end verification on real PR 552 inputs

**Files:**
- No file edits.

- [ ] **Step 1: Show the original spurious findings**

```bash
RUN=/home/odio/.pr-reviewer/runs/cncorp_plow__552__20260430T155615407Z__da4f39a
grep -E '\[medium\] This increment also strips|\[blocking\] The new \`build_tutorial\`' $RUN/agents/aggregator/output.md | head
```

Expected: shows the two attributed-to-plonkus-but-from-main findings that originally motivated this whole effort.

- [ ] **Step 2: Verify gh pr diff against current main returns the right scope**

```bash
TMP=$(mktemp -d)
cd "$TMP"
gh repo clone cncorp/plow plow -- --depth=500 --no-single-branch 2>&1 | tail -2
git -C plow fetch origin "+refs/pull/552/head:containers" --depth=500 --quiet
git -C plow checkout -B containers containers --quiet
echo "=== gh pr diff includes vercel.json or build_tutorial? ==="
gh pr diff 552 --repo cncorp/plow 2>/dev/null \
    | grep -E '^diff --git a/.*vercel\.json|^diff --git a/scripts/build_tutorial' \
    | head
echo "=== (empty above means good — those files are NOT in the PR per GitHub's view) ==="
cd / && rm -rf "$TMP"
```

Expected: empty result above the `(empty above means good ...)` line. GitHub's three-dot diff correctly excludes content that's already on main.

- [ ] **Step 3: Verify is_clean_incremental_available behaves correctly on a freshly-cloned branch**

```bash
TMP=$(mktemp -d)
cd "$TMP"
gh repo clone cncorp/plow plow -- --depth=500 --no-single-branch 2>&1 | tail -2
git -C plow fetch origin "+refs/pull/552/head:containers" --depth=500 --quiet
git -C plow checkout -B containers containers --quiet
. /home/odio/Hacking/knightwatch-reviewer3/lib/diff-build.sh

# A SHA that's an ancestor of HEAD with no merges in range should be clean.
# Use the most recent non-merge commit's parent as PRIOR.
PRIOR=$(git -C plow log --no-merges --pretty=format:%H -2 | tail -1)
echo "=== PRIOR: $PRIOR ==="
echo "=== Clean? (expect: clean OR not-clean depending on history; either is fine) ==="
if is_clean_incremental_available "$TMP/plow" "$PRIOR"; then
    echo "  predicate returned TRUE (clean incremental available)"
else
    echo "  predicate returned FALSE (would fall back to gh pr diff with ⚠️ warning)"
fi

# Force the unclean case: a known merge commit in range
echo "=== Now testing with a SHA known to have merge commits in range ==="
PRIOR_OLD=$(git -C plow log --pretty=format:%H -20 | tail -1)
if is_clean_incremental_available "$TMP/plow" "$PRIOR_OLD"; then
    echo "  predicate returned TRUE (no merges in last 20 commits — unusual but not an error)"
else
    echo "  predicate returned FALSE (merges in range OR not-ancestor — correct)"
fi

cd / && rm -rf "$TMP"
```

Expected: at least one of the two cases shows the predicate returning FALSE, demonstrating the merge-detection works on a real branch's history. The exact pass/fail per scenario depends on PR 552's current state, but the predicate must respond correctly to whatever git reports.

- [ ] **Step 4: No commit (verification only)**.

---

### Task 10: Push branch + post replies on PR #28

**Files:**
- No file edits beyond what previous tasks committed.

- [ ] **Step 1: Final sanity**

```bash
git status
git log --oneline main..HEAD
just test
```

Expected: clean tree (untracked `.claude/` and `docs/superpowers/` only); 8 new commits since the last pushed state; `all checks passed`.

- [ ] **Step 2: Push**

```bash
git push
```

Expected: success (no force-push, no `--no-verify`).

- [ ] **Step 3: Post replies on the bot's round-4 and round-5 review comments**

Both review comments raised the same two findings (diff-scope drift + auth-vs-visibility). Reply to each on its own surface (top-level, since each was a PR-level comment), pointing at the new structural fix:

```bash
cat > /tmp/babysit-reply-r4.md <<'EOF'
Both findings addressed structurally — design doc at `docs/superpowers/specs/2026-04-30-reviewer-simplification-design.md`, implementation across the most recent 8 commits.

**Diff scope (Finding 1).** Dropped `lib/diff-scope.sh` entirely along with `build_pr_diff` / `build_incremental_diff` / `compute_authored_files` / `has_traceable_history` / `DIFF_EXCLUDES` tracking (~225 lines). New design: single `gh pr diff` call up front populates both `KID_INPUT_DIFF` (default) and `FULL_PR_DIFF` (always). Override `KID_INPUT_DIFF` with local `git diff KNOWN_SHA..HEAD` ONLY when `is_clean_incremental_available` returns true — which requires both (a) prior SHA is still an ancestor of HEAD (replaces the broken `cat-file -e` existence check that misframed orphaned SHAs as incremental) AND (b) zero merge commits in `KNOWN_SHA..HEAD` (eliminates the same-file leak the round-2 finding identified). Any other condition leaves `KID_INPUT_DIFF` as the full PR diff and emits a deterministic `⚠️ Clean incremental unavailable` warning at the top of the review via the existing `SKIPPED_CHECKS` array. `file-history.md` derives its file list by parsing `^diff --git a/` headers out of `KID_INPUT_DIFF` directly — single source of truth for "what files this review covers."

**Cross-repo seam (Finding 2).** Dropped the `gh api collaborators/<author>/permission` auth-gate (per-sibling AND base-repo). `SOURCE_PATHS` in `repos.conf` IS the whitelist now: if the operator listed `cncorp/plow-content` for `cncorp/plow` reviews, that's affirmative consent to reference plow-content code in plow PR comments. 4-status classification (`included`/`excluded`/`missing`/`lookup-error`) → 2 (`included .siblings/<slug>` | `missing`). The "auth-vs-visibility" critique evaporates because there's no auth check; the "leak excluded slug names in coverage prose" critique evaporates because we don't list non-whitelisted siblings at all. Path-scrub safety net stays. Prompts updated for the simpler 2-status format.

**Net code delta:** ~-330 lines. Implementation in commits since `4fcb033` (the spec doc).

**On the merged-in attribution concern that originally motivated PR #28:** `gh pr diff` correctly excludes content that's already on main when both refs have the same content (verified on PR 552's current state — vercel.json and build_tutorial files do NOT appear in the gh pr diff output, since they're identical between origin/main and HEAD). The original bug was the worker's local origin/main being weeks-stale (depth-50 fetch), which produced wrong merge-base computations. Fixed by depth-500 in this PR.
EOF

# Post the same reply to both rounds (each was a separate top-level comment)
gh pr comment 28 --body-file /tmp/babysit-reply-r4.md
```

Expected: two new comment URLs printed (one per `gh pr comment` call — but since the round-4 and round-5 review bodies are functionally identical, one reply to the most recent suffices in practice; the babysit skill's "every comment gets a reply" rule is satisfied by replying to the most recent restated round). Use one reply on the latest review comment per the skill's "reply on the right surface" guidance.

- [ ] **Step 4: Trigger fresh whole-PR re-review**

This pass made substantial changes across multiple files (refactor + helper rename + prompt updates + delete). Use the whole-PR trigger:

```bash
gh pr comment 28 --body "/srosro-review"
```

Expected: comment URL printed.

- [ ] **Step 5: Hand back to babysit-pr** — the next babysit pass will pick up the new review when it lands. No `ScheduleWakeup` invocation in this task; the regularly-scheduled pass is enough.

---

## Self-review checklist

- [ ] **Spec coverage:**
    - Section 1 (whitelist-only cross-repo) — Tasks 1, 2, 3 ✓
    - Section 2 (gh pr diff default + clean-incremental optimization) — Tasks 4, 5, 6, 7 ✓
    - Deterministic ⚠️ warning via SKIPPED_CHECKS — Task 8 ✓
    - Attribution prompt update — Task 8 ✓
    - Deferred follow-ups (`/.knightwatch/`, REVIEW_NOTES rename) noted via TODOs — Task 8 ✓
    - E2E verification on real PR 552 inputs — Task 9 ✓
    - Post replies + trigger fresh review — Task 10 ✓
- [ ] **Placeholders:** none. Every step has exact file path, exact command, exact expected output, and (for code steps) the actual code block to write.
- [ ] **Type/name consistency:**
    - `is_clean_incremental_available` (helper, smoke, caller) — same name in all three.
    - `stage_search_roots` (helper, smoke, caller) — same name; signature changed to single-arg in Task 2.
    - `SKIPPED_CHECKS`, `DIFF_FALLBACK`, `KID_INPUT_DIFF`, `FULL_PR_DIFF` — used consistently across review-one-pr.sh edits.
    - `SOURCE_PATHS`, `REPOS` — consumed via global declare-A pattern, same as today.
- [ ] **Each task ends with a commit (TDD + frequent commits):** Tasks 2, 3, 5, 6, 7, 8 commit; Tasks 1, 4 are TDD-prep (no commit); Tasks 9, 10 are verification + push (no new commits beyond what 1–8 produced).
- [ ] **All new smokes added to justfile:** `diff-build` smoke replaces `diff-scope` smoke entry in Task 5; `search-roots` smoke entry stays unchanged (file is rewritten in Tasks 1–2 but its justfile entry doesn't change).
