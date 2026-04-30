# Anti-Bloat Review Prompts — Design

## Problem

The kw-reviewer + babysit-pr loop is producing scope creep on PRs in `cncorp/plow`. Investigation across PRs 544, 546, and 552 (top-level + inline comments from knightwatch, Copilot, and corgea[bot], plus the resulting commits) shows:

- The kw-reviewer's `Bug-Class-Recurrence` consolidation works correctly (PR 546 collapsed 4 sub-findings twice; PR 552 once). The aggregator's seam-bypass framing is sharp. Inferred-intent is consistently good.
- But specialists frequently propose **remedies that add defensive code, fallback chains, theoretical edge-case handlers, or wrapper structures** — and neither the critic nor the aggregator audits the *cost of the proposed remedy itself*. They evaluate whether the finding is real, not whether the fix is worth its complexity.
- Babysit-pr's two-bucket triage (`Apply | Decline`) treats finding-validity as the apply-gate. So a real-but-bloat-y finding (e.g., "replace `assert user is not None` with explicit raise + logging context") gets applied verbatim because it's "real."
- The result is PRs that grow by N defensive lines per round — each calcifying a branch that future refactors must preserve.

**The cost being managed isn't LOC.** LOC is a stand-in for **conditionals, special cases, defensive code, and edge-case handlers that calcify the codebase**. Handling edge cases that don't actually happen makes the code harder to reshape later. The test for any proposed remedy is: *does the edge case it handles actually happen, or will it happen in the near future?* If neither, the remedy is bloat regardless of line count.

## Five recurring bloat patterns observed across PRs 544 / 546 / 552

1. **Add defensive guard** — `assert` → explicit raise + log context; `if not isinstance(x, list)` outside trust boundaries; null-checks where the seam guarantees non-null. (Copilot on PR 544's `assert user is not None`; corgea[bot] on PR 552's `containers might not be a list`.)
2. **Add fallback / state-reset for hypothetical pollution** — e.g. "set `posthog.disabled = False` in the prod branch in case prior init left it disabled." (kw-reviewer flagged this as `medium` on PR 544 — a calibration miss.)
3. **Wrap with snapshot dataclass / new DI seam** — the architecture/shape specialists sometimes propose new structures whose remedy is +50 LOC. PR 546's session-shape refactor was net-positive (deletes a class of bug); PR 552's "explicit bundle-id→slot mapping with a safe fallback" for a 32-slot djb2 collision among ~3 known bundle IDs is bloat.
4. **Add streaming/incremental version for theoretical perf/OOM** — e.g. tarball SHA-256 streaming on a desktop app importing user containers (PR 552).
5. **Add CI guard / extra test for unreachable scenario** — without naming the LOC math of the test itself.

## Goals

1. Make the bot **decline to propose** remedies that handle theoretical edge cases or add defensive code outside trust boundaries.
2. Give babysit-pr a **third bucket** between Apply and Decline — `Counter-propose` — for cases where the finding is real but the remedy as written is bloat.
3. Make the change with **net-flat or LOC-negative** edits across kw-reviewer + vibe-engineering. The mechanism must reduce calcified branches in the *output* without growing the prompts that produce it.

## Non-goals

- No new specialist (each new specialist costs ~$0.50/PR per orchestrator log; the issue is upstream of fan-out).
- No structural rewrite of `Bug-Class-Recurrence` or the critic gate — both work as designed.
- No change to babysit-pr's "no defer" rule — that remains load-bearing.
- No change to the `learn-from-replies.sh` mechanism — `/srosro-memorize` stays the only auto-tune path. We seed `COMMENT_REVIEW_MISTAKES.md` once with the patterns above; future tuning still flows through the existing seam.

## Architecture

Five edits across two repos. The unifying mental model: **introduce one "remedy-cost" framing rule at the highest leverage point (`common-header.md`), inherited by all 7 specialists**, then add downstream gates so neither the critic nor babysit-pr lets a bloat-y remedy through.

### kw-reviewer changes (knightwatch-reviewer3)

#### Change A — Add a "Remedy-cost framing" rule to `prompts/common-header.md`

Single edit, applies to all 7 specialists. Adds a numbered rule (~6 LOC) that mandates LOC delta + complexity framing for any proposed remedy, and explicitly forbids defensive guards, fallback chains, type validation outside boundaries, and wrapper dataclasses for theoretical concerns.

The rule must use the user's own framing: **LOC is a stand-in for conditionals, special cases, and defensive branches**. The test for any edge-case handler is whether the edge case actually happens or will happen in the near future.

#### Change B — Trim `prompts/architecture.md`

Currently 21 LOC. Two paragraphs collapse once Change A exists:
- The "non-blocking 'this is fine to ship today, file an issue before X' findings" paragraph — already covered by the remedy-cost rule (low-severity findings about future cost are fine; the rule just blocks bloat-y *current* remedies).
- The "more compute / more latency to delete a class of special cases is *not* over-engineering" paragraph — restates Concise Code in a way that now lives in common-header.

Net: -5 to -8 LOC, no loss of content.

#### Change C — Add `REMEDY-BLOAT` bucket to `prompts/critic.md` step 1

The critic currently has 6 status buckets: AGREE, FALSE POSITIVE, OVER-SPECIFIC, MISCALIBRATED, ALREADY ADDRESSED, DUPLICATE. Add a 7th: **REMEDY-BLOAT** — the finding may be real but the implied remedy adds N conditionals/defensive branches/edge-case handlers for a scenario that doesn't actually happen. Either rewrite to point at the LOC-negative alternative, or drop.

The critic's structural role is "stress-test specialist findings"; this gives it a name for the most common stress-test outcome that the existing buckets don't cleanly capture.

Net: +3 LOC, kills entire class of finding before it reaches the aggregator.

### vibe-engineering changes (claude-config)

#### Change D — Seed `COMMENT_REVIEW_MISTAKES.md` with 5 anti-bloat patterns

Currently 5 entries (12 LOC). Add 5 more, one per pattern observed in PRs 544 / 546 / 552:

- Don't propose replacing `assert X` (or other fail-fast guards) with explicit raise + logging context. The user's `Fail-Fast` standard prefers the assertion; a `try/except` wrapper at a non-boundary is bloat.
- Don't propose isinstance / type-validation checks for internal callers. Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers.
- Don't propose state-reset/fallback writes ("set X = default in case prior init left it dirty") unless the polluting scenario is observed in production, not theoretical.
- Don't propose wrapper dataclasses or new DI seams when a 1-2 line direct fix solves the same problem. Snapshots, freeze-views, and helper types are remedies for repeated problems, not first instances.
- Don't propose streaming / incremental rewrites of small in-memory operations on the basis of theoretical perf/OOM. Cite a measured failure or skip.

Net: +10 LOC, but each entry suppresses a documented class of finding.

This change feeds in via `lib/review-one-pr.sh:435` which appends `COMMENT_REVIEW_MISTAKES.md` to every assembled `standards.md`. Specialists already read § "Comment Review Mistakes" (per `critic.md:3`).

#### Change E — Add `Counter-propose` bucket to `babysit-pr/SKILL.md` Step 5 triage

Replace the two-bucket Apply/Decline table with three:

| Verdict | Examples | Action |
|---|---|---|
| **Apply** | real bug, fix is LOC-neutral or net-negative, fix doesn't add new conditionals/branches/handlers | fix in Step 6 |
| **Counter-propose** | finding is real but the remedy as written adds defensive guards / fallback chains / type-checks outside boundaries / new abstractions for theoretical concerns | reply with the LOC-negative alternative ("valid, but the suggested remedy adds N branches for a scenario that doesn't happen here; the fail-fast version is `<diff>` — applying that") and apply the alternative |
| **Decline** | finding wrong, premature abstraction for one call site, sycophantic ack, contradicts user standards | reply citing the conflicting rule |

The `Counter-propose` bucket lets babysit-pr push back on bloat-y remedies *at apply-time*, even if the finding survived the critic and aggregator. This is the muscle that makes the "no defer" rule still work — it preserves the spirit of the finding without applying the bloat-y letter.

Concurrently, two redundant paragraphs in the SKILL collapse:
- The "Apply with scope expansion" template's purpose is now covered explicitly by Counter-propose's reply pattern.
- The "When in doubt about scope" sentence at the end of Step 5 already lives in the table semantics once Counter-propose exists.

Net: 0 to -5 LOC depending on how much we collapse the redundancy.

## File-by-file edit map

| File | Repo | Net LOC | Change |
|---|---|---|---|
| `prompts/common-header.md` | knightwatch-reviewer3 | +6 | Add Rule 8 — Remedy-cost framing |
| `prompts/architecture.md` | knightwatch-reviewer3 | -5 to -8 | Drop two paragraphs now redundant with Rule 8 |
| `prompts/critic.md` | knightwatch-reviewer3 | +3 | Add `REMEDY-BLOAT` status bucket |
| `COMMENT_REVIEW_MISTAKES.md` | vibe-engineering | +10 | Seed 5 anti-bloat patterns |
| `skills/babysit-pr/SKILL.md` | vibe-engineering | 0 to -5 | Add `Counter-propose` triage bucket; collapse redundant scope-expansion language |

**Total:** roughly LOC-neutral across both repos. The win is in the *output* — fewer calcified branches in PRs going forward.

## Testing

The changes are markdown edits to LLM-prompt files; behavior tests don't apply. Validation comes in two forms:

1. **Smoke** — run `scripts/smoke-stale-head-warning.sh` and any other existing smoke that exercises prompt assembly to confirm `standards.md` still composes correctly with the seeded `COMMENT_REVIEW_MISTAKES.md`.
2. **Live observation** — over the next 1-2 active PRs after the edits land, check whether the bot proposes any of the 5 patterns from § "Five recurring bloat patterns." Each surfaced pattern is either (a) the prompt change failed to land, (b) the model didn't generalize from the rule (revisit phrasing), or (c) the pattern wasn't actually in the seeded list.

A two-week follow-up is appropriate to evaluate whether Change D's seeded entries are reducing scope creep in observed PRs, or whether more aggressive language is needed.

## Risks

- **Change A is the highest-leverage edit and the highest-risk for under-firing.** If the "remedy-cost framing" language is too soft, specialists will reproduce the same patterns. Mitigation: bias the language toward concrete bans ("don't propose X") over abstract principles ("consider the cost of Y").
- **Change C (`REMEDY-BLOAT` bucket in critic) is the highest-risk for over-firing.** A trigger-happy critic could mark every finding as `REMEDY-BLOAT` and the aggregator drops it. Mitigation: the bucket's prompt language must explicitly limit to "remedy adds defensive code OR handles theoretical edge cases OR introduces new abstraction for one call site."
- **Change E's `Counter-propose` bucket adds a third decision** at apply-time. Babysit-pr may struggle to choose between Counter-propose and Decline. Mitigation: the table's `Examples` column carries the choice explicitly — finding-real-but-remedy-bloat → Counter-propose; finding-wrong → Decline.

## Open questions

- Should Change D be seeded directly in this PR, or should it land via `/srosro-memorize` on a fresh PR so the existing learning seam is the sole path? **Resolved per user feedback: seed directly here.** Future tuning still flows through `/srosro-memorize` — this just bypasses the wait for it to organically accumulate the patterns.
- Should the `REMEDY-BLOAT` bucket allow keeping the finding at downgraded severity (medium → Surveyed-only), or always replace with the LOC-negative version? **Both** — the critic emits status; the aggregator decides whether to keep, downgrade, or drop. The existing AGREE/MISCALIBRATED machinery already handles this distinction.
