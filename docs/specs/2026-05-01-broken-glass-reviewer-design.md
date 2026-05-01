# Broken-Glass Reviewer — Design

## Problem

The kw-reviewer + babysit-pr loop reliably grows PRs across review rounds at our scale. Of the 18 PRs reviewed 6+ times in the last fortnight, 16 grew during review (typically 1.5×–4×). Only two shrank.

Spot-checks on the two PRs with the worst loop dynamics show the failure mode:

- **`cncorp/plow#534`** (10 rounds, eventually closed by author). Round 1 was 4 findings, +3,179 / −51 LOC. Round 10 was 3 findings, +6,305 / −212 LOC — doubled. Round 10's lead finding was `Bug-Class-Recurrence` ("4th review round surfacing the same alias-recovery class"), but it appeared *as one of three blocking/medium findings* — local fixes still surfaced alongside the structural ask, so the author kept patching the locals. After 10 rounds and a 2× LOC growth, they gave up and closed the PR.
- **`cncorp/plow#552`** (11 rounds, eventually merged). Bug-Class-Recurrence fired on **every single round** (2–3 instances per round). LOC trajectory was roughly stable (the author held the line). The reviewer never let go of the structural rewrite ask; the author shipped without it. The `Bug-Class-Recurrence` finding became background noise.

The two anti-patterns are different — one author over-iterated, the other under-iterated — but the cause is the same: **the existing loop-detection signal (`Bug-Class-Recurrence`) is one finding among many, and the reviewer has no mechanism to switch into a higher-level mode that names the *why* in plain prose, suppresses competing findings visually, and grounds the framing in the team's actual operating context** (~10 users, pre-PMF, fail-fast > defensive coverage).

The 2026-04-29 anti-bloat spec landed a `REMEDY-BLOAT` critic bucket and a `Counter-propose` babysit-pr triage rule. Those help on a per-finding basis. They don't address the *trajectory* — the across-rounds dynamic where each round's findings stack onto the prior rounds' patches.

## The cultural lens this spec encodes

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels: for me to even send you an invitation, I'd first have to find out your 'workspace URL' which very few people knew." — Stewart Butterfield on Slack's shared-channels beta

The reviewer's job, at our scale (~10 users, pre-PMF), is to catch real bugs and push for elegant code that lets us discover product-market fit. It is *not* to push for handling user types, scale, or behaviors we don't have yet. Architecture complexity for hypothetical scenarios is broken-glass cleanup — calcified branches that have to be preserved through every future refactor — disguised as diligence.

**Voice posture: questions over prescriptions.** Every non-bug finding states its #1 assumption as a question. The reviewer is the team's "could-this-actually-happen" check, not its "you must address this" enforcer. For scope-creep findings specifically, the question must name the *cost* of the additive remedy — *"adds complexity and makes PMF iteration harder"* — so the author is choosing between two visible costs (broken-glass risk vs. complexity) instead of being dictated to. Declarative voice is reserved for high-confidence bugs: reproducible failures, broken contracts with concrete user impact, security/data-integrity regressions with traceable cause.

This spec adds the **Broken-Glass Test** as a named standard (with the inquisitive-voice posture baked in), the per-repo `.knightwatch/review-priority.md` as the operating point, a momentum specialist that names the structural "why" on re-reviews as a question, a critic mode that reframes scope-creep findings as cost-naming questions when LOC is creeping, and an aggregator real-estate change that promotes the structural finding above competing locals while preserving the inquisitive voice across every published finding.

## What's already in place

- `Bug-Class-Recurrence` (aggregator step 5a + `CODING_STANDARDS.md` § Bug-Class-Recurrence) — replaces N local findings of the same class with one structural finding when the class has appeared in 2+ prior reviews or 2+ findings in the current draft.
- `REMEDY-BLOAT` (critic.md status bucket, from 2026-04-29 spec) — flags findings whose proposed remedy adds defensive branches / fallback chains / new abstractions for theoretical scenarios.
- Step-back signal (aggregator step 6) — switches to a 200–400-word "this PR is too broken to converge through review iteration; close + resubmit smaller" mode when 5+ blocking findings or a load-bearing seam-bypass shows up. **First-review only.**
- `Counter-propose` triage (babysit-pr SKILL Step 5) — apply-time push-back on bloat-y remedies.
- `CODING_STANDARDS.md` § Anti-Bloat, § Reframe the Spec, § Concise Code, § Fail-Fast — the principles the reviewer cites today.
- `common-header.md` Rule 8 (Remedy-cost framing) — applies to all 8 finding-producing specialists.

## Goals

1. **Frame feedback as questions by default.** Every non-bug finding leads with its #1 assumption as a question. Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). Specialists, critic, aggregator, and the new momentum specialist all default to inquisitive voice.
2. **Name the cost in scope-creep questions.** When the underlying ask is additive ("you should also add X"), the published question must name the cost: *"adds complexity and makes PMF iteration harder."* The author is choosing between two visible costs, not being told what to do.
3. **Detect ballooning.** When a PR's LOC has grown across rounds *or* the same class has been flagged in 2+ rounds, the reviewer notices and switches modes.
4. **Promote the structural ask above the local fixes.** When the loop-breaker fires, the structural finding gets dedicated real estate at the top of the review (its own callout block, question-framed, citing the touchstone). Local findings remain in the numbered list below — *not dropped* — but visually subordinate, and themselves voiced as questions where applicable.
5. **Ground every remedy in the operating context.** A new Pre-PMF lens: for each surviving finding, the critic asks whether the remedy is solving for users, scale, or behaviors we don't have today. Two outcomes: if the remedy adds defensive code/abstraction with no observed need → REMEDY-BLOAT (drop). If the underlying concern is real but the prescription is additive → REFRAME-AS-QUESTION (move to Open Questions with cost-naming).
6. **Make the cultural anchor citable.** Add `Broken-Glass Test` to `CODING_STANDARDS.md` (with the Butterfield quote, the voice posture, and the question template baked in), and `.knightwatch/review-priority.md` as the per-repo operating-point file with concrete bloat-vs-bugfix contrast pairs and worked-example reframings.
7. **Keep specialists' existing severity calibrations.** This spec is additive — it adds a new specialist, a voice posture, and tightens existing prompts; it does not relax any existing finding mechanism. High-confidence bugs are still declarative, still severity-tagged, still in the Findings list.

## Non-goals

- No replacement of `Bug-Class-Recurrence`. It still fires when the same class repeats; this spec makes its *real estate* louder when scope-creep also signals.
- No change to `learn-from-replies.sh` / `/srosro-memorize`. Future tuning still flows through that seam.
- No new findings the reviewer wasn't already empowered to make. The momentum specialist outputs *prose only*, not severity-tagged findings — its output goes into the Overview, not the Findings list.
- No removal of any existing standard. `CODING_STANDARDS.md` gets one new section.
- No relaxation of fail-fast standards in service of "elegance." Elegance and fail-fast are *aligned* — the seam choices that reduce LOC also remove silent-degradation paths.

## Architecture

Nine edits across two repos plus orchestrator wiring. The unifying mental model: **the reviewer carries the Broken-Glass Test (with its inquisitive-voice posture) as an always-on lens** (loaded into every prompt via the standards file + thin posture-pointers in each prompt), but the *aggressiveness of citation*, the *amount of question-reframing*, and the *real estate given to the structural finding* all escalate when LOC trajectory + Bug-Class-Recurrence signal a loop.

The voice posture cuts across every node in the pipeline:

| Node | Voice posture role |
|---|---|
| **Specialists** (security, data-integrity, architecture, simplification, tests, shape, performance, consumers) | Each finding states its #1 assumption explicitly. Specialists may file declaratively for high-confidence bugs; otherwise lead with the assumption-as-question. |
| **Critic** | Catches declarative findings that should have been question-framed. Adds REFRAME-AS-QUESTION status with a cost-naming reframe. |
| **Aggregator** | Preserves question voice across the published Findings. Routes REFRAME-AS-QUESTION items to Open Questions with structured cost-naming format. |
| **Momentum specialist** (new) | Outputs prose-only re-review meta-findings as questions. Names the trajectory pattern + the cost of continuing it. |

### vibe-engineering changes (claude-config)

#### Change A — Add § Broken-Glass Test to `CODING_STANDARDS.md`

New top-level section, ~50 LOC. Contains:

1. **The Butterfield quote, verbatim** — beta-period Slack shared-channels memo about validating PMF before polishing.
2. **The principle.** At our scale (~10 users, pre-PMF), the reviewer's job is to catch real bugs and push for elegant code that lets us discover PMF. It is not to push for handling user types, scale, or behaviors we don't have yet. The elegant version that fails loudly when its assumption breaks is preferable to the defensive version that silently handles a population we don't have.
3. **Voice posture: questions over prescriptions.** Default to inquisitive voice on every non-bug finding. State the #1 assumption explicitly as a question. Declarative voice is reserved for high-confidence bugs only — reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. The bar for "high-confidence" is: can you cite the failing path, the user-observable outcome, and the line where the contract breaks?
4. **Question template** (cite by name when applying):

   ```
   Will [user state X / data shape Y / scale Z]?
   - If yes, [proposed action].
   - If not, consider cutting [proposed action] — adds complexity and makes PMF iteration harder.
   [Optional: recommendation given the operating point.]
   ```

   The "adds complexity and makes PMF iteration harder" phrasing is load-bearing for scope-creep findings — it names the cost of the additive remedy so the author chooses between two visible costs (broken-glass risk vs. complexity), not between "fix the issue" and "ignore the reviewer."

5. **Worked-example reframings** (3 examples drawn from real published bloat moments):
   - Taxonomy demand for first-instance directory: *"Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships team-skills/ content into the runtime."*
   - Unrelated guard-update ask: *"Has any agent task touched `plow-local-token` in the last fortnight? If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder."*
   - Demand for regression tests beyond 1-2 focused: *"Has the upstream CSV format changed twice in the last quarter? If yes, 1-2 in-memory SQLite tests pinning the import path are worth ~10 LOC each. If not, fail-loud-on-bad-shape is acceptable; consider cutting the layer-by-layer coverage demand — adds complexity and makes PMF iteration harder."*

6. **Review question:** *"Did this finding name its #1 assumption as a question, or was it asserted as if the assumption is settled? Did the question name the cost of the remedy?"*
7. **Pointer** to the per-repo `.knightwatch/review-priority.md` for the current operating point + per-repo contrast pairs.

The section is short and citable — specialists reference it like they reference `Anti-Bloat` or `Fail-Fast` today, with the additional step that the voice posture is now part of the standard itself, not a separate stylistic concern.

#### Change B — Seed two entries into `COMMENT_REVIEW_MISTAKES.md`

Two new calibrations:

> Don't propose remedies that solve for users, scale, or behaviors we don't have yet. The product is small (see `.knightwatch/review-priority.md`); remedies should match that reality. The elegant + fail-loud version of a fix is preferred over the defensive version that silently handles a hypothetical population.

> Lead non-bug findings with the #1 assumption as a question, not as an assertion. For scope-creep findings specifically, the question must name the cost: *"adds complexity and makes PMF iteration harder."* Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). When a finding is asserted but the assumption could go either way, that's a calibration miss — reframe it.

These are the calibration entries the auto-tune loop would have produced eventually; we seed them directly so they're available immediately. Future tuning still flows through `/srosro-memorize`.

### knightwatch-reviewer changes

#### Change C — Per-repo `.knightwatch/review-priority.md`

New per-repo file alongside `product-context.md` and `siblings`. Read via the existing `read_knightwatch_file` loader at the same base-ref-from-merge-base pattern. Written to `.codex-scratch/review-priority.md`. Loaded loud at the top of `common-header.md` (so every specialist + critic + aggregator + momentum specialist sees it before reading anything else).

**Default content** (used when the file is absent — a cold-start fallback that matches the present operating point of every tracked repo):

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

Operators edit this file per repo as the operating point shifts. Scope creep into `tkmx-server` at 100K users → edit the file for that repo to match its new operating point; the rest of the repos are unaffected.

#### Change D — New `prompts/momentum.md` specialist

New specialist that runs **only on re-reviews** (skipped on first review). Outputs prose, not severity-tagged findings. Consumed by the aggregator's Overview.

Inputs: `prior-reviews.md` (concatenated prior aggregator outputs), `commits.md` (commits on this branch), `loc-trend.md` (new — see Change E), `review-priority.md`, `inferred-intent.md`, `diff.patch`.

Output contract (4–6 sentences, no preamble, no headers, no severity tags). The prose **must end with a question**, not a directive — the reviewer's role here is to surface the trajectory pattern and force the author to articulate whether continuing it is worth the cost.

```
## Momentum

<Sentence 1-2: name the trajectory — "N rounds, M LOC growth, structural ask
of <X> unmoved since round Y."

Sentence 3-4: name the cost of continuing the current approach.
Cite Broken-Glass Test when applicable. The cost language must echo the
standard's phrasing: "adds complexity and makes PMF iteration harder," or
"calcifies <N> branches that future refactors must preserve," or similar.

Sentence 5-6 (closing question): a single, sharp question to the author.
"Are we ready to commit to <structural alternative>, or is continuing to
patch leaves the better trade for <reason>?" Do not direct; ask.>

If the structural ask has been unmoved across N rounds, name it explicitly
in the closing prose: "Findings 2-N below are local. Do not address them
in this PR until the structural direction is settled — additive responses
now are how PRs balloon."
```

Example output for `cncorp/plow#534` round 4:

> ## Momentum
>
> 4 rounds, +3.1k LOC, and the alias-recovery resolver still hasn't moved — every round adds another `if/elif` branch to `_resolve_pair_state()` for a case the prior round flagged. The structural ask since round 1 has been: one resolver owns reclaim precedence, all callers consume it. Continuing the current approach calcifies four alias-state branches that the next refactor would have to preserve, and none of the failure modes flagged this round have been observed at our scale.
>
> Are we ready to commit to splitting alias-state policy into one owner, or is continuing to extend the leaves the better trade for some reason I'm not seeing? Findings 2–N below are local; addressing them in this PR before the structural direction is settled is how PRs balloon — adds complexity and makes PMF iteration harder.

**Triggers:** runs on every re-review (whenever `previous-review.md` is non-empty). The aggregator decides what to do with the output based on whether the loop-breaker conditions are met (Change G).

#### Change E — `.codex-scratch/loc-trend.md` scratch input

New scratch file written by `lib/review-one-pr.sh` before specialist fan-out. The per-round SHAs come from each run's `meta.json.sha` (the canonical post-checkout `REVIEWED_SHA`); the run-directory listing is just the filter for "which runs belong to this PR".

Format (3-line summary + per-round table):

```markdown
# LOC trend

This PR has been reviewed N times. Across rounds, base...head has gone from
+START_ADDS / −START_DELS to +END_ADDS / −END_DELS (FILE_DELTA files).

Trajectory: GROWING (X.X× from first review) | STABLE | SHRINKING.

| Round | Timestamp | SHA | base...head | Files |
|---|---|---|---|---|
| 1 | <ts> | <sha> | +A / −D | F |
| 2 | ... | ... | ... | ... |
```

`base...head` is `git diff --shortstat <base_tip>...<sha>` (three-dot, matches GitHub's "Files changed" view) — the same shape PR review uses for `FULL_PR_DIFF`. The helper lives in `lib/run-dir.sh` next to the existing run-dir helpers (`stage_prior_reviews`, etc.); the orchestrator calls it before specialist fan-out and writes the table.

This file is consumed by the momentum specialist (Change D) and the aggregator's loop-breaker (Change G). Specialists already loaded today don't need it.

#### Change F — Critic: voice posture + REFRAME-AS-QUESTION + Pre-PMF lens

Three additions to `prompts/critic.md`:

**(F1) Voice-posture audit.** For every finding the critic processes, check: did the specialist file it as a question or as an assertion? If declarative-but-not-high-confidence, the critic flags it. The threshold for "high-confidence" follows § Broken-Glass Test: reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. Anything else should have its #1 assumption surfaced as a question. The critic's existing buckets handle the surviving finding; this audit just adds a new bucket below for items that fail the test.

**(F2) New status: REFRAME-AS-QUESTION.** Adds an 8th status bucket alongside today's AGREE / FALSE POSITIVE / OVER-SPECIFIC / MISCALIBRATED / REMEDY-BLOAT / ALREADY ADDRESSED / DUPLICATE. Used when:
- The underlying concern is real (so it's not FALSE POSITIVE), AND
- The proposed remedy is additive (adds defensive code, abstraction, validation, test, branch, file), AND
- The author could legitimately decide either way once the assumption is named.

When applied, the critic emits the reframed text inline so the aggregator can drop it directly into Open Questions:

```
### [<specialist>] Finding N — REFRAME-AS-QUESTION
<one-line reason: what assumption is being asserted>
Reframe:
> Will [state X]? If yes, [Y]. If not, consider cutting [Y] — adds complexity and makes PMF iteration harder.
> [Optional recommendation given operating point.]
```

Scope-creep findings (asking the PR to update unrelated infra, fix a long-pre-existing gap, expand into adjacent policy) MUST be REFRAME-AS-QUESTION'd if they survive — they are not bugs, the remedy is additive by definition, and the cost-naming forces the author to weigh in. The reframe must include explicit cost language ("adds complexity and makes PMF iteration harder").

**(F3) Pre-PMF lens.** When `loc-trend.md` shows GROWING and Bug-Class-Recurrence has fired in this round or any prior round, the critic applies the lens to *every surviving finding*: would the failure mode the remedy is preventing be observed in production at our scale today? If no AND the remedy is additive without observed need → REMEDY-BLOAT (drop entirely). If no but the underlying concern is real → REFRAME-AS-QUESTION.

Implementation: ~25 LOC added to critic.md (output schema + bucket descriptions + lens conditional + cost-language requirement). The existing critic machinery handles the rest.

#### Change G — Aggregator: voice posture + Open Questions structure + loop-breaker mode

Three additions to `prompts/aggregator.md`:

**(G1) Voice posture across published findings.** Before publishing any Finding, the aggregator checks: did the specialist (or critic, after stress-testing) state the #1 assumption as a question? Declarative findings are kept as-is *only* if they meet the high-confidence bar (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). All other surviving findings lead with a question that names the assumption — and, for additive remedies, names the cost.

A typical published finding now looks like:

```
3. [medium] Will the production CSV emitter ever drop the trailing
   newline? `import_csv()` reads `lines = raw.split('\n')` so a missing
   final newline silently truncates the last row. If the upstream emitter
   is contractually newline-terminated, this is fine — fail loudly on the
   structural assumption. If the contract is ambiguous, consider parsing
   via `csv.reader` instead of `split` — same LOC, no edge-case risk.
   Files: scripts/receipts_db.py:62. (Standard: Fail-Fast)
```

Note the structure: **question → conditional → recommendation tied to operating-point.**

**(G2) Open Questions section structure.** Today's Open Questions section is free-form. After this spec, REFRAME-AS-QUESTION items from the critic land here in a structured format:

```
**Open Questions**

- **Q: <name the choice in 5-10 words>** — <state-trigger sentence>. <If-not branch with cost-naming>. <Optional: recommendation.>
```

Example:

```
**Open Questions**

- **Q: Permanent fourth taxonomy class, or one-off?** — Will we add a 2nd `team-skills/` bundle in the next month? If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships team-skills/ content into the runtime.
- **Q: Has any agent task touched `plow-local-token` recently?** — If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder.
```

Open Questions is no longer "padding" or "stuff that didn't fit elsewhere" — it's the home for legitimate concerns whose remedy is additive enough that the author should answer rather than absorb. The aggregator should not feel pressure to drop these to keep the review short; questions are the unit of reviewer pushback now.

**(G3) Re-review loop-breaker mode.** Modify step 6 (today's "step-back signal") to also fire on re-reviews when:

- `loc-trend.md` shows GROWING (≥1.5× since first review), AND
- `Bug-Class-Recurrence` has fired in this round or any prior round (visible in `prior-reviews.md`),

OR

- `Bug-Class-Recurrence` has fired in 2+ prior rounds (regardless of LOC trajectory — this catches the PR#552 dynamic where the author held LOC stable but ignored the structural ask),

OR (existing trigger, unchanged):

- First-review-only conditions from today's step 6.

When the loop-breaker fires:

1. **Promote the momentum specialist's output verbatim** as a dedicated callout block at the top of the review, immediately after the intent line and before `**Overview**`. Format with visual weight (blockquote + bold lead). The callout is question-shaped — momentum specialist's output already ends in a question; the aggregator preserves that voice.

   Example:
   ```
   > **Why this PR isn't converging?**
   >
   > 4 rounds, +3.1k LOC, and the alias-recovery resolver still hasn't
   > moved... [full momentum prose]
   ```
2. **Keep the local findings.** They appear in the numbered `**Findings**` list as today, ranked by severity, all subject to the (G1) voice posture. *Not dropped* — but the structural callout has eaten the visual real estate before the reader gets to them.
3. **Add a closing question** in the Overview: *"Are we ready to commit to the structural direction in the callout above, or is continuing to patch leaves the better trade given X? Addressing the local findings below before the direction is settled is how PRs balloon."*
4. **Verdict stays `COMMENT`** — same as today's first-review step-back.

The first-review step-back path (PR fundamentally not iterable, today's step 6) keeps its existing behavior — a 200–400-word redirect with the 3 most structural issues, *no per-finding enumeration*. That mode is more drastic; the re-review loop-breaker mode is less drastic (locals stay in the list) because by definition, the author has been engaging in good faith for multiple rounds. Both modes share the inquisitive voice posture from (G1).

#### Change H — Orchestrator wiring (momentum + review-priority + loc-trend)

Three wire-ins in `lib/review-one-pr.sh`:

1. **Momentum specialist.** Run alongside the critic, after specialists fan out. Output written to `.codex-scratch/agents/momentum/output.md`. The aggregator reads it as a new input. Skip when `previous-review.md` is empty (first review — no momentum to evaluate).
2. **`review-priority.md` load path.** Read via `read_knightwatch_file` from the merge-base SHA (same pattern as `product-context.md`). Tri-state: PRESENT → use file content; ABSENT → use the default content embedded in the script; ERROR → abort the review (Fail-Fast — don't silently fall through to default if git itself failed).
3. **`loc-trend.md` computation.** Read `~/.pr-reviewer/runs/<repo>__<pr>__*` listing, take each run's SHA from its `meta.json.sha` (post-checkout `REVIEWED_SHA`), compute `git diff --shortstat <base_tip>...<sha>` (three-dot) for each prior SHA, write the table format from Change E to `.codex-scratch/loc-trend.md`. Handle 1-round (no trend yet — emit a header noting it's the first review), N-round, and missing-`runs/` cases without aborting; fail loud on a `meta.json` that's present but missing `.sha` / `.started_at` (corruption — silent skip would mask a regression rewiring the SHA source).

Plus prompt-side wire-ins:

4. **`prompts/common-header.md`** — add a load-loud block at the top that interpolates `review-priority.md` content. This is what makes the standard always-on for the 8 finding-producing specialists. Also add a single-line voice-posture pointer: *"Apply the voice posture from `standards.md` § Broken-Glass Test — questions over prescriptions on every non-bug finding; declarative voice only on high-confidence bugs; scope-creep questions must name the cost."*
5. **`prompts/critic.md`** — same single-line voice-posture pointer at the top, since critic doesn't inherit common-header.
6. **`prompts/aggregator.md`** — same single-line voice-posture pointer at the top.
7. **`prompts/momentum.md`** — voice posture is already baked into the output contract (Change D), but the same pointer is added for consistency.

### Trigger conditions, summarized

| Trigger | Today | After this spec |
|---|---|---|
| First review, 5+ blocking / load-bearing seam-bypass | Step-back redirect | Same (unchanged) |
| Re-review, LOC ≥1.5× since first round + Bug-Class-Recurrence | (no signal) | Loop-breaker mode (Change G) |
| Re-review, Bug-Class-Recurrence in 2+ prior rounds | Surface as one finding | Loop-breaker mode (Change G) |
| Re-review, no Bug-Class-Recurrence | Normal review | Normal review (momentum still runs, may or may not surface) |
| First review, normal | Normal review | Normal review |

## File-by-file edit map

| File | Repo | Net LOC | Change |
|---|---|---|---|
| `claude-config/CODING_STANDARDS.md` | vibe-engineering | +50 | Add § Broken-Glass Test (principle + voice posture + question template + worked-example reframings) |
| `claude-config/COMMENT_REVIEW_MISTAKES.md` | vibe-engineering | +6 | Seed two entries (Pre-PMF + voice-posture calibrations) |
| `.knightwatch/review-priority.md` | knightwatch-reviewer + each tracked repo | +90 each | New per-repo file with stage / voice posture / contrast pairs / worked-example reframings |
| `prompts/momentum.md` | knightwatch-reviewer | +70 | New specialist (output ends in question, names cost) |
| `prompts/common-header.md` | knightwatch-reviewer | +6 | Load `review-priority.md` loud at top + voice-posture pointer |
| `prompts/critic.md` | knightwatch-reviewer | +25 | Voice-posture audit + REFRAME-AS-QUESTION bucket + Pre-PMF lens (Change F) |
| `prompts/aggregator.md` | knightwatch-reviewer | +50 to +70 | Voice posture across published findings + Open Questions structure + re-review loop-breaker mode (Change G) |
| `lib/review-one-pr.sh` | knightwatch-reviewer | +30 to +40 | Compute `loc-trend.md`, run momentum specialist, load `review-priority.md` (Change H) |
| `lib/knightwatch-config.sh` | knightwatch-reviewer | 0 | (loader already supports new file via existing API) |

**Total:** ~+250 LOC in prompt content + ~+25 LOC in shell wiring. The win is in PR *output* — questions that force authors to choose between visible costs, fewer calcified branches absorbed silently, faster convergence on structural finding direction.

## Testing

The changes are predominantly markdown edits to LLM prompts and a small shell wire-in. Validation:

1. **Smoke** — extend `lib/tests/anti-bloat-contract-smoke.sh` (or add a sibling) to fence:
   - `Broken-Glass Test` token present in `CODING_STANDARDS.md`.
   - Voice-posture pointer present in `common-header.md`, `critic.md`, `aggregator.md`, and `momentum.md`.
   - REFRAME-AS-QUESTION token present in critic.md alongside the existing 7 buckets.
   - `.knightwatch/review-priority.md` loader handles ABSENT → default fallback (3 states: PRESENT / ABSENT / ERROR, same as the existing pattern).
   - `loc-trend.md` script handles 1-round (no trend yet), N-round, and missing-`runs/` cases without aborting.
   - Aggregator's loop-breaker trigger fires on a synthetic prior-reviews.md with 2+ Bug-Class-Recurrence entries.
2. **Live observation** — over the next 1–2 active re-reviews on `cncorp/plow`, verify:
   - Momentum specialist produces a prose section ending in a question.
   - When LOC trajectory + Bug-Class-Recurrence signal trigger, the structural callout appears at the top with the locals retained below.
   - REFRAME-AS-QUESTION items appear in critic output and land in Open Questions in the published review.
   - Non-bug findings in the published review state their #1 assumption as a question and (for additive remedies) include cost-naming.
   - **Critically:** verify a real high-confidence bug from the same window is *still* declarative — that the voice posture isn't over-applied. A regression here is the most expensive miss.

A two-week follow-up is appropriate to evaluate whether scope-creep PRs (next instance of #534/#552 dynamics) actually shrink, hold steady, or get redirected to a structural rebuild. If neither happens, the language in Change G needs to be more direct. Also check: are authors *answering* the questions in PR threads (good signal), or ignoring them (bad signal — voice may be too soft)?

## Risks

- **Voice posture (Changes A, F, G) could over-question and weaken real bugs.** If specialists/critic/aggregator over-apply the inquisitive voice, a real data-corruption bug ends up framed as "Will user data end up in X state?" — diluting the urgency. Mitigation: the standard names the high-confidence bar explicitly (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). The critic's voice-posture audit is a *check*, not a transformation — it only reframes findings that fail the high-confidence bar. The aggregator's published findings preserve declarative voice when the bar is met. Live-observation step in Testing covers this: a real bug reframed as a question is the most important miss to catch.
- **Voice posture could become performative.** Specialists could prepend a vacuous question ("Will this break?") to every finding and call the posture satisfied. Mitigation: the question template is *specific* — it names the state-trigger, the if-yes branch, the if-not branch with cost-naming, and an optional recommendation. A specialist that produces "Will this break?" is failing the schema. Smoke tests can fence the structural shape (does each non-bug finding have a question + cost-naming?).
- **Change D (momentum specialist) is the highest-risk for under-firing.** A momentum specialist that hedges or restates the local findings adds noise without changing behavior. Mitigation: the prompt mandates 4–6 sentences max, no severity tags, no enumeration of local findings, output ends in a question, and cost-naming is required. The output contract is rigid.
- **Change G (loop-breaker) is the highest-risk for over-firing.** A trigger-happy loop-breaker would turn every 4+-round PR into a "rebuild the seam" redirect, frustrating authors mid-iteration. Mitigation: round count alone never triggers it. Either LOC has materially grown *and* Bug-Class-Recurrence has fired ≥1 time, or Bug-Class-Recurrence has fired in ≥2 rounds independently. Authors holding LOC stable while iterating on small unrelated findings won't trigger it.
- **Change C (per-repo file) adds operator burden.** Each tracked repo needs the file committed to its base branch. Mitigation: the default content (used when absent) matches today's universal operating point. Operators only need to edit when a repo's stage shifts. The existing PRESENT/ABSENT/ERROR fallback semantics in `knightwatch-config.sh` make this a clean migration.
- **REFRAME-AS-QUESTION could conflict with the critic's existing AGREE bucket.** The critic might both AGREE and REFRAME-AS-QUESTION the same finding. Mitigation: REFRAME-AS-QUESTION is mutually exclusive with AGREE — it's chosen when the underlying concern is real but the remedy is additive. The critic's prompt makes the discriminator explicit: AGREE for declarative-bug findings that meet the high-confidence bar; REFRAME-AS-QUESTION for everything that survives but would otherwise calcify a branch.
- **Open Questions could become a dumping ground.** If every borderline finding gets dumped to Open Questions, the section grows long and the author's eye glazes. Mitigation: the aggregator's prompt caps Open Questions at "as many as needed, but each must be sharp" — questions that don't meet the template (state-trigger + if-not branch with cost-naming + optional recommendation) get dropped. Quality over volume, same as Findings.
- **Change G's "keep locals in the list" choice could backfire.** If locals are still visible, authors may still patch them and ignore the structural callout (the PR#534 dynamic). Mitigation: the structural callout's visual weight (blockquote + bold lead + question-shape at the top) is the muscle, and the closing question in the Overview directly tells the author "addressing the local findings below before the structural direction is settled is how PRs balloon." If the data 2 weeks from now shows authors still bypass the callout, the next iteration is to drop the locals (or move them under a `<details>` collapsed block).

## Open questions

- Should the momentum specialist also run on first reviews? **Resolved: no.** Momentum is by definition trajectory-aware; on first review there's no trajectory. The first-review step-back already exists for "PR too broken to converge."
- Should the per-repo `review-priority.md` be required, or is the default content the source of truth? **Resolved: default is the source of truth, per-repo override optional.** Today every tracked repo is at the same operating point; the per-repo file exists for the future moment when one repo's stage shifts.
- Should we pin a token threshold for "≥1.5× LOC since first review"? **Resolved: 1.5× is the soft trigger, but the aggregator prompt allows judgment.** Hardcoding 1.5× into the shell wire-in would be a calcified branch we'd later have to revisit; phrasing it as "materially grown" in `loc-trend.md` and letting the aggregator decide is more aligned with the standard's spirit.
- Should `Counter-propose` (from the 2026-04-29 spec) get a Broken-Glass-Test version? **Probably yes, but out of scope for this spec.** Babysit-pr's apply-time pushback on bloat-y remedies should cite the new standard once it lands. Filing as a follow-up.
