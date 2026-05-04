# Simplify-at-all-costs review priority — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tighten the canonical Broken-Glass standard and the per-repo `.knightwatch/review-priority.md` operating points so every reviewer round is biased toward LOC-down. Add a worked PR#47→#50 example so future specialists ground "subtractive remedies are higher leverage" in a real instance, not abstract guidance.

**Architecture:** Uses the existing seam — every specialist prompt reads `.codex-scratch/review-priority.md` first via `prompts/common-header.md` Rule 0, and `review-priority.md` cites the canonical `CODING_STANDARDS.md` § Broken-Glass Test. We do NOT touch `prompts/*.md` or any orchestrator/runtime code in this plan; we strengthen the **content** the existing seam delivers. Subtractive-priority becomes load-bearing in two layers (canonical standards + per-repo operating point), with a smoke test pinning the new tokens.

**Tech Stack:** Markdown edits only. Verification via `just test` (knightwatch-reviewer's `prompt-contracts-smoke.sh` token-presence fences) and a replay against PR #47 R5 to confirm the new operating-point content actually surfaces in posted reviews.

**Background:** Conversation thread `2026-05-04` — PR #47 (`feat: probes-as-unit refactor`) burned 23 review rounds and 32 hours growing to +2272 LOC for a "simplification" goal, then closed unmerged. PR #50 shipped the substrate replacement (delete bash orchestration, replace with one Python file) in 8 hours. The bot's standards already say "LOC is a cost, not a feature" but `.knightwatch/review-priority.md` files don't propagate the priority strongly enough — review-priority's "Cultural emphasis" line says *"SIMPLIFY and FAIL LOUDLY — same as everywhere"* without naming subtraction-as-default or citing a worked example.

**Out of scope:** Changes to `prompts/*.md`, the aggregator finding-cap (separate plan: `2026-05-04-aggregator-finding-cap.md`), per-repo updates beyond `vibe-engineering` and `srosro/knightwatch-reviewer` (the other 5 tracked repos get follow-up PRs once this lands and the template proves out).

---

## Branch setup

This plan touches two repos. Per the user's global `NO worktrees, ever` rule, work on feature branches in the existing sibling checkouts (NOT in worktrees).

- [ ] **Step 0a: Create knightwatch-reviewer branch off main**

```bash
cd ~/Hacking/knightwatch-reviewer4
git fetch origin
git checkout -b feat/simplify-at-all-costs origin/main
git status   # confirm clean tree
```

- [ ] **Step 0b: Create vibe-engineering branch off main**

```bash
cd ~/Hacking/vibe-engineering
git fetch origin
git checkout -b feat/simplify-at-all-costs origin/main
git status
```

---

## Task 1: Strengthen § Broken-Glass Test in canonical standards

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` — § Broken-Glass Test (existing section)

The section already exists and already contains the contrast pairs and 20-LOC threshold. We're adding a **subtractive-by-default opening clause** + a **worked PR#47→#50 example** + reframing the "Decline as last resort" subsection to lead with "look for the deletion."

- [ ] **Step 1.1: Read the current Broken-Glass section to confirm structure**

```bash
cd ~/Hacking/vibe-engineering
grep -n '^### \|^## Broken-Glass' claude-config/CODING_STANDARDS.md
```

Expected: `## Broken-Glass Test`, then subsections `### Voice posture`, `### Question template`, `### Universal contrast pairs`, `### Worked-example reframings`, `### 20-LOC remedy threshold`, `### Decline as last resort`.

- [ ] **Step 1.2: Add the subtractive-by-default opening clause**

In `claude-config/CODING_STANDARDS.md`, find the paragraph that starts `The reviewer's job is to catch real bugs and push for elegant code that lets the team validate the product.` Add a new paragraph immediately after the existing `**Source of truth:**` paragraph and before `### Voice posture: questions over prescriptions`:

```markdown
### Subtractive remedies are higher-leverage than additive ones

At any severity, a remedy that reduces LOC is higher-leverage than one that adds LOC. The asymmetry is structural, not stylistic:

- **Additive remedies pay rent.** Every new branch / guard / helper / abstraction has to be maintained, understood, and reasoned about by every later change. A `+30 LOC` validation guard for a scenario that hasn't fired isn't free; it's a calcified branch the next refactor has to preserve.
- **Subtractive remedies don't have a "failure mode not observed" argument** — code that gets *smaller* doesn't introduce new failure modes, it removes them. The pre-PMF lens drops additive remedies whose failure mode isn't observed; it doesn't have anything to drop on the subtractive side.
- **Cumulative additive LOC across review rounds is the structural-failure signal.** When a reviewer has been requesting +20 LOC per round for 5 rounds, the substrate is the problem. Stop adding. Ask what to delete.

When in doubt, surface and apply the LOC-negative remedy. Counter-propose the LOC-negative version of an additive one. Decline only as last resort. *This is just `Anti-Bloat` and `Concise Code` propagated forward — every line earns its place, and a line you can delete didn't earn its place yet.*
```

- [ ] **Step 1.3: Add the PR#47→#50 worked example**

In the same file, find `### Worked-example reframings` and append a new worked example at the end of the section (after the existing `Demand for layer-by-layer regression tests` example):

````markdown
**Substrate replacement reframing — `srosro/knightwatch-reviewer#47` → `#50`** — declarative version of what should have surfaced earlier: *"The 4 bash files implementing the orchestration pipeline (orchestrate.sh + critic-splitter.sh + run-specialist.sh + prompt-build.sh, ~530 LOC combined) drive 5+ rounds of byte-level parser bugs each PR; the substrate is the source of the recurring class."* Reframed as a question with the deletion named:

> Will we keep paying parser-bug iteration cost on this 4-file bash splitter, or is the right move to collapse the substrate? A single `lib/pipeline.py` (~430 LOC, stdlib only, no external splitter parsing) does the same job and retires the byte-level parser bug class. **Net delta: −100 LOC + one fewer parsing seam.** If the answer is "we keep iterating on bash," consider cutting the next round of parser-validation findings — they add complexity and make PMF iteration harder for a substrate we're already planning to replace.

PR #47 grew to +2272 LOC across 23 rounds defending the 4-file bash substrate; PR #50 shipped the substrate replacement at net −20 LOC in 8 hours and merged. The reviewer pushing for "more validation, more fail-loud guards, more fence tests" round-after-round was *correct on each individual finding* — and *wrong on the structural ask*. The signal was visible from round 5 (cumulative additive remedies ≥ 100 LOC) but never surfaced because no specialist's mandate covers "this whole subsystem could be smaller in a different shape."

Lesson: **when cumulative additive LOC across rounds gets large and no leaf finding retires the class, ask what to delete, not what to add.**
````

- [ ] **Step 1.4: Reframe § Decline as last resort to lead with deletion**

In the same file, find `### Decline as last resort (look for the simpler shape first)`. The existing section already says "Look for the simpler shape first" — strengthen the opening question. Replace:

```markdown
**Is there a refactor that addresses the underlying concern AND simplifies existing code?**
```

with:

```markdown
**Is there a deletion that retires the concern entirely?** If yes, that's the move — a refactor of *existing* code that absorbs the concern and removes complexity beats any additive remedy. Subtraction is the highest-leverage answer to a finding; the bot's job isn't just to push back on additive complexity, it's to surface the deletion that makes the concern moot.

If no deletion retires the concern, then ask the next-best question: **is there a refactor that addresses the underlying concern AND simplifies existing code?**
```

- [ ] **Step 1.5: Verify the file still renders cleanly**

```bash
cd ~/Hacking/vibe-engineering
# Markdown is forgiving; this is a lint-equivalent check
grep -c "^## Broken-Glass Test" claude-config/CODING_STANDARDS.md
```

Expected: `1` (we added subsections, didn't add a new top-level section).

- [ ] **Step 1.6: Commit**

```bash
cd ~/Hacking/vibe-engineering
git add claude-config/CODING_STANDARDS.md
git commit -m "$(cat <<'EOF'
feat(standards): subtractive-by-default in Broken-Glass Test

Adds an explicit "subtractive remedies are higher-leverage" subsection
to § Broken-Glass Test, plus a worked PR#47→#50 example showing the
substrate-replacement move that the existing prompts couldn't surface.
Reframes § Decline as last resort to lead with the deletion question.

Why: PR #47 grew to +2272 LOC across 23 rounds defending a 4-file
bash substrate that PR #50 deleted in one move. The standards already
said "LOC is a cost" but the operating point read by every specialist
didn't have a worked example to ground subtractive-priority in. This
adds the example and makes the policy load-bearing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Cross-reference the new policy from REVIEW_PRACTICES.md

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/REVIEW_PRACTICES.md`

`REVIEW_PRACTICES.md` is the operational counterpart to `CODING_STANDARDS.md`. It already has `## Concise Code` and `## Approval Verdicts` sections. Add a one-line pointer at the top of `## Concise Code` so reviewers reading practices land on the standard.

- [ ] **Step 2.1: Locate the Concise Code section**

```bash
cd ~/Hacking/vibe-engineering
grep -n '^## Concise Code' claude-config/REVIEW_PRACTICES.md
```

- [ ] **Step 2.2: Add the cross-reference at the top of § Concise Code**

In `claude-config/REVIEW_PRACTICES.md`, immediately under the `## Concise Code` header, insert:

```markdown
> **Subtractive-by-default.** See `CODING_STANDARDS.md` § Broken-Glass Test § Subtractive remedies are higher-leverage than additive ones for the operating principle. The bullet list below is the operational translation.
```

- [ ] **Step 2.3: Commit**

```bash
git add claude-config/REVIEW_PRACTICES.md
git commit -m "$(cat <<'EOF'
docs(practices): cross-reference subtractive-by-default policy

Adds a pointer from REVIEW_PRACTICES.md § Concise Code to the new
canonical Broken-Glass subsection so practices-readers land on the
worked example instead of inferring it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Tighten vibe-engineering's own `.knightwatch/review-priority.md`

**Files:**
- Modify: `~/Hacking/vibe-engineering/.knightwatch/review-priority.md`

Self-review case: vibe-engineering reviews PRs against itself. Its `review-priority.md` already exists; tighten the cultural-emphasis line and add a repo-specific contrast pair that cites the new subtractive-priority policy.

- [ ] **Step 3.1: Read the current file**

```bash
cd ~/Hacking/vibe-engineering
cat .knightwatch/review-priority.md
```

- [ ] **Step 3.2: Tighten the Cultural emphasis line**

In `.knightwatch/review-priority.md`, find the line that starts `**Cultural emphasis:** SIMPLIFY and FAIL LOUDLY — same as everywhere.` Replace with:

```markdown
**Cultural emphasis:** SIMPLIFY at all costs — complexity kills PMF iteration. Subtractive remedies (delete, collapse, retire) are higher-leverage than additive ones at any severity; cumulative additive LOC across review rounds is the structural-failure signal. See `claude-config/CODING_STANDARDS.md` § Broken-Glass Test § Subtractive remedies are higher-leverage than additive ones for the canonical policy + worked PR#47→#50 example. Cascade risk is the dominant axis here; favor precise, falsifiable rules over vague guidance.
```

- [ ] **Step 3.3: Add a repo-specific contrast pair**

In the same file, find the `**Repo-specific review emphasis:**` bullet list. Append a new bullet:

```markdown
- **Standards-file edits that ADD prescription text are higher-bar than edits that delete it.** Adding "the reviewer must also check X" calcifies a branch every PR review must execute thereafter. Deleting a stale rule, collapsing two redundant rules into one, or replacing a prescriptive list with an inquisitive question is net-leverage-positive. When in doubt, ask what the standards file would look like with this rule removed; if it would still hold up, the addition isn't earning its place.
```

- [ ] **Step 3.4: Commit**

```bash
git add .knightwatch/review-priority.md
git commit -m "$(cat <<'EOF'
chore(knightwatch): tighten review-priority — simplify at all costs

Names subtractive-priority and cumulative-additive-LOC as the
structural-failure signal. Adds a repo-specific contrast pair for
standards-file edits (adding prescription text is higher-bar than
deleting it).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 3.5: Verify smoke + push branch**

```bash
cd ~/Hacking/vibe-engineering
just test    # runs ./smoke-install.sh — symlink layout sanity, no content fences here
git push -u origin feat/simplify-at-all-costs
```

---

## Task 4: Tighten knightwatch-reviewer's own `.knightwatch/review-priority.md`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/.knightwatch/review-priority.md`

Same pattern as Task 3. The existing file has its own contrast-pair table for "Architecture bloat — DON'T (in this repo)" vs "Bugfix — DO". Tighten the cultural-emphasis line and add a row to the table that names cumulative-additive-LOC as a trigger.

- [ ] **Step 4.1: Read the current file**

```bash
cd ~/Hacking/knightwatch-reviewer4
cat .knightwatch/review-priority.md
```

- [ ] **Step 4.2: Tighten the Cultural emphasis line**

In `.knightwatch/review-priority.md`, find the line `**Cultural emphasis:** SIMPLIFY and FAIL LOUDLY — same as everywhere.` Replace with:

```markdown
**Cultural emphasis:** SIMPLIFY at all costs — complexity kills PMF iteration. Subtractive remedies (delete, collapse, retire) are higher-leverage than additive ones at any severity. Cumulative additive LOC across review rounds is the structural-failure signal — when the bot has been requesting +20 LOC per round for 3+ rounds, the substrate is the problem; stop adding and look for the deletion that retires the class. Prompt-engineering changes here cascade into every PR review across every tracked repo; favor precise, falsifiable rules over vague guidance. The universal Broken-Glass posture lives in `standards.md` § Broken-Glass Test — apply that here, including the worked PR#47→#50 substrate-replacement example.
```

- [ ] **Step 4.3: Add a contrast-pair row for cumulative additive LOC**

In `.knightwatch/review-priority.md`, find the contrast-pair table (`| Architecture bloat — DON'T (in this repo) | Bugfix — DO |`). Append a new row:

```markdown
| Continue iterating with additive remedies on a refactor PR whose cumulative additive LOC across rounds has crossed +100 (probe-as-unit PR#47 dynamic). | Surface the substrate-replacement move that retires the recurring bug class — net-LOC-down beats five rounds of net-LOC-up parser fixes. |
```

- [ ] **Step 4.4: Commit**

```bash
cd ~/Hacking/knightwatch-reviewer4
git add .knightwatch/review-priority.md
git commit -m "$(cat <<'EOF'
chore(knightwatch): tighten review-priority — subtractive-by-default

Names subtractive-priority + cumulative-additive-LOC trigger as the
structural-failure signal. Adds a contrast-pair row that cites PR#47
dynamics directly so future reviewer rounds have a concrete anchor for
"stop adding, look for the deletion."

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4.5: Anchor `prompts/simplification.md` on inferred-intent for refactor PRs

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/prompts/simplification.md`

**Rationale:** `common-header.md` (prepended to every specialist by `lib/pipeline.py:166`) already lists `inferred-intent.md` as an input and explicitly names "the architecture and **simplification** specialists in particular should ask: does the chosen implementation deliver on that intent?" But `simplification.md`'s own body never re-anchors on intent the way `architecture.md` and `shape.md` do. PR #47's stated intent was simplification ("consolidate findings + open questions into a single probe data type"); the diff was net-additive +862 LOC by R5; if `simplification.md` had been actively grading-against-stated-intent, it would have been the natural seam to surface "you stated simplify; you're net-additive; what would you delete to honor the stated intent?"

This task plugs the asymmetry. Small targeted edit, one assertion in the smoke (folded into Task 5), no behavior change for non-refactor PRs.

- [ ] **Step 4.5.1: Read the current top of simplification.md**

```bash
cd ~/Hacking/knightwatch-reviewer4
head -20 prompts/simplification.md
```

Confirm the file opens with `**Your angle: Simplification, DRY, and code-quality smells.**` followed by the `FIRST, read .codex-scratch/prior-art.md...` paragraph.

- [ ] **Step 4.5.2: Insert the intent-anchoring clause**

Use the Edit tool. Find:

```markdown
**Your angle: Simplification, DRY, and code-quality smells.**

FIRST, read `.codex-scratch/prior-art.md`. That's the output of `kid` — a semantic-similarity search that identifies blocks in *this PR's diff* that resemble existing code in the repo.
```

Replace with:

```markdown
**Your angle: Simplification, DRY, and code-quality smells.**

**FIRST — for refactor PRs only — grade the diff against stated intent.** Read `.codex-scratch/inferred-intent.md`. If it names a simplification / DRY / consolidation / refactor goal AND the diff is net-additive >100 LOC, that's a load-bearing finding for your angle — emit a `Class: complexity-cost` probe at `Severity if yes: blocking` naming the deletion (of *existing* code, not just the new additions) that would honor the stated intent. The substrate is often the source of the complexity that drives net-additive "simplification" PRs; surface that here, not in a momentum/loop-breaker round 5+. The probe's `If yes, edit:` clause must name a specific deletion target with file paths + LOC delta, not just "consider simplifying."

THEN, read `.codex-scratch/prior-art.md`. That's the output of `kid` — a semantic-similarity search that identifies blocks in *this PR's diff* that resemble existing code in the repo.
```

- [ ] **Step 4.5.3: Verify the file still opens cleanly**

```bash
head -10 prompts/simplification.md
```

Confirm the new opening reads logically, the existing `kid is noisy` paragraph still flows from the THEN clause, and no markdown got mangled.

- [ ] **Step 4.5.4: Commit**

```bash
git add prompts/simplification.md
git commit -m "$(cat <<'EOF'
feat(simplification): anchor on inferred-intent for refactor PRs

Adds an opening clause to simplification.md that grades the diff
against stated intent for refactor / DRY / consolidation PRs. When
intent claims simplification and the diff is net-additive >100 LOC,
emit a complexity-cost probe naming the deletion of existing code
that would honor the intent.

Why: common-header.md already names "the architecture and simplification
specialists in particular should ask: does the chosen implementation
deliver on that intent?" but simplification.md's body never re-anchored
the way architecture.md and shape.md do. PR #47's stated intent was
simplification; by R5 the diff was +862 LOC. The substrate-replacement
finding (which PR #50 ultimately shipped) had no specialist seam to
surface from. This adds the seam.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Add a smoke fence pinning the new tokens

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/lib/tests/prompt-contracts-smoke.sh`

Mirror the existing `assert_grep` pattern. The fence catches "someone deletes the cultural-emphasis tightening on a future cleanup pass" — a regression class the existing K-decay paired-token fences already handle for other prompts.

- [ ] **Step 5.1: Read the existing fence pattern**

```bash
cd ~/Hacking/knightwatch-reviewer4
grep -n "assert_grep" lib/tests/prompt-contracts-smoke.sh | head -10
```

Note the `assert_grep "<label>" "<pattern>" "<file>"` signature.

- [ ] **Step 5.2: Append a new section**

Add at the end of `lib/tests/prompt-contracts-smoke.sh`, before the final exit-success line:

```bash
# ====================================================================
# Section: subtractive-priority tokens (added 2026-05-04)
# ====================================================================
# Pins the subtractive-by-default tightening in this repo's
# .knightwatch/review-priority.md and the canonical worked example in
# the consumed standards. If these tokens drift away, every specialist
# loses the operating-point signal that drives PR#47-style structural
# loops to surface the substrate-replacement move.

echo "  asserting subtractive-priority tokens in .knightwatch/review-priority.md..."
assert_grep "review-priority.md should name SIMPLIFY at all costs" \
    "SIMPLIFY at all costs" .knightwatch/review-priority.md
assert_grep "review-priority.md should cite cumulative additive LOC" \
    "Cumulative additive LOC" .knightwatch/review-priority.md
assert_grep "review-priority.md should cite the canonical Broken-Glass section" \
    "Broken-Glass Test" .knightwatch/review-priority.md

echo "  asserting simplification.md anchors on inferred-intent for refactor PRs..."
assert_grep "simplification.md should grade diff against stated intent" \
    "grade the diff against stated intent" prompts/simplification.md
assert_grep "simplification.md should call out net-additive refactor PRs" \
    "net-additive >100 LOC" prompts/simplification.md
```

- [ ] **Step 5.3: Run the smoke**

```bash
just test 2>&1 | grep -A2 "prompt-contracts" | head -10
```

Expected: `prompt-contracts-smoke.sh ... PASS` (or the equivalent line — the smoke prints `OK` if all assertions pass).

If FAIL: re-read the assertion, confirm the pattern matches the actual file content with `grep -F "<pattern>" .knightwatch/review-priority.md`, fix the prompt or the assertion.

- [ ] **Step 5.4: Commit**

```bash
git add lib/tests/prompt-contracts-smoke.sh
git commit -m "$(cat <<'EOF'
test(prompt-contracts): pin subtractive-priority tokens

Adds a token-presence fence so a future cleanup pass can't silently
delete the SIMPLIFY-at-all-costs tightening from
.knightwatch/review-priority.md. Pattern mirrors the existing
assert_grep style — pins token presence, not literal prose, per
Rule 8's prose-pinning prohibition.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Replay PR #47 R5 against the new operating point

This is the behavioral verification: given the same PR #47 R5 inputs as the original review, does the new operating-point content actually shift what the bot surfaces?

**Files:**
- Read-only: existing replay harness `lib/tests/replay/` + `replay.sh` if present, OR the per-run scratch dirs on `wakeup`.

This task documents the verification protocol; no commits expected unless the replay reveals the smoke is wrong.

- [ ] **Step 6.1: Locate the replay entrypoint**

```bash
cd ~/Hacking/knightwatch-reviewer4
ls lib/tests/replay/ 2>/dev/null
# OR
find . -maxdepth 3 -name "replay*" -not -path "./.git/*" 2>/dev/null
```

If a replay harness exists at `replay.sh` or `lib/replay.sh`, that's the entrypoint. PR #48's commit `70389bf feat(replay): live-GH-lookup replay harness for any OSS PR (#48)` added it.

- [ ] **Step 6.2: Replay PR #47 R5**

Pick a SHA from PR #47 around R5 (~2026-05-02 22:30 UTC, after the per-line attribution + AI-author callout landed but before the validator stack was deeply layered):

```bash
# Replay against srosro/knightwatch-reviewer#47 at the R5 head commit.
# Use the replay harness's documented invocation; if unsure, read its --help.
./replay.sh srosro/knightwatch-reviewer 47 --at-sha <R5-sha>
```

The R5 SHA can be looked up via:

```bash
gh pr view 47 --repo srosro/knightwatch-reviewer --json commits \
    --jq '.commits[] | select(.committedDate < "2026-05-02T23:00:00Z" and .committedDate > "2026-05-02T22:00:00Z") | .oid' | tail -1
```

- [ ] **Step 6.3: Inspect the replay output**

The replay produces an aggregator-rendered review that goes to a temp file, NOT to GitHub (replay harness is read-only on output). Read that file and check:

1. Does any specialist (especially `simplification` or `shape`) cite the substrate-replacement framing — i.e., a probe whose `If yes, edit:` clause names a deletion ≥50 LOC?
2. Does the `momentum` specialist's prose cite the cumulative-additive-LOC trigger or the worked PR#47→#50 example?
3. Does the aggregator's Probes block surface the substrate finding within the top 3 (subtractive ranks above additive within band, per the Broken-Glass strengthening)?

Expected: at least one of (1)/(2)/(3) shifts vs. the original R5 review (visible in `prior-reviews.md` from the wakeup deploy). If NONE shift, the operating-point tightening isn't reaching the specialists — investigate Rule 0 / common-header citation chain before claiming the fix lands.

- [ ] **Step 6.4: Document the replay outcome in the PR description**

When opening the PR (Task 7), include the replay diff in the PR description:

```markdown
## Replay verification

Ran the replay harness against PR #47 R5 with the new operating point. Diff vs. the historical R5 review:

| Layer | Original R5 | Replayed R5 (new operating point) |
|---|---|---|
| Top-of-band finding | "add probe_validate enum check (+30 LOC)" | <new top finding> |
| Momentum prose | (not yet present at R5) | <new momentum text or "n/a — no prior_reviews"> |
| Substrate finding present? | No | <Yes/No + cite> |
```

If the replay can't run locally (needs `wakeup`-side codex + gh state), document that as a gap and mark Step 6 as "verified manually against deployed bot's first review on the open feat/simplify-at-all-costs PR."

---

## Task 7: Open PRs

- [ ] **Step 7.1: Push knightwatch-reviewer branch**

```bash
cd ~/Hacking/knightwatch-reviewer4
git push -u origin feat/simplify-at-all-costs
```

- [ ] **Step 7.2: Open PR**

```bash
gh pr create --title "feat(knightwatch): simplify-at-all-costs review priority + smoke fence" \
    --body "$(cat <<'EOF'
## Summary

- Tightens `.knightwatch/review-priority.md` to name SIMPLIFY-at-all-costs as the cultural emphasis and cumulative-additive-LOC across rounds as the structural-failure signal.
- Adds a contrast-pair row citing PR#47 dynamics so future reviewer rounds have a concrete anchor.
- Adds a token-presence smoke fence to `prompt-contracts-smoke.sh` pinning the new tokens.

## Companion PR

`vibe-engineering/feat/simplify-at-all-costs` — strengthens the canonical Broken-Glass standard with a subtractive-by-default subsection + the worked PR#47→#50 example. Land that first; this PR cites it.

## Replay verification

<paste the replay table from Task 6.4>

## Test plan

- [x] `just test` passes locally
- [ ] Open this PR; confirm the bot's first review on _this_ PR uses the new operating point (look for "SIMPLIFY at all costs" or substrate-replacement framing in the bot's R1 surfaced findings)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7.3: Push vibe-engineering branch + open PR**

```bash
cd ~/Hacking/vibe-engineering
git push -u origin feat/simplify-at-all-costs
gh pr create --title "feat(standards): subtractive-by-default + PR#47→#50 worked example" \
    --body "$(cat <<'EOF'
## Summary

- Adds § Subtractive remedies are higher-leverage than additive ones to § Broken-Glass Test.
- Adds the PR#47→#50 substrate-replacement worked example.
- Reframes § Decline as last resort to lead with the deletion question.
- Cross-references the new policy from REVIEW_PRACTICES.md § Concise Code.
- Tightens vibe-engineering's own `.knightwatch/review-priority.md`.

## Companion PR

`srosro/knightwatch-reviewer/feat/simplify-at-all-costs` — propagates the same tightening to that repo's operating-point file + adds a smoke fence.

## Test plan

- [x] `just test` (smoke-install) passes locally
- [ ] After merge: confirm next review across any tracked repo cites the new operating-point content

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 7.4: After both PRs land, run /babysit-pr on each**

Per `~/.claude/CLAUDE.md` § Branch Workflow, do not auto-merge — invoke `/babysit-pr <PR#>` on each PR and let the human make the merge call.

---

## Task 8: Follow-up template (out of plan, document only)

The other 5 tracked repos with `.knightwatch/review-priority.md` files (`cncorp/plow`, `cncorp/plow-content`, `srosro/tkmx-client`, `srosro/tkmx-server`, `plow-pbc/watchmepivot`) get the same Cultural-emphasis tightening as Task 3/Task 4 in follow-up PRs. The pattern:

1. Branch off main: `git checkout -b chore/simplify-at-all-costs-priority`
2. Replace the `**Cultural emphasis:**` line with the tightened version from Task 3.2 (drop the "Cascade risk is the dominant axis here" clause — that's vibe-engineering-specific; replace with whatever the repo's existing emphasis was).
3. Add a repo-specific contrast pair under `**Repo-specific review emphasis:**` that names what additive-vs-subtractive looks like in *that repo's* context (e.g. for `cncorp/plow`, "Adding a new SwiftUI view to address a finding is higher-bar than collapsing two existing ones" — substitute the repo's actual common patterns).
4. No smoke fence needed (per-repo files don't have token presence smokes — the fence in Task 5 only covers knightwatch-reviewer's file because that repo has the test infrastructure).
5. PR per repo. Each is a small chore/doc commit.

These 5 follow-up PRs are **not part of this plan**. Track them separately when the canonical PRs (Task 7) land.

---

## Self-review checklist

Run after writing every task:

- [ ] Spec coverage: every "thrust" the user named is covered. Subtractive-priority canonical → Task 1. Worked example → Task 1.3. Per-repo operating point → Tasks 3+4. Simplification specialist intent-anchoring → Task 4.5. Smoke fence → Task 5. Replay verification → Task 6. Other repos → Task 8 (out of scope, documented).
- [ ] Placeholder scan: no TBD, no "appropriate", no "similar to Task N" without code.
- [ ] Type consistency: filenames + paths consistent across tasks (`prompt-contracts-smoke.sh` not `prompt-contract-smoke.sh`; `.knightwatch/review-priority.md` not `review_priority.md`).
- [ ] Commit messages follow conventional style + include the `Co-Authored-By` trailer per `~/.claude/CLAUDE.md`.
- [ ] No worktree creation anywhere (per global rule).
