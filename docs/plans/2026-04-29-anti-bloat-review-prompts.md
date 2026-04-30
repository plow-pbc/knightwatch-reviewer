# Anti-Bloat Review Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten the kw-reviewer + babysit-pr loop so it stops proposing remedies that add defensive branches, fallback chains, type-checks outside trust boundaries, or wrappers for theoretical edge cases.

**Architecture:** Five markdown edits across `knightwatch-reviewer3` (3 files) and `vibe-engineering` (2 files). One high-leverage rule lands in `prompts/common-header.md` and inherits to the 6 finding-producing specialists (security, data-integrity, architecture, simplification, tests, shape) via `build_specialist_prompt`. The `intent`, `critic`, and `aggregator` prompts bypass the common header by design — their `REMEDY-BLOAT` bucket and handling are added directly in their own files. Two downstream gates (`critic.md` bucket, `babysit-pr` triage bucket) catch anything that slips past. `COMMENT_REVIEW_MISTAKES.md` gets seeded with 5 explicit anti-patterns. `architecture.md` loses two paragraphs that the new common-header rule supersedes.

**Tech Stack:** Markdown only. No code, no tests beyond the existing smoke scripts that exercise prompt assembly.

---

## Spec

See `docs/specs/2026-04-29-anti-bloat-review-prompts-design.md` for the design, the investigation that informed it, and the bloat patterns each change targets.

## Cross-cutting framing

Every prompt edit must use the user's framing: **LOC is a stand-in for conditionals, special cases, and defensive branches that calcify the codebase.** The test for any proposed remedy is whether the edge case it handles *actually happens or will happen in the near future*. Theoretical edge cases justify no special-case code.

When writing the language for each task, lean on concrete bans ("don't propose X") over abstract principles. Specialists generalize better from explicit examples than from soft framing.

---

## Task 1: Add Rule 8 (Remedy-cost framing) to `prompts/common-header.md`

**Files:**
- Modify: `prompts/common-header.md` (in `knightwatch-reviewer3` — currently 51 LOC; add ~7 LOC after the existing rule 7 inside the `**Rules for your output:**` block)

**Why this task is first:** Every specialist prompt is built by `lib/prompt-build.sh:build_specialist_prompt()` as `common-header.md` + the angle file. So this single edit propagates to security, data-integrity, architecture, simplification, tests, and shape — six of the seven prompts that produce findings. Critic and aggregator read the assembled `standards.md` separately and need their own edits (Tasks 3 and 4); this rule is for the finding-producers.

- [ ] **Step 1: Read the current rules block**

Run: `grep -n "Rules for your output:" prompts/common-header.md` and read lines 26–51 to confirm the existing structure (rules 1–7).

- [ ] **Step 2: Insert Rule 8 after Rule 7**

Insert after the line ending Rule 7 (the line about keeping each finding under 120 words):

```markdown
8. **Remedy-cost framing.** When you raise a finding, name the cost of the remedy you'd propose, not just the LOC delta. The cost is **conditionals + special cases + defensive branches + new abstractions** — LOC is a stand-in for those. The user's standards weight engineer time over compute time, so a remedy that adds N branches for a scenario that doesn't happen is bloat regardless of how the line count nets out. **Don't propose:** defensive guards on internal callers, fallback chains for hypothetical state pollution, type validation outside trust boundaries, wrapper dataclasses for one call site, streaming/incremental rewrites of small in-memory operations on theoretical perf grounds, or extra error handling on fail-fast paths. The test for any edge-case handler: *does the edge case actually happen, or will it in the near future?* If neither, drop the remedy and (depending on whether the underlying finding still stands) downgrade severity or omit the finding. Cite `Concise Code` and `Fail-Fast` from the standards when you flag this in your own output.
```

- [ ] **Step 3: Verify the file still parses cleanly**

Run: `wc -l prompts/common-header.md` — expect 58–59 lines (was 51). Open the file in any reader, confirm Rule 8 sits between Rule 7 and the trailing closing of the rules block (or the end of file).

- [ ] **Step 4: Smoke-test prompt assembly**

**Deployment is automatic on this box**: `~/.pr-reviewer/` symlinks `prompts/`, `lib/`, `contexts/`, etc. into `~/Hacking/knightwatch-reviewer/`, so the running pipeline picks up changes the moment they land on `main` and the canonical install pulls (≤2 min after merge per the systemd timers). **Do NOT `cp` from this checkout into `~/.pr-reviewer/`** — `cp` writes through the symlink into the canonical install's working tree, polluting its git state and creating drift between this branch and the deployed prompt. Verification happens against the source files in this branch.

Verify the new rule is present in the source file (the existing `lib/tests/build-specialist-prompt-smoke.sh` already fences the substitution machinery with a controlled fake header — it does NOT need updating to pin Rule 8's literal text, which would calcify wording without catching quality regressions per Rule 8 itself):

Run:
```bash
grep -A2 "Remedy-cost framing" prompts/common-header.md
```

Expected: the rule body is present and includes the bans (defensive guards on internal callers, fallback chains, type validation outside trust boundaries, wrapper dataclasses for one call site, streaming rewrites, extra error handling on fail-fast paths). To exercise the full pipeline end-to-end including substitution, wait for merge → the canonical install pulls automatically and the next timer tick (≤2 min) reviews the live prompt against the next inbound PR.

- [ ] **Step 5: Commit**

```bash
cd ~/Hacking/knightwatch-reviewer3
git checkout -b feat/anti-bloat-review-prompts
git add prompts/common-header.md
git commit -m "$(cat <<'EOF'
prompts: add Rule 8 — remedy-cost framing to common-header

Inherits to all 6 finding-producing specialists. Names that the cost
being managed is conditionals + special cases + defensive branches,
not just LOC, and bans the recurring remedy patterns observed across
PRs 544/546/552: defensive guards on internal callers, fallback
chains, type validation outside boundaries, wrapper dataclasses for
one call site, streaming rewrites for theoretical perf, extra error
handling on fail-fast paths.

See docs/specs/2026-04-29-anti-bloat-review-prompts-design.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Trim `prompts/architecture.md` to drop content now redundant with Rule 8

**Files:**
- Modify: `prompts/architecture.md` (currently 21 LOC; drop ~5–8 LOC)

- [ ] **Step 1: Identify the redundant content**

Read `prompts/architecture.md` lines 13 and 17 specifically:

- Line 13: the bullet beginning "Over-engineering for this stage (10 users, moving quickly)..." includes the parenthetical "**Note:** 'more compute / more latency to delete a class of special cases' is *not* over-engineering — it is the trade we want at this stage. The thing being optimized is engineer-hours, not CPU." — this restates Rule 8's "engineer time over compute time" framing. Keep the bullet's first sentence; drop the **Note:** parenthetical.
- Line 17: the standalone paragraph "**You are explicitly allowed to file non-blocking findings of the form: 'this is fine to ship today, but file an issue to migrate before X happens.'** That is often the most valuable finding this specialist produces — mark those as `low` or `medium`, not `blocking`." — this is a permission grant, not a constraint. Rule 8 already permits it (the rule only bans bloat-y *current* remedies, not low-severity future-cost findings). Drop this entire paragraph.

- [ ] **Step 2: Apply the edits**

Delete the **Note:** sentence inside the over-engineering bullet (keep the bullet, just trim the parenthetical).

Delete the standalone "explicitly allowed to file non-blocking" paragraph and the trailing blank line.

Expected new line count: 13–16 LOC (down from 21).

- [ ] **Step 3: Verify**

Run: `wc -l prompts/architecture.md` — expect 13–16. Open and read end-to-end to confirm flow still reads cleanly without the dropped sentences.

- [ ] **Step 4: Commit**

```bash
git add prompts/architecture.md
git commit -m "$(cat <<'EOF'
prompts/architecture: drop two paragraphs now redundant with Rule 8

The 'engineer time over compute time' note and the 'explicitly allowed
to file non-blocking migrate-before-X findings' paragraph both restate
content that the new common-header Rule 8 covers. Keep the bullets
that scope each angle; drop the standalone permission grants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `REMEDY-BLOAT` status bucket to `prompts/critic.md`

**Files:**
- Modify: `prompts/critic.md` (currently 70 LOC; add ~3 LOC)

- [ ] **Step 1: Locate the status bucket list**

Read `prompts/critic.md` lines 22–32 (the numbered list 1–6 of stress-test angles, each with its existing status name) and lines 36–38 (the format header inside the output block: `### [security] Finding N — <status: AGREE | FALSE POSITIVE | OVER-SPECIFIC | MISCALIBRATED | ALREADY ADDRESSED | DUPLICATE OF [other-specialist] Finding M>`).

- [ ] **Step 2: Add a 7th numbered angle**

Insert after item 6 (the existing `**Duplicate**` entry):

```markdown
7. **Remedy-bloat** — finding may be valid but the implied fix adds defensive branches, fallback chains, type validation outside trust boundaries, a new abstraction for one call site, or handles a theoretical edge case that doesn't actually occur. The cost is conditionals/special cases that calcify, not just LOC. Either rewrite to point at the LOC-negative / branch-negative alternative, or drop the finding. Cite `Concise Code`, `Fail-Fast`, or the relevant `COMMENT_REVIEW_MISTAKES` entry.
```

- [ ] **Step 3: Add `REMEDY-BLOAT` to the status enum in the output format**

Update the output-format header line to include `REMEDY-BLOAT`:

```markdown
### [security] Finding N — <status: AGREE | FALSE POSITIVE | OVER-SPECIFIC | MISCALIBRATED | REMEDY-BLOAT | ALREADY ADDRESSED | DUPLICATE OF [other-specialist] Finding M>
```

- [ ] **Step 4: Update the aggregator's handling — note for next task**

The aggregator at `prompts/aggregator.md:36–43` lists how to handle each critic verdict (AGREE, FALSE POSITIVE, OVER-SPECIFIC, etc). It doesn't yet know about `REMEDY-BLOAT`. Add to that list (in the *next task*, not this one — keep this commit focused) a single line: "**REMEDY-BLOAT** → either drop, or rewrite the finding to recommend the LOC-negative alternative the critic named."

For now, just append a TODO note to your commit message so it's visible in `git log` for follow-up.

- [ ] **Step 5: Verify**

Run: `wc -l prompts/critic.md` — expect 73–74 (was 70).

Run: `grep -c "REMEDY-BLOAT" prompts/critic.md` — expect 2 (the numbered angle + the output-format enum).

- [ ] **Step 6: Commit**

```bash
git add prompts/critic.md
git commit -m "$(cat <<'EOF'
prompts/critic: add REMEDY-BLOAT status bucket

Lets the critic mark a finding whose remedy adds defensive branches,
fallback chains, type checks outside boundaries, or new abstraction
for theoretical concerns. The cost is conditionals + special cases
that calcify, not just LOC.

Aggregator handling lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Teach the aggregator how to handle `REMEDY-BLOAT`

**Files:**
- Modify: `prompts/aggregator.md` (currently 138 LOC; add ~1 LOC)

- [ ] **Step 1: Locate the verdict-handling list**

Read `prompts/aggregator.md` lines 36–43 — the bulleted list under step 1 covering AGREE, FALSE POSITIVE, OVER-SPECIFIC, MISCALIBRATED, ALREADY ADDRESSED, DUPLICATE.

- [ ] **Step 2: Add the `REMEDY-BLOAT` verdict line**

Insert after the `**MISCALIBRATED**` line (matching style — bolded verdict name, em-dash, action):

```markdown
   - **REMEDY-BLOAT** → drop unless the critic named a LOC-negative alternative; if it did, keep the finding at the original or downgraded severity, rewritten to point at that alternative.
```

- [ ] **Step 3: Verify**

Run: `grep -A1 "REMEDY-BLOAT" prompts/aggregator.md | head -3` — expect to see the new line under step 1.

- [ ] **Step 4: Commit**

```bash
git add prompts/aggregator.md
git commit -m "$(cat <<'EOF'
prompts/aggregator: handle the new REMEDY-BLOAT critic verdict

Drops or rewrites findings the critic flagged as bloat-y remedy.
Pairs with the prior commit that added the bucket to critic.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Push the kw-reviewer branch and open a PR

- [ ] **Step 1: Push**

```bash
cd ~/Hacking/knightwatch-reviewer3
git push -u origin feat/anti-bloat-review-prompts
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --title "prompts: anti-bloat — remedy-cost framing across all specialists" --body "$(cat <<'EOF'
## Summary

- Adds a Rule 8 (Remedy-cost framing) to `common-header.md` that inherits to all 6 finding-producing specialists. Bans defensive guards on internal callers, fallback chains, type validation outside trust boundaries, wrapper dataclasses for one call site, streaming rewrites on theoretical perf grounds, and extra error handling on fail-fast paths.
- Trims two paragraphs in `architecture.md` now covered by Rule 8.
- Adds a `REMEDY-BLOAT` status bucket to `critic.md` and teaches `aggregator.md` how to handle it.

The cost being managed is **conditionals + special cases + defensive branches**, not just LOC. Each calcified branch survives every future refactor and shapes the next change. Spec: `docs/specs/2026-04-29-anti-bloat-review-prompts-design.md`. Investigation across PRs 544/546/552 surfaced 5 recurring bloat patterns — see the spec.

## Test plan

- [ ] `~/.pr-reviewer/prompts/*.md` picks up the merged content automatically via symlink (no `cp` step)
- [ ] Manual prompt-assembly check: `build_specialist_prompt shape ...` produces a prompt that includes Rule 8 with placeholders substituted
- [ ] Live observation on the next 1-2 active PRs: the bot does not propose any of the 5 patterns from the spec
- [ ] Two-week follow-up to evaluate whether scope creep has measurably dropped

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Capture the PR URL** for the follow-up vibe-engineering PR description.

---

## Task 6: Seed `COMMENT_REVIEW_MISTAKES.md` with anti-bloat patterns

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/COMMENT_REVIEW_MISTAKES.md` (currently 12 LOC; add ~10 LOC)

- [ ] **Step 1: Switch to vibe-engineering and create a feature branch**

```bash
cd ~/Hacking/vibe-engineering
git checkout main && git pull --ff-only
git checkout -b feat/anti-bloat-mistakes-seed
```

- [ ] **Step 2: Read the current file structure**

The file currently has 5 numbered entries (lines 8–12). Each entry is a single sentence stating a pattern + when not to apply it.

- [ ] **Step 3: Append entries 6–10 after entry 5**

Match the existing terse style — one sentence per entry, no PR numbers, no specific paths, no team names.

```markdown
6. Don't propose replacing `assert X` (or other fail-fast guards) with explicit raise + logging context. The user's `Fail-Fast` standard prefers the assertion crashing loudly on internal-caller bugs; logging+raise is bloat unless the code sits at a trust boundary.
7. Don't propose `isinstance` / type-validation checks for internal callers. Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers — adding type guards calcifies the call shape and contradicts `Concise Code`.
8. Don't propose state-reset / fallback writes ("set X = default in case prior init left it dirty") unless the polluting scenario is observed in production, not theoretical. A fallback chain for module-global pollution mostly fires in tests and locks the surrounding code into preserving both branches forever.
9. Don't propose wrapper dataclasses, snapshot views, or new DI seams when a 1–2 line direct fix solves the same problem. Snapshots and freeze-views are remedies for *repeated* problems, not first instances; "Three similar lines > premature abstraction" applies.
10. Don't propose streaming / incremental rewrites of small in-memory operations on theoretical perf or OOM grounds. Cite a measured failure or skip — the streaming version typically adds 15+ LOC of state machine, and the in-memory version costs nothing on the inputs that actually arrive.
```

- [ ] **Step 4: Sync to the active location**

Run: `cp COMMENT_REVIEW_MISTAKES.md ~/.claude/COMMENT_REVIEW_MISTAKES.md`

(`lib/review-one-pr.sh:435` reads from `~/.claude/COMMENT_REVIEW_MISTAKES.md` when assembling each PR's `standards.md`.)

- [ ] **Step 5: Verify the file remains under the auto-tune cap**

The hourly `learn-from-replies.sh` maintains a "ranked top-48 list." We're going from 5 to 10 entries — well under that cap. Confirm:

Run: `wc -l ~/.claude/COMMENT_REVIEW_MISTAKES.md` — expect ~22 lines including header/blank lines.

- [ ] **Step 6: Commit**

```bash
git add COMMENT_REVIEW_MISTAKES.md
git commit -m "$(cat <<'EOF'
mistakes: seed 5 anti-bloat patterns observed across PRs 544/546/552

Adds entries 6–10 covering the recurring remedy patterns the bot
shouldn't propose: assert→raise+log replacements, isinstance checks
for internal callers, state-reset fallbacks for theoretical pollution,
wrapper dataclasses for one call site, streaming rewrites for
theoretical perf.

Each entry suppresses a documented class of finding the bot proposed
and that the author had to push back on. Future tuning still flows
through /srosro-memorize via learn-from-replies.sh — this just seeds
the calibration so it doesn't have to organically accumulate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Replace `babysit-pr/SKILL.md` Step 5 triage with three buckets

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/skills/babysit-pr/SKILL.md` (currently 201 LOC)

- [ ] **Step 1: Read the current Step 5 block**

Read lines 73–84 of `skills/babysit-pr/SKILL.md`. The current structure: a header paragraph ("Two buckets only..."), a 2-row table (Apply / Decline), a "When unclear" paragraph, a "Verify references" paragraph.

- [ ] **Step 2: Read the templates section**

Read lines 117–124 — the **Templates** subsection has bullets including "Applied:" and "Applied with scope expansion:". The Counter-propose bucket needs its own template here.

- [ ] **Step 3: Replace the Step 5 header paragraph**

The current line: `**Two buckets only: apply or decline. There is no "defer" bucket — deferred work usually never happens.** If a finding is valid, do it now even if it expands the PR's scope a bit. ...`

Replace with:

```markdown
**Three buckets: apply, counter-propose, decline. There is no "defer" bucket — deferred work usually never happens.** If a finding is valid AND the proposed remedy doesn't add defensive branches, fallback chains, or new abstractions, apply it now even if it expands the PR's scope a bit. If the finding is real but the remedy as written would add bloat, *counter-propose* — apply the LOC-negative version and explain in the reply. Only stop and ask the user if the fix would touch many files unrelated to this PR's purpose.
```

- [ ] **Step 4: Replace the table with the 3-bucket version**

Current table:
```markdown
| Verdict | Examples | Action |
|---|---|---|
| **Apply** | real bug, missing auth check, leftover `if x:` defensive guard the bot correctly flagged, hallucinated import, dead code that reduces LOC, real security issue, **stale docs adjacent to the change, small but real refactor that improves the diff, a CI guard the bot suggested that would catch this class of bug** | fix in Step 6, even if it widens scope a bit |
| **Decline** | "add `try/except`", "add null/empty check" outside system boundaries, "extract helper" for 1–2 call sites, "add comment" for self-evident code, fallback chains (`a or b or default`), `// removed` breadcrumbs for deleted code, "add docstring" on trivial functions, sycophantic replies, premature abstractions | reply citing the conflicting rule |
```

Replace with:
```markdown
| Verdict | Examples | Action |
|---|---|---|
| **Apply** | real bug, missing auth check, leftover `if x:` defensive guard the bot correctly flagged, hallucinated import, dead code that reduces LOC, real security issue, stale docs adjacent to the change, small refactor that genuinely shrinks the diff | fix in Step 6, even if it widens scope a bit |
| **Counter-propose** | finding is real but remedy adds defensive branches, fallback chains, type validation outside trust boundaries, a wrapper dataclass for one call site, streaming rewrite for theoretical perf, or an extra `try/except` on a fail-fast path. The cost is conditionals + special cases + edge-case handlers that calcify, not just LOC. | apply the LOC-negative / branch-negative version; reply: "valid finding, but the remedy as written adds N branches for a scenario that doesn't happen here. Applying `<diff>` instead — same fix, no calcification." |
| **Decline** | "add `try/except`" / "add null/empty check" outside system boundaries, "extract helper" for 1–2 call sites, "add comment" for self-evident code, fallback chains (`a or b or default`), `// removed` breadcrumbs for deleted code, "add docstring" on trivial functions, sycophantic replies, premature abstractions, finding hallucinates the bug | reply citing the conflicting rule |
```

- [ ] **Step 5: Drop the redundant "Applied with scope expansion" template**

Templates subsection currently has:
```markdown
- **Applied:** `Applied in <SHA> — <one-sentence change>. Thanks for flagging.`
- **Applied with scope expansion:** `Applied in <SHA> — also touched <file> beyond this PR's original scope, since deferring usually means it doesn't get done.`
- **Scope too large to silently apply:** `Valid finding — but applying would touch <N> files unrelated to this PR. Want me to handle here or as a separate change?` (then wait for user)
- **Declined:** `Declined — conflicts with the "<rule name>" rule in <file>. Specifically: <why>. Leaving as-is.`
- **No-finding bot review** (e.g., knightwatch "Findings: None", Copilot summary-only): `Acknowledged — no findings raised.`
```

Replace with:
```markdown
- **Applied:** `Applied in <SHA> — <one-sentence change>. Thanks for flagging.`
- **Counter-proposed:** `Applied in <SHA> — valid finding, but the suggested remedy adds <N defensive branches / fallback chain / wrapper dataclass> for <theoretical scenario>. Applied the LOC-negative version: <one-sentence diff>. Cites <Fail-Fast | Concise Code | mistakes #N>.`
- **Scope too large to silently apply:** `Valid finding — but applying would touch <N> files unrelated to this PR. Want me to handle here or as a separate change?` (then wait for user)
- **Declined:** `Declined — conflicts with the "<rule name>" rule in <file>. Specifically: <why>. Leaving as-is.`
- **No-finding bot review** (e.g., knightwatch "Findings: None", Copilot summary-only): `Acknowledged — no findings raised.`
```

The "Applied with scope expansion" template collapses into the first two — Apply is for in-scope LOC-neutral fixes, Counter-proposed handles the case where the remedy would widen scope with bloat.

- [ ] **Step 6: Drop the now-redundant red flag**

Lines 192–197 list red flags. The line `- About to write "this is out of scope, tracking as a follow-up" → STOP. Deferring rarely happens. Either apply it (even if scope widens a bit) or ask the user explicitly` stays. But add one new red flag adjacent to it:

```markdown
- About to apply a fix verbatim that adds defensive branches / fallback chains / type-checks outside boundaries / a new wrapper for one call site → STOP. That's a Counter-propose case, not an Apply. Apply the LOC-negative version and explain in the reply.
```

- [ ] **Step 7: Verify**

Run: `wc -l skills/babysit-pr/SKILL.md` — expect 200–203 lines (was 201). The replacements roughly net out.

Run: `grep -c "Counter-propose\|Counter-proposed\|counter-propose" skills/babysit-pr/SKILL.md` — expect ≥3 (table row, template, red flag).

- [ ] **Step 8: Commit**

```bash
git add skills/babysit-pr/SKILL.md
git commit -m "$(cat <<'EOF'
babysit-pr: add Counter-propose triage bucket

Replaces the two-bucket Apply/Decline table with three buckets. The
new Counter-propose bucket handles the case where a finding is real
but the proposed remedy adds defensive branches, fallback chains,
type checks outside trust boundaries, or a wrapper for one call site.
Apply the LOC-negative version and explain in the reply.

The cost is conditionals + special cases that calcify, not just LOC.
Each calcified branch survives every future refactor.

Drops the "Applied with scope expansion" template (subsumed by the
new Counter-proposed template) and adds a red flag for catching
verbatim applies of bloat-y remedies.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Push and open the vibe-engineering PR

- [ ] **Step 1: Push**

```bash
cd ~/Hacking/vibe-engineering
git push -u origin feat/anti-bloat-mistakes-seed
```

- [ ] **Step 2: Open the PR, linking the kw-reviewer PR from Task 5**

```bash
gh pr create --title "anti-bloat: seed mistakes + add Counter-propose triage to babysit-pr" --body "$(cat <<'EOF'
## Summary

- Seeds `COMMENT_REVIEW_MISTAKES.md` with 5 explicit anti-bloat patterns observed across cncorp/plow PRs 544 / 546 / 552 (entries 6–10). Each suppresses a class of bot finding that proposes adding defensive branches, fallback chains, type validation outside boundaries, wrappers for one call site, or streaming rewrites for theoretical perf.
- Replaces the babysit-pr two-bucket Apply/Decline triage with a three-bucket Apply / Counter-propose / Decline. Counter-propose lets babysit-pr push back on bloat-y remedies *at apply-time* by applying the LOC-negative version and explaining in the reply.

The cost being managed is **conditionals + special cases + defensive branches** — LOC is a stand-in for those. Each calcified branch survives every future refactor and shapes the next change.

Pairs with the kw-reviewer-side changes in <kw-reviewer PR URL>.

## Test plan

- [ ] `~/.claude/COMMENT_REVIEW_MISTAKES.md` synced and visible to the next review's `standards.md` assembly
- [ ] Live observation on the next 1-2 active PRs: babysit-pr uses the Counter-propose template at least once when a Copilot/corgea[bot] finding has a bloat-y remedy
- [ ] Two-week follow-up to evaluate whether the seeded mistakes meaningfully reduced inline-comment volume

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Cross-link the PRs**

Edit each PR's body to add a link to the other (`gh pr edit <#> --body "..."`). Both PRs need to land together.

---

## Task 9: Post-merge live-observation watch

After both PRs merge, watch the next 1–2 active PRs in `cncorp/plow` for evidence the changes are firing correctly.

- [ ] **Step 1: Identify the next active PR**

Run: `gh pr list --repo cncorp/plow --state open --limit 5`

- [ ] **Step 2: Read each new bot review and inline comment as it lands**

Specifically check:
- Does the kw-reviewer review propose any of the 5 bloat patterns from the spec? Each surfaced pattern is a calibration miss to debug.
- When a Copilot or corgea[bot] inline comment proposes bloat (defensive guard, type-check, etc.), does babysit-pr's reply use the Counter-propose template?
- Does the critic ever emit `REMEDY-BLOAT`? Visible in the assembled prompts under `~/.pr-reviewer/last-run-scratch/.../critic.md` if you sample.

- [ ] **Step 3: If a pattern slips through, file a `/srosro-memorize` on the offending PR**

That feeds the existing learning loop. The seeded mistakes are a starting point; the auto-tune mechanism extends them.

- [ ] **Step 4: Two-week follow-up**

Schedule a check-in via `/schedule` for ~2 weeks out: review whether scope creep has measurably dropped on the PRs that landed in the interim. If not, revisit Rule 8's wording — soft framing under-fires; sharpen the bans.
