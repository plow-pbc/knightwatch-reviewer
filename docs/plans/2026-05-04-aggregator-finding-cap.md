# Aggregator finding cap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the aggregator's "drop nits when 3+ stronger probes" cull rule with a diff-size-aware cap `N = min(15, 3 + LOC_of_diff / 100)`. All blocking + medium + open probes always surface; the cap applies only to the low/nit band. Prevents valid findings from being culled in R1 only to re-surface in R2/R3, a major contributor to PR #47's review-loop dynamic.

**Architecture:** Single-file edit to `prompts/aggregator.md` step 3 (cull rule) + step 7 (length contract). Plus a smoke fence in `lib/tests/prompt-contracts-smoke.sh` pinning the new tokens. No new mechanics, no orchestrator changes — the LOC-of-diff number is already available to the aggregator via `.codex-scratch/diff.patch` (or via `loc-trend.md` which the aggregator already reads).

**Tech Stack:** Markdown edits + one bash smoke section. Verification via replay against PR #47 R1 (1400-LOC diff → N=15 → would surface ~10 more findings than the original R1).

**Background:** Conversation thread `2026-05-04` — user named the dynamic that valid findings get culled in R1 only to re-surface in R2/R3, contributing to the multi-round-loop failure mode. Today's policy (`prompts/aggregator.md` step 3): *"It is correct to drop nits if there are ≥3 stronger probes — a short review is better than a padded one."* Plus step 7's *"300-500 words for typical PRs"* word-count target. Both rules cull more aggressively as the PR gets bigger, exactly the opposite of what review quality requires.

**Out of scope:** LOC-direction-as-first-class subtractive vs additive ranking (separate plan: `2026-05-04-simplify-at-all-costs.md`). Ship that first — it makes culling smarter; this plan makes culling rarer. Reverse order surfaces more low-leverage additive findings before the ranking learns to demote them.

---

## Branch setup

Per the user's global `NO worktrees, ever` rule, work on a feature branch in the existing checkout.

- [ ] **Step 0: Create feature branch off main**

```bash
cd ~/Hacking/knightwatch-reviewer4
git fetch origin
# Recommended: branch off the head of feat/simplify-at-all-costs once that
# lands, so this PR sits cleanly on top. If that PR is still open, branch
# off origin/main and rebase later.
git checkout -b feat/aggregator-finding-cap origin/main
git status   # confirm clean tree
```

---

## Task 1: Replace step 3 cull rule in `prompts/aggregator.md`

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/prompts/aggregator.md` (step 3, currently the "Drop probes that are weak..." paragraph)

The existing step 3 is one paragraph that mixes three concerns: drop weak/duplicative probes, drop nits when there are 3+ stronger probes, and prefer short reviews. We're replacing the second concern (the count-based nit cull) with a diff-size-aware cap, leaving the other two intact.

- [ ] **Step 1.1: Read the current step 3 to confirm exact wording**

```bash
cd ~/Hacking/knightwatch-reviewer4
sed -n '/^3\. Drop probes/,/^4\./p' prompts/aggregator.md
```

Expected output:

```
3. Drop probes that are weak, duplicative, or that a reader would score as "not worth mentioning." Quality over volume. It is correct to drop nits if there are ≥3 stronger probes — a short review is better than a padded one.
4. Specialists output a "Surveyed" section even when they have no probes. ...
```

- [ ] **Step 1.2: Replace step 3 with the diff-size-aware cap**

Use the Edit tool. Replace:

```markdown
3. Drop probes that are weak, duplicative, or that a reader would score as "not worth mentioning." Quality over volume. It is correct to drop nits if there are ≥3 stronger probes — a short review is better than a padded one.
```

with:

```markdown
3. **Probe budget — diff-size-aware cap, ceiling-not-floor.** Compute `N = min(15, 3 + LOC_of_diff / 100)` where `LOC_of_diff` is the additions+deletions count from `.codex-scratch/diff.patch` (read it directly: `grep -cE '^[+-][^+-]' .codex-scratch/diff.patch`). N caps the number of `Answer: yes` probes surfaced in the **Probes** block, but **bands govern what's cullable**:

   - Surface ALL `Answer: yes` blocking and medium probes regardless of N. These are the load-bearing concerns; culling them just defers the same probe to R2.
   - Surface ALL `Answer: unknown` (open-question) probes regardless of N. These are the questions the author MUST answer for the bot to converge; culling them just regenerates them next round.
   - Apply N as a **ceiling** on the `Answer: yes` low/nit band only. If `(blocking + medium + unknown) >= N`, surface zero low/nits this round. If fewer, fill the remaining slots with the highest-leverage low/nits (per step 2's intra-band ranking).

   **Within the low/nit cap, prefer specialist diversity over depth.** When low/nit probes exceed the available slots, prefer one finding per specialist over multiple from the same specialist — a `[low] [from: tests]` + `[low] [from: simplification]` + `[low] [from: shape]` beats three `[low] [from: simplification]` because diversity carries more signal.

   **Ceiling, not floor — never pad to hit N.** If you have fewer than N valid `Answer: yes` low/nits, surface what you have. Padding the review with manufactured nits actively harms it; the goal is to stop *culling* good findings, not to produce a longer review for its own sake.

   Drop probes that are weak, duplicative, or that a reader would score as "not worth mentioning." Quality still beats volume — N is the cap on culling, not a quota.
```

- [ ] **Step 1.3: Verify step 3 still parses as a numbered list**

```bash
sed -n '/^3\. /,/^4\. /p' prompts/aggregator.md | head -20
```

Expected: the new step 3 followed by `4. Specialists output a "Surveyed" section...` — confirm the numbering is intact and step 4 wasn't accidentally merged in.

---

## Task 2: Update step 7 length contract

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/prompts/aggregator.md` (step 7, the "Target 300-500 words for typical PRs..." paragraph)

The existing word-count target conflicts with the new cap on bigger diffs (a 1000-LOC PR with N=13 will produce a >500-word review). Reframe the length contract to be per-finding rather than total-word-count.

- [ ] **Step 2.1: Locate step 7's length sentence**

```bash
cd ~/Hacking/knightwatch-reviewer4
grep -n "300-500 words" prompts/aggregator.md
```

- [ ] **Step 2.2: Replace the length sentence**

In step 7, find:

```
Target 300-500 words for typical PRs. For large diffs (>500 KB) or PRs with many substantive probes, you may flex up to 1000 words — but only if the extra length carries real content. Quality over length: don't pad to hit the floor, and don't drop important probes to hit the ceiling. **Step-back signal mode (above) overrides this length contract** — a redirect review is 200-400 words even when the underlying PR has 20 probes, because the redirect is the review.
```

Replace with:

```
**Length scales with N (the probe budget from step 3), not a fixed target.** Per-probe rendering at step 6 averages ~50-80 words per `Answer: yes` probe + ~30-40 per `Answer: unknown` open question; at N=4 (small diff) the review lands in 250-400 words, at N=13 (1000-LOC diff) it lands closer to 800-1100 words. Both are correct — the constraint is per-finding tightness, not total length. Quality still beats volume: don't pad findings with prose to look thorough; one paragraph per probe with file:line cite + `Edit:` clause is the contract. **Step-back signal mode (Path 1 redirect) overrides the N-scaled length** — a redirect review is 200-400 words even on a 5000-LOC PR, because the redirect IS the review. **Path 2 (loop-breaker callout) drops the leaf probes entirely** — the structural callout is the review when momentum fires, regardless of N.
```

- [ ] **Step 2.3: Verify step 7 length contract is internally consistent**

```bash
sed -n '/^7\. Produce the final/,/^8\./p' prompts/aggregator.md | head -40
```

Confirm: step 7 references step 3's N, doesn't conflict with step 5/Path-1 (which keeps its own 200-400 cap), doesn't conflict with the Path-2 leaf-drop behavior in the existing prompt.

---

## Task 3: Add smoke fence pinning the new tokens

**Files:**
- Modify: `~/Hacking/knightwatch-reviewer4/lib/tests/prompt-contracts-smoke.sh`

Add a section that pins the cap formula tokens, the band-protection rule, and the ceiling-not-floor rule. These are load-bearing — if any drift away on a future cleanup pass, the cap behavior degrades silently.

- [ ] **Step 3.1: Append a new section to the smoke**

At the end of `lib/tests/prompt-contracts-smoke.sh`, before the final exit-success line, append:

```bash
# ====================================================================
# Section: aggregator probe-budget cap (added 2026-05-04)
# ====================================================================
# Pins the diff-size-aware cap formula and the band-protection rules.
# If these tokens drift, valid findings get culled silently to hit a
# fixed-count target — the regression class this fence prevents.

echo "  asserting probe-budget cap formula in aggregator.md..."
assert_grep "aggregator.md should compute N from diff size" \
    "N = min(15, 3 + LOC_of_diff / 100)" prompts/aggregator.md

echo "  asserting band protection (blocking always surfaces)..."
assert_grep "aggregator.md should always surface blocking probes" \
    "Surface ALL \`Answer: yes\` blocking and medium probes regardless of N" prompts/aggregator.md

echo "  asserting band protection (open questions always surface)..."
assert_grep "aggregator.md should always surface open-question probes" \
    "Surface ALL \`Answer: unknown\` (open-question) probes regardless of N" prompts/aggregator.md

echo "  asserting ceiling-not-floor rule..."
assert_grep "aggregator.md should forbid padding to hit N" \
    "never pad to hit N" prompts/aggregator.md

echo "  asserting specialist-diversity preference..."
assert_grep "aggregator.md should prefer specialist diversity in low/nit cap" \
    "prefer specialist diversity over depth" prompts/aggregator.md

# Negative fence: the legacy 3-strong-probes rule must NOT remain — that
# was the cull rule replaced by N. If both rules coexist, specialists
# could read the older one and over-cull.
echo "  asserting legacy '3 stronger probes' cull rule was replaced..."
if grep -qF "drop nits if there are ≥3 stronger probes" prompts/aggregator.md; then
    echo "FAIL: aggregator.md still carries the legacy 3-stronger-probes cull rule — it should have been replaced by the N cap"
    exit 1
fi
```

- [ ] **Step 3.2: Run the smoke**

```bash
just test 2>&1 | grep -E "prompt-contracts|FAIL" | head -10
```

Expected: all assertions pass; `prompt-contracts-smoke.sh ... OK` (or equivalent).

If FAIL on the negative fence: re-read `prompts/aggregator.md`, confirm the old `≥3 stronger probes` clause was actually removed in Task 1.2 (it was inside the paragraph being replaced).

If FAIL on a positive assertion: re-check the exact pattern by running `grep -F "<pattern>" prompts/aggregator.md`. The assertions use literal-string match, so the pattern must appear verbatim in the file.

- [ ] **Step 3.3: Commit**

```bash
git add prompts/aggregator.md lib/tests/prompt-contracts-smoke.sh
git commit -m "$(cat <<'EOF'
feat(aggregator): diff-size-aware probe budget cap

Replaces the count-based "drop nits if there are ≥3 stronger probes"
cull rule with N = min(15, 3 + LOC_of_diff / 100). Bands govern what's
cullable: blocking, medium, and open-question probes always surface;
the N cap applies only to the Answer:yes low/nit band. Specialist
diversity preferred over depth within the low/nit cap. Step 7 length
contract reframed to scale with N rather than a fixed word count.

Why: today's policy culls more aggressively as PRs get bigger, the
opposite of what review quality requires. PR #47 dynamics show valid
findings culled in R1 re-surface in R2/R3 and drive the loop. Cap is
ceiling-not-floor — no padding to hit N.

Adds smoke fence pinning the cap formula, band-protection rules, and
ceiling-not-floor token. Negative fence ensures the legacy
3-strong-probes rule was removed, not just appended-around.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replay PR #47 R1 against the new cap

Behavioral verification: PR #47 R1 was a 1400-LOC diff that produced 4 findings (the original review's count). With N=15 the bot should surface up to 15. The question: are there 8-12 *more* valid findings the original culled, and are they the kind of findings whose absence drove subsequent rounds?

**Files:**
- Read-only: existing replay harness + the per-run scratch dirs.

- [ ] **Step 4.1: Locate PR #47 R1 SHA**

```bash
cd ~/Hacking/knightwatch-reviewer4
gh pr view 47 --repo srosro/knightwatch-reviewer --json commits \
    --jq '.commits[] | select(.committedDate < "2026-05-02T20:00:00Z") | .oid' | tail -1
```

R1 fired around 2026-05-02 19:50 UTC; the SHA above is the head commit at that time.

- [ ] **Step 4.2: Replay**

```bash
./replay.sh srosro/knightwatch-reviewer 47 --at-sha <R1-sha>
```

If the replay harness has a different invocation, use `--help` to check.

- [ ] **Step 4.3: Compare finding count + content vs. historical R1**

Open the replayed review's aggregator output and the original R1 review (visible on the PR at `2026-05-02T19:50:45Z`). Compare:

| Layer | Original R1 | Replayed R1 (N cap) |
|---|---|---|
| Total `Answer: yes` findings surfaced | 4 | <expect 8-15> |
| Blocking findings | <count from original> | <should match — bands are protected> |
| Low/nit findings | <count from original, likely 0> | <expect 4-12 new ones> |
| Findings that re-appear in R2/R3 originally | <list 2-3 from PR timeline> | <should appear in replayed R1 instead — that's the proof the cap reduces re-surfacing> |

If the replay surfaces 4 findings exactly (same as original): either (a) PR #47's original R1 already had ≤4 valid findings and the cap is irrelevant for this PR, or (b) the cap isn't being applied. Check (b) first — verify `prompts/aggregator.md`'s new step 3 text is in the replay's prompt context.

If the replay surfaces 15+ findings *and many feel padded*: the cap may be too generous for this repo's diffs; consider tightening to `N = min(12, 2 + LOC_of_diff / 120)` and re-replaying. Document the tuning rationale in the PR description.

- [ ] **Step 4.4: Document the replay outcome**

Capture the table from Step 4.3 in a temp file for the PR description (Task 5).

```bash
# Save a comparison artifact for the PR body
cat > /tmp/replay-comparison.md <<'EOF'
## Replay verification (PR #47 R1)

<paste comparison table here>

**Findings whose deferral to R2/R3 drove the original loop, that R1-with-cap surfaces instead:**
- <finding 1>
- <finding 2>
- <finding 3>

**Cap applied correctly?** Yes / No (with explanation).
EOF
```

---

## Task 5: Open PR

- [ ] **Step 5.1: Push branch**

```bash
cd ~/Hacking/knightwatch-reviewer4
git push -u origin feat/aggregator-finding-cap
```

- [ ] **Step 5.2: Open PR**

```bash
gh pr create --title "feat(aggregator): diff-size-aware probe budget cap" \
    --body "$(cat <<'EOF'
## Summary

- Replaces aggregator step 3's count-based cull rule (`drop nits when 3+ stronger probes`) with a diff-size-aware cap `N = min(15, 3 + LOC_of_diff / 100)`.
- Bands govern what's cullable: ALL blocking + medium + open-question probes always surface; the N cap applies only to the `Answer: yes` low/nit band.
- Step 7 length contract reframed to scale with N (per-probe tightness, not fixed word count).
- Smoke fence in `prompt-contracts-smoke.sh` pins the cap formula, band-protection rules, ceiling-not-floor, and a negative fence on the legacy `3 stronger probes` rule.

## Why

PR #47's review loop was driven in part by valid findings being culled in R1 only to re-surface in R2/R3. The original R1 surfaced 4 findings on a 1400-LOC diff; with N=15 the bot surfaces up to 15. Author addresses more in one push, fewer rounds, less leak-and-resurface.

## Companion change

Land [`feat: simplify-at-all-costs review priority`](LINK-TO-COMPANION-PR) first — it makes culling smarter (subtractive ranks above additive within band). Reverse order surfaces low-leverage additive findings before the ranking learns to demote them.

<paste /tmp/replay-comparison.md content here>

## Test plan

- [x] `just test` passes locally — including the new smoke section
- [x] Replay harness against PR #47 R1 surfaces N findings (see comparison above)
- [ ] After merge: confirm next review on a >500-LOC PR surfaces more than 4 findings without obvious padding

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5.3: Run `/babysit-pr` on the PR per `~/.claude/CLAUDE.md` § Branch Workflow**

Do not auto-merge; the human makes the merge call.

---

## Self-review checklist

Run after writing every task:

- [ ] **Spec coverage:** N formula → Task 1.2. Band protection → Task 1.2. Ceiling-not-floor → Task 1.2 + Task 3 negative fence. Length contract → Task 2. Smoke fence → Task 3. Replay verification → Task 4. PR description → Task 5.
- [ ] **Placeholder scan:** no TBD; the only placeholders are `<R1-sha>` and `<paste...>` markers in PR description templates that the executing engineer fills in from real outputs.
- [ ] **Type consistency:** `prompt-contracts-smoke.sh` (not `-smoke-aggregator-cap.sh`); `prompts/aggregator.md` step 3 + step 7 (not "step 4" or other numbers); `Answer: yes` / `Answer: unknown` (matches probe-schema).
- [ ] **Cap formula consistency:** `min(15, 3 + LOC_of_diff / 100)` appears identically in step 3 (Task 1.2), the smoke assertion (Task 3.1), and the PR description (Task 5.2). If the engineer tunes the formula in Task 4.3 (e.g., to `min(12, 2 + LOC_of_diff / 120)`), they MUST update all three sites.
- [ ] **Commit messages follow conventional style + include `Co-Authored-By` trailer.**
- [ ] **No worktree creation anywhere** (per global rule).
- [ ] **Order with companion plan respected:** PR description in Task 5.2 cites the companion plan and recommends landing it first.
