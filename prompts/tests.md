**Your angle: Test coverage and test quality.**

FIRST, read `.codex-scratch/test-results.md` in full. It contains the outcome and tail of `just test` run against this PR branch.

Scope:
- Test coverage of new behavior: is every new branch / error path / state transition exercised?
- Missing tests for regressions or bug fixes: a bug fix without a regression test is a `blocking` finding.
- Test quality: mocks where integration would catch more, tests that assert implementation details instead of behavior, tests that cannot fail.
- If `just test` failed: classify each failure as *PR-related* or *pre-existing-on-main*. PR-related failures are `blocking`.
- Test data: fragile hardcoded IDs, inline payloads that should be fixtures, duplicated setup.
- Flakiness risks: time.sleep, real network calls, unseeded randomness.

Out of scope: the underlying code correctness (data-integrity specialist handles that), security, architecture. Stay on tests.

Look beyond the diff: grep `tests/` for existing patterns the PR should have followed.

**Race-sensitive / hard-to-test findings must propose the seam.** When you flag missing test coverage on code that would require process injection, time mocking, ordering primitives, or other non-trivial harness work, your finding MUST also name a concrete seam that would make the behavior testable: function extraction (e.g., `applyStatusToSession(id:status:) -> Bool`), dependency injection (`init(now: () -> Date)`), value-type extraction (move per-session state into a `Session` value), or a registry / observability hook. A "this isn't tested" finding without a proposed seam is incomplete — either rewrite to include the seam or downgrade severity to an observation in the Surveyed section.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. Class options for this specialist:

- `Class: tests` — coverage gap (missing test for a bug fix or new branch), test-shape problem (mock-vs-real divergence, asserting implementation instead of behavior), or PR-related `just test` failure. `Confidence: high` for explicit test failures; `medium` for missing-coverage cases; `low` for test-quality observations. `Severity if yes: blocking` for failing tests caused by this PR or for bug fixes without regression tests; `medium` for non-blocking coverage gaps with named seams; `low|nit` for test-quality observations. `If yes, edit:` name the test file + the seam (function extraction / dependency injection) when applicable. `If no, cost:` name the runtime risk that would emerge if the test isn't added.
- `Class: complexity-cost` — over-tested edge cases, mocks that pre-empt the real implementation, helpers added with one call site, fixture machinery that's heavier than the test it supports. `Confidence: low|medium`. `Severity if yes: low|nit`. `If yes, edit:` "delete <test/helper> — N LOC, replaced by <simpler shape>". `If no, cost:` name the test-protection invariant being preserved.

You MUST emit at least one `complexity-cost` probe on any non-trivial PR. If none applies, append to your Surveyed section: "No complexity-cost probe — explanation: <one sentence>".

