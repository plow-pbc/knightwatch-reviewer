# Reviewer Simplification — Diff Scope & Cross-Repo Seam

**Status:** spec
**Author:** Sam (with Claude Opus 4.7)
**Context:** PR #28 (`fix/merge-attribution-and-path-leak`) on `srosro/knightwatch-reviewer`

## Goal

Replace two over-engineered seams in the reviewer worker with simpler, structurally-correct designs:

1. **Diff scope** — drop `lib/diff-scope.sh` and its supporting machinery. Default to `gh pr diff` for the canonical full-PR view. Use a local `git diff KNOWN_SHA..HEAD` only as an optimization when the incremental scope is *demonstrably clean* — i.e. the prior reviewed SHA is still on the branch's history AND no merge commits exist in the incremental range. Any other condition falls back to the full PR diff with a deterministic warning at the top of the review.

2. **Cross-repo seam** — drop the `gh api collaborators/<author>/permission` auth-gate (per-sibling AND base-repo). Treat `SOURCE_PATHS` (declared in `repos.conf`) as the whitelist itself: if the operator listed it, it's safe to reference. Two statuses for `search-roots.md` (`included` | `missing`); no `excluded`, no `lookup-error`. The path-scrub safety-net regex pass stays.

## Background

PR #28 set out to fix two real bugs surfaced on cncorp/plow#552: (a) the reviewer attributing merged-from-main content to the PR author, and (b) absolute host paths leaking into public PR comments. The first round of fixes (per-commit walk + author auth-gate + workdir-relative `.siblings/` + path-scrub) was reviewed by knightwatch itself across **5 rounds** of `/srosro-review` re-runs. Each round identified new edge cases in the same two seams:

| Round | Diff-scope finding | Cross-repo finding |
|-------|-------------------|--------------------|
| 1 | Incremental + file-history don't share the seam | Sibling staging ordered before auth gate; symlink-redirect attack |
| 2 | Same-file leak in filename filter; no fail-closed-vs-fallback discriminator | Smokes don't exercise the actual bug-fix paths |
| 3 (stale) | (re-flag of round 2) | (re-flag of round 1) |
| 4 | Per-commit walk reintroduces reverted intermediate states; loses conflict resolutions inside merge commits; rebased-away SHAs misframed as incremental | Auth-based not visibility-based; coverage-gap prose leaks excluded slug names into public comments |
| 5 | (same as round 4) | (same as round 4) |

The recurring finding class is "every local computation diverges from 'the current PR diff' the worker says it means" and "the cross-repo gate keys off the PR author's collaborator rights instead of the audience of the comment being posted."

The fixes-on-top-of-fixes pattern stopped converging. Both seams need a fresh, structurally-simpler design rather than a sixth round of patches.

## Section 1 — Cross-Repo Seam (whitelist-only)

### What changes

`lib/search-roots.sh::stage_search_roots` becomes a much smaller helper. The base-repo trust check (`gh api collaborators/<author>/permission` for the BASE repo) and the per-sibling trust check (same call for each sibling) are both deleted. The 4-status classification (`included`/`excluded`/`missing`/`lookup-error`) becomes a 2-status one (`included`/`missing`).

Trust model: `SOURCE_PATHS` in `repos.conf` IS the whitelist. If the operator listed `cncorp/plow-content` as a sibling source for `cncorp/plow`, that's the operator's affirmative consent that referencing plow-content code in a plow PR review is safe. The bot does not second-guess via runtime permission checks.

### New `search-roots.md` format

```
# coverage: full | partial | same-repo-only
<slug> included .siblings/<slug>     (whitelisted in repos.conf AND checkout exists on disk)
<slug> missing                       (whitelisted in repos.conf BUT checkout absent on disk)
```

`coverage` header values:
- `full` — every whitelisted sibling has its checkout on disk
- `same-repo-only` — no whitelisted siblings, OR none have their checkout on disk
- `partial` — at least one included AND at least one missing

No `excluded` lines (the auth-gate that produced them is gone). No `lookup-error` lines (no `gh api` call to fail). The 4-status classification's whole purpose was "qualify the verdict because we couldn't check this sibling for trust"; with no trust check, only on-disk presence matters, and `missing` already covers that.

### What stays

- `lib/sibling-symlinks.sh::materialize_sibling_symlinks` — same signature, called the same way (after `stage_search_roots`, with the `included` slug list parsed from the search-roots output). The function itself doesn't change; just its input is now derived from a simpler search-roots output.
- `lib/path-scrub.sh::scrub_review_paths` — unchanged. Still the last-hop regex pass before `gh pr comment`. Strips workdir prefix, sibling abs paths (via `SOURCE_PATHS`), and any leaked `.siblings/` prefix. The safety net stays even though Section 1 reduces the *primary* path-leak risk.

### Prompt updates

- `prompts/consumers.md`, `prompts/dead-code-search.md` — drop the "downgrade to uncertain when sibling has non-included status (excluded / missing / lookup-error)" paragraphs. Replace with the simpler reality: *"`search-roots.md` lists each whitelisted sibling as either `included .siblings/<slug>` (grep this) or `missing` (operator-config gap; treat as a coverage gap for any modified public symbol that plausibly has consumers there)."*
- The "cross-repo finding framing" paragraph added in PR #28 stays (about phrasing as "your change here breaks consumer X" rather than "fix this in X").

### Smoke test

`lib/tests/search-roots-smoke.sh` shrinks from 7 scenarios to 2:
1. **All siblings have checkouts on disk** — coverage: `full`, every sibling listed as `included .siblings/<slug>`
2. **One sibling missing on disk** — coverage: `partial`, that sibling listed as `missing`

The auth-related scenarios (untrusted base, untrusted sibling, lookup-error on each) are deleted because the code paths they covered are deleted.

### Code delta (Section 1)

- `lib/search-roots.sh` — ~115 lines → ~30 lines (delete the two `gh api` blocks and the 4-way `case` classification)
- `lib/tests/search-roots-smoke.sh` — ~150 lines → ~50 lines (delete 5 scenarios)
- `prompts/consumers.md`, `prompts/dead-code-search.md` — replace the qualifying paragraphs (~10 lines each)

## Section 2 — Diff Scope (gh pr diff default + clean-incremental optimization)

### What changes

The entire `lib/diff-scope.sh` file is deleted. Its dependents (`build_pr_diff`, `build_incremental_diff`, `compute_authored_files`, `compute_pr_authored_files`, `has_traceable_history`, `build_authored_diff`, `DIFF_EXCLUDES` tracking) are deleted along with it. The diff-build block in `lib/review-one-pr.sh` becomes ~15 lines.

### New diff-build seam

```bash
# Single gh pr diff call up front — the canonical "what's in this PR"
# view, same one humans see on the PR's "Files changed" tab. Used for
# both KID_INPUT_DIFF (the diff specialists review) by default, and
# FULL_PR_DIFF (the aggregator's "verify prior findings against current
# state" reference) always.
FULL_PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
KID_INPUT_DIFF="$FULL_PR_DIFF"
DIFF_FALLBACK=false

# Optimization: use a local incremental diff for KID_INPUT_DIFF ONLY
# when the prior reviewed SHA is still on the branch's history AND no
# merge commits exist in the incremental range. Any other condition
# (rebase/force-push evicted the prior SHA, OR the branch merged main
# between then and now) would leak merge-from-main content or misframe
# an off-branch SHA, so we leave KID_INPUT_DIFF as the full PR diff and
# emit a deterministic warning at the top of the review.
if [ -n "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" != "true" ]; then
    if git -C "$REPO_DIR" merge-base --is-ancestor "$KNOWN_SHA" HEAD 2>/dev/null \
       && [ -z "$(git -C "$REPO_DIR" log --merges --pretty=format:%H "$KNOWN_SHA..HEAD" 2>/dev/null)" ]; then
        KID_INPUT_DIFF=$(git -C "$REPO_DIR" diff "$KNOWN_SHA..HEAD")
        log "$PR_ID: clean incremental diff since ${KNOWN_SHA:0:7}"
    else
        DIFF_FALLBACK=true
        log "$PR_ID: incremental not clean (rebased or merged-from-main since ${KNOWN_SHA:0:7}); using full PR diff"
    fi
fi

# Empty-diff abort — same fail-fast as today. If gh pr diff itself
# returned nothing (auth/network failure), bail rather than posting a
# meaningless review.
if [ -z "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: empty diff — gh pr diff returned nothing (possible auth or network issue), aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
```

### Why these two checks

1. **`git merge-base --is-ancestor KNOWN_SHA HEAD`** — replaces today's `git cat-file -e KNOWN_SHA^{commit}` (which only checks "object exists in repo," not "still in this branch's history"). A force-push or rebase leaves the old commit's object in the store but orphaned; `cat-file -e` returns success and the worker silently does `git diff $orphan..HEAD`, which produces a meaningless diff or worse. `--is-ancestor` correctly fails for orphaned SHAs → fall back.

2. **`git log --merges KNOWN_SHA..HEAD` empty** — guarantees no merge commits in the incremental range. Without this check, the incremental diff `KNOWN_SHA..HEAD` includes any commits brought in via `git merge origin/main` between then and now, polluting attribution (the bot's round 2 same-file finding). With this check, when the branch HAS merged main, we fall back to `gh pr diff` — whose three-dot semantics correctly handle the merge-base advance.

### Deterministic warning at top of review (DRY via existing array)

The fallback case (`DIFF_FALLBACK=true`) emits a warning at the top of the posted review through the existing `SKIPPED_CHECKS` mechanism in `prepend_review_header`. One line added in `review-one-pr.sh` near the existing `SKIPPED_CHECKS+=("🧪 Tests")` and `SKIPPED_CHECKS+=("🔍 Prior-art (KID)")`:

```bash
[ "$DIFF_FALLBACK" = "true" ] && SKIPPED_CHECKS+=("⚠️ Clean incremental unavailable; reviewed full PR diff")
```

The existing `SKIPPED_CHECKS` array (declared in `review-one-pr.sh`, formatted into the header by `prepend_review_header` in `lib/run-dir.sh`) is already the DRY answer for "deterministic top-of-review notes." Today it carries `🧪 Tests not run` and `🔍 Prior-art (KID) not run`; adding the diff-fallback warning extends it by one line, exactly as the existing code comment ("add a new capability by appending one line — no helper change needed") prescribes.

A `# TODO:` comment goes near the array setup pointing at a future rename to `REVIEW_NOTES` (the array now carries warnings, not just skips) — that rename + signature change to `prepend_review_header` is a separate cleanup PR.

### File-history scope

`file-history.md` is derived from whichever diff was chosen (`KID_INPUT_DIFF`), by parsing the `^diff --git a/<path> b/<path>` headers out of it. Single source of truth — same files specialists see in `diff.patch` are the files file-history covers, regardless of full-PR or incremental scope:

```bash
TOUCHED_FILES=$(printf '%s' "$KID_INPUT_DIFF" \
    | grep -E '^diff --git a/' \
    | sed -E 's|^diff --git a/(.*) b/.*$|\1|' \
    | sort -u | head -30)
```

This replaces the current `compute_pr_authored_files "$REPO_DIR" "$DEFAULT_BRANCH"` invocation. Works for both `gh pr diff` and `git diff` outputs (both emit `diff --git a/<path> b/<path>` headers).

### Prompt update for attribution

One paragraph added to `prompts/common-header.md`, in the inputs list near `diff.patch`:

> *"`diff.patch` is what GitHub considers part of this PR — including any content the branch pulled in via `git merge origin/<base>` commits. If you flag a finding about content that came in via a `Merge ... into <branch>` commit (visible in `commits.md`), attribute it factually as 'this PR carries forward [content from the merged-in change]; the merge resolution may need re-checking,' rather than as authored-from-scratch by the PR author."*

This is the prompt-side answer to the attribution concern that originally motivated PR #28. The diff itself faithfully shows what's in the PR; the attribution nuance is something specialists can reason about correctly when prompted.

### What stays

- `lib/path-scrub.sh::scrub_review_paths` — unchanged. Last-hop safety net before `gh pr comment`.
- `lib/sibling-symlinks.sh::materialize_sibling_symlinks` — unchanged.
- The existing `--depth=500` fetch — kept. Even though we trust `gh pr diff` for the full-PR view, the `--is-ancestor` and `log --merges` checks are local git operations that need adequate history to be reliable. `--depth=500` covers realistic cases.

### Smoke test

`lib/tests/diff-scope-smoke.sh` is deleted (it tested the deleted helpers). Replaced with a smaller smoke `lib/tests/diff-build-smoke.sh` that exercises the new conditional logic in `review-one-pr.sh`'s diff-build block:

1. **First review (no KNOWN_SHA)** — uses `gh pr diff` (mocked); `DIFF_FALLBACK=false`
2. **Re-review, prior SHA on branch, no merges in range** — uses local `git diff KNOWN_SHA..HEAD`; `DIFF_FALLBACK=false`
3. **Re-review, prior SHA rebased away (not ancestor of HEAD)** — falls back to `gh pr diff`; `DIFF_FALLBACK=true`
4. **Re-review, prior SHA on branch, merge commit in range** — falls back to `gh pr diff`; `DIFF_FALLBACK=true`
5. **Re-review with `FORCE_WHOLE_PR=true`** — uses `gh pr diff`; no incremental attempt; `DIFF_FALLBACK=false`

Each scenario verifies (a) the diff source actually used, and (b) whether `DIFF_FALLBACK` is set correctly so the warning appears at the top.

### Code delta (Section 2)

- `lib/diff-scope.sh` — entire file deleted (~85 lines)
- `lib/tests/diff-scope-smoke.sh` — entire file deleted (~140 lines), replaced with smaller `lib/tests/diff-build-smoke.sh` (~80 lines)
- `lib/review-one-pr.sh` — `build_pr_diff`, `build_incremental_diff`, `DIFF_EXCLUDES` tracking, the 50-line conditional that switched between `build_pr_diff` and `build_incremental_diff` — all gone. Replaced with the ~15-line block above. The file-history loop's `compute_authored_files "$REPO_DIR" HEAD "${DIFF_EXCLUDES[@]}"` becomes the `TOUCHED_FILES` parse from `$KID_INPUT_DIFF`. The `SKIPPED_CHECKS+=("⚠️ ...")` line is the one addition.
- `prompts/common-header.md` — one paragraph added.
- `justfile` — `=== diff-scope smoke test ===` block renamed to `=== diff-build smoke test ===`, points at the new smoke file.

## Net code delta (both sections combined)

- **Deleted:** `lib/diff-scope.sh` (~85), `lib/tests/diff-scope-smoke.sh` (~140), Section 1 reductions in `lib/search-roots.sh` (~85) and `lib/tests/search-roots-smoke.sh` (~100), the `build_pr_diff`/`build_incremental_diff`/`DIFF_EXCLUDES` tracking in `lib/review-one-pr.sh` (~50). **Total: ~460 lines.**
- **Added:** New diff-build block in `review-one-pr.sh` (~15), `TOUCHED_FILES` parse (~6), `SKIPPED_CHECKS+=("⚠️ ...")` (~1), `lib/tests/diff-build-smoke.sh` (~80), prompt paragraphs in `common-header.md` + `consumers.md` + `dead-code-search.md` (~30 lines net). **Total: ~130 lines.**
- **Net:** ~-330 lines.

## Deferred follow-ups (NOT in this spec)

These are real opportunities surfaced during the brainstorm but explicitly scoped out of this design to keep PR #28's review surface manageable:

- **`/.knightwatch/` per-repo config.** Move per-repo declarations (product context, dead-code command, sibling-grep wishlist) from central `repos.conf` into each tracked repo's `.knightwatch/` directory. Operator's `repos.conf` would shrink to "which repos to watch + which sibling checkouts I have on disk." Has its own design surface: file format (TOML vs bash), trust model (read from base branch vs PR head), bootstrap (first review on a never-onboarded repo), backwards-compat (un-onboarded repos keep working with sensible defaults). A `# TODO:` line in `repos.conf` near the SOURCE_PATHS declaration will point at this direction so the next person editing it sees the trajectory.

- **`SKIPPED_CHECKS` → `REVIEW_NOTES` rename + consolidation.** The array now carries warnings, not just skips, and `prepend_review_header` could absorb the `review_scope` and `stale_head` arguments as additional notes in the same array. Mechanical refactor; lands cleaner as its own focused PR after this one.

## Test plan

- `just test` — all existing smokes pass, plus new `diff-build-smoke.sh` (5 scenarios) and updated `search-roots-smoke.sh` (2 scenarios)
- **End-to-end on PR 552** — fresh deep clone + the new diff-build block: confirm `gh pr diff` returns the same output the bot would have shown today, no vercel.json or build_tutorial in the authored set
- **End-to-end on this PR (#28)** — once the production checkout is updated post-merge, trigger `/srosro-review` on PR #28 itself; confirm diff scope, sibling-coverage, and absence of leaked paths all behave as designed
- **Force-push scenario** — manual: push to PR #28, force-push it back to a prior SHA, trigger `/srosro-update-review`; confirm the warning appears at the top and the reviewer falls back to full-PR diff
- **Merge-from-main scenario** — manual: merge main into PR #28's branch, trigger `/srosro-update-review`; confirm warning + fallback

## Operator notes (for the commit message, not this spec)

- No `repos.conf` changes required — the SOURCE_PATHS declarations the operator already has continue to work as the new whitelist.
- The first reviewer tick after deploy will show a slightly different `search-roots.md` format on every review (no `excluded` / `lookup-error` lines), and any review of a PR whose branch has merged main will start showing the new `⚠️ Clean incremental unavailable` header when re-reviewed. Both are expected.
