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

- **`shape`** — second-instance pattern with no canonical yet, OR architectural seam / layering violation (`shape`, `architecture-refined`). `Confidence: medium|high`, `Severity if yes: medium` (`blocking` for hard architectural lock-in). `If yes, edit:` "extract <name> at <path:line>" or name the structural change. `If no, cost:` "third instance will be cheaper to write than to refactor — pattern established by inertia".

- **`simplification`** — removal-shaped finding: `If yes, edit:` is LOC-negative or branch-negative. Covers DRY collapses (kid-hit or intra-PR duplication into a helper), dead-code (stale caller / unreachable conditional / zero-callers symbol / private dead helper), and complexity-cost (defensive branches, helpers with one call site, framework-where-function-would-do, premature optimization, defense-in-depth not requested, over-tested edges, defensive caller-shape adapters, retry layers, idempotency machinery, caching layers, validation guards). `Confidence: medium|high` for clear duplication or stale-caller; `low|medium` for "earns its place?" judgment calls. `Severity if yes: blocking` for stale-caller / unreachable-bad-path / well-established-utility-was-already-there / net-additive refactor PR with no substrate-replacement target; `medium` for typical DRY collapses or architectural defensive layers; `low|nit` for code-style cases. `If yes, edit:` "delete <code> — N LOC, fewer seams" or "collapse N copies into <helper>". `If no, cost:` name what calcifies at the operating point if we keep the shape (defensive surface, third-copy threshold, dynamic-dispatch argument, etc.).

- **`tests`** — coverage gap, test-shape problem, or PR-related `just test` failure (`tests`). `Confidence: high` for explicit test failures; `medium` for missing-coverage; `low` for test-quality. `Severity if yes: blocking` for failing tests caused by this PR or bug-fixes-without-regression-test; `medium` for non-blocking gaps with named seams; `low|nit` for test-quality observations. `If yes, edit:` name the test file + the seam (function extraction / DI) when applicable. `If no, cost:` name the runtime risk that would emerge if the test isn't added.

## Critic counter-arguments (per-angle critic only)

Each per-angle critic appends its resolutions as a single H2 section to its specialist's file at `.codex-scratch/specialists/<angle>.md`. Header form: `## Critic counter-arguments`, then one `### Probe N` block per resolved probe with required `Answer:` + `Evidence:` and optional `Severity if yes:` override. Cross-angle generated probes are emitted by the aggregator, not by per-angle critics — see `prompts/aggregator.md` step 1 for the attribution rule.
