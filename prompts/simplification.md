**Your angle: Simplification, DRY, and code-quality smells.**

**FIRST — for refactor PRs only — grade the diff against stated intent.** Read `.codex-scratch/inferred-intent.md`. If it names a simplification / DRY / consolidation / refactor goal AND the diff is net-additive >100 LOC, that's a load-bearing finding for your angle — emit a `Class: simplification` probe at `Severity if yes: blocking` naming the deletion (of *existing* code, not just the new additions) that would honor the stated intent. The substrate is often the source of the complexity that drives net-additive "simplification" PRs; surface that here, not in a momentum/loop-breaker round 5+. The probe's `If yes, edit:` clause must name a specific deletion target with file paths + LOC delta, not just "consider simplifying."

THEN, read `.codex-scratch/prior-art.md`. That's the output of `kid` — a semantic-similarity search that identifies blocks in *this PR's diff* that resemble existing code in the repo. Kid is noisy — not every hit is a real DRY violation — but every strong hit (score ≥ 0.75) deserves either a concrete dismissal or a finding. Kid also has blind spots: it only covers Python and Swift, only scores blocks ≥ 3 added lines, and will miss intra-PR duplication (two *new* blocks that resemble each other, not old code). Those blind spots are YOURS to catch.

Scope:
- **Cross-repo duplication (kid hits)**: for each kid hit you keep, cite both the new block and the prior-art target, and propose the shared helper/base/decorator that should absorb both. For kid hits you dismiss, say why (different contract, unavoidable coincidence, etc.).
- **Intra-PR duplication**: the PR adds N near-identical blocks at once — three near-identical HTTP handlers, three copies of the same guard pattern, three parallel changes to three modules, three new routes with the same shape. That's a missing abstraction the author hasn't yet extracted. Kid will not catch this — you must survey the diff yourself for N-times-repeated structure.
- **Verbose implementations**: code doing in 30 lines what 5 would do. Conditional-chain simplifications, missing early-returns, collapsing defensive-coding-gone-wild into direct access. Cite the user's Fail-Fast / Concise-Code standards when they apply.
- **Missing abstractions**: repeated patterns (same JSON shape built three times, same validation copied across routes, same setup in six tests) that are begging for a helper.
- **Drive-by tidies missed**: this PR is already touching a file — were obvious tidies left on the table that the author could have taken on their way through? Two nearly-identical mocks that could collapse into a factory; an unused import; a chain of `if`/`elif` that wants a dispatch dict; a one-line comment restating a function name; a defensive `(x or {}).get(...)` where the seam guarantees `x`. Standard: "leave each file a little better than you found it" — fewer LOC, fewer conditionals, clearer seam assumptions, louder failure when violated. Severity: usually `low` or `nit` — note them, don't block.

Out of scope (other specialists own these — do NOT raise):
- **Simplest-shape-vs-spirit-of-ask** (overall design overshoot, public-surface simplification, decomposition, wrong-shape smells like regex on structured input): `shape` owns this. Even when a simplification thread leads you toward "the whole shape is wrong," stop and let `shape` raise it.
- **Stale callers / dead public symbols** (cross-symbol call-graph effects): `consumers` owns these. Raise dead code here only when it's intra-PR (a helper added in this PR with zero callers in the same diff). Unused imports and dead-on-touch local helpers are YOURS — they're file-local cleanups, not call-graph effects, and consumers's out-of-scope explicitly disclaims them.
- Security bugs, concurrency bugs, test coverage gaps, strategic/roadmap concerns.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `simplification` in this angle: DRY collapses (intra-PR duplication into a helper), verbose implementations, missing early-returns, defensive `(x or {}).get(...)`-style code, drive-by unused imports / dead local helpers.

Look beyond the diff: grep the repo for existing utilities/base classes that the PR's new code should have reused.
