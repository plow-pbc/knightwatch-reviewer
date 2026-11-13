# Probe — schema (data shape only)

This file defines the **data shape**. Policy (when to emit, mandates, posture) lives in `prompts/common-header.md`. Rendering policy lives in `prompts/aggregator.md`. Keeping shape and policy split prevents drift between two prompt surfaces.

## Fields

Every probe is a Markdown block with this exact field set:

```
### Probe N
- **From:** <specialist name>          # e.g. shape, security, architecture-refined, critic
- **Class:** <bug|bypass|shape|simplification|tests>
- **Q:** <one sentence — the assumption being asserted as if settled, in question form>
- **Files:** <path:line>, <path:line>, …
- **If yes, edit:** <concrete code change this unlocks — name files + LOC delta>
- **Sketch:** <OPTIONAL — simplification/shape probes: fenced code block with the simpler version; see Class options>
- **If no, cost:** <one clause naming what calcifies if we keep current shape>
- **Confidence:** <high|medium|low>    # emitter's prior on Q being yes
- **Severity if yes:** <blocking|medium|low|nit>
- **Answer:** <yes|no|unknown>         # filled by critic with evidence; specialists default to "unknown"
- **Evidence:** <one line citing the grep/git-log/file-history finding that produced the answer; "—" if Answer=unknown>
```

## Class options

The `Class:` field takes exactly one of these tokens. Each class carries its own severity rubric + edit/cost convention; per-specialist files list which classes they emit and supply the **domain examples** (what to look for in their angle).

- **`bug`** — defect with a user-observable wrong outcome (security, data-integrity). `Confidence: high` when the failing path is cited; `medium` when the trigger requires a plausible-but-uncited condition. `Severity if yes: blocking` for high-confidence + user-observable; `medium` for hardening / lower-confidence. `If no, cost:` `"—"` (bug probes don't take an inverted-cost stance — when the bug is real, severity is the only axis).

- **`bypass`** — instance-1 of a canonical pattern the PR sidestepped (`shape`). `Confidence: high`, `Severity if yes: blocking`. `If yes, edit:` "rewrite to call canonical at <path:line>". `If no, cost:` "establishes a parallel seam future routes must reckon with".

- **`shape`** — second-instance pattern with no canonical yet, OR architectural seam / layering violation (`shape`, `architecture-refined`). `Confidence: medium|high`, `Severity if yes: medium` (`blocking` for hard architectural lock-in). `If yes, edit:` "extract <name> at <path:line>" or name the structural change. `If no, cost:` "third instance will be cheaper to write than to refactor — pattern established by inertia". `Sketch:` (per the Fields block) is welcome here too when the extraction/structural change fits in ~15 lines.

- **`simplification`** — removal-shaped finding: `If yes, edit:` is LOC-negative or branch-negative. Covers DRY collapses (kid-hit or intra-PR duplication into a helper), dead-code (stale caller / unreachable conditional / zero-callers symbol / private dead helper), and complexity-cost (defensive branches, helpers with one call site, framework-where-function-would-do, premature optimization, defense-in-depth not requested, over-tested edges, defensive caller-shape adapters, retry layers, idempotency machinery, caching layers, validation guards). `Confidence: medium|high` for clear duplication or stale-caller; `low|medium` for "earns its place?" judgment calls. `Severity if yes: blocking` for stale-caller / unreachable-bad-path / well-established-utility-was-already-there / net-additive refactor PR with no substrate-replacement target; `medium` for typical DRY collapses or architectural defensive layers; `low|nit` for code-style cases. `If yes, edit:` "delete <code> — N LOC, fewer seams" or "collapse N copies into <helper>". `If no, cost:` name what calcifies at the operating point if we keep the shape (defensive surface, third-copy threshold, dynamic-dispatch argument, etc.). When the replacement fits in ~15 lines, include a `Sketch:` — the actual collapsed code (the *after*), not a description of it, so the author can apply rather than interpret. Being unable to write a behavior-preserving sketch is evidence the probe is wrong — resolve that doubt before emitting, don't emit a sketchless hedge.

- **`tests`** — coverage gap, test-shape problem, or PR-related `just test` failure (`tests`). `Confidence: high` for explicit test failures; `medium` for missing-coverage; `low` for test-quality. `Severity if yes: blocking` for failing tests caused by this PR or bug-fixes-without-regression-test; `medium` for non-blocking gaps with named seams; `low|nit` for test-quality observations. `If yes, edit:` name the test file + the seam (function extraction / DI) when applicable — and name the existing test or fixture to extend before proposing a new one, stating the *net* LOC including any collapse proposed alongside. `If no, cost:` name the runtime risk that would emerge if the test isn't added.

- **`copy`** — a user-facing string that is verbose, imprecise, AI-sounding, or doing a job an affordance should do (`copy`). `Confidence: high` when the replacement is a clear cut or a precise term; `medium` for tone and AI-tell clusters. `Severity if yes: medium` for copy in a shipped UI or a message users receive; `low|nit` for marketing pages and one-word nits; never `blocking`. `If yes, edit:` the exact replacement text, or the affordance that replaces it. `If no, cost:` what the user misreads or skims past. `Sketch:` before → after.

## Critic counter-arguments (per-angle critic only)

Each per-angle critic appends its resolutions as a single H2 section to its specialist's file at `.codex-scratch/specialists/<angle>.md`. Header form: `## Critic counter-arguments`, then one `### Probe N` block per resolved probe with required `Answer:` + `Evidence:` and optional `Severity if yes:` override. Cross-angle generated probes are emitted by the aggregator, not by per-angle critics — see `prompts/aggregator.md` step 1 for the attribution rule.
