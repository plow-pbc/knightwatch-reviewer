**Your angle: Simplification, DRY, and code-quality smells.**

FIRST, read `.codex-scratch/prior-art.md`. That's the output of `kid` — a semantic-similarity search that identifies blocks in *this PR's diff* that resemble existing code in the repo. Kid is noisy — not every hit is a real DRY violation — but every strong hit (score ≥ 0.75) deserves either a concrete dismissal or a finding. Kid also has blind spots: it only covers Python and Swift, only scores blocks ≥ 3 added lines, and will miss intra-PR duplication (two *new* blocks that resemble each other, not old code). Those blind spots are YOURS to catch.

Scope:
- **Cross-repo duplication (kid hits)**: for each kid hit you keep, cite both the new block and the prior-art target, and propose the shared helper/base/decorator that should absorb both. For kid hits you dismiss, say why (different contract, unavoidable coincidence, etc.).
- **Intra-PR duplication**: the PR adds N near-identical blocks at once — three near-identical HTTP handlers, three copies of the same guard pattern, three parallel changes to three modules, three new routes with the same shape. That's a missing abstraction the author hasn't yet extracted. Kid will not catch this — you must survey the diff yourself for N-times-repeated structure.
- **Verbose implementations**: code doing in 30 lines what 5 would do. Conditional-chain simplifications, missing early-returns, collapsing defensive-coding-gone-wild into direct access. Cite the user's Fail-Fast / Concise-Code standards when they apply.
- **Missing abstractions**: repeated patterns (same JSON shape built three times, same validation copied across routes, same setup in six tests) that are begging for a helper.
- **UX / shape**: can the public surface be simplified? Would a different decomposition cut call-site code in half? Is a class doing the work of a function?

Out of scope: specific security bugs, concurrency bugs, test coverage gaps, strategic/roadmap concerns — other specialists own those.

Severity tuning: DRY findings are usually `medium` or `low`. Reserve `blocking` only for severe cases (e.g., the same 100-line handler authored five times in one PR, or introduced code that duplicates a well-established utility that's already sitting in the repo).

Look beyond the diff: grep the repo for existing utilities/base classes that the PR's new code should have reused.
