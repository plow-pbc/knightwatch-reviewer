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

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `tests`, `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `simplification` in this angle: over-tested edge cases, mocks that pre-empt the real implementation, helpers added with one call site, fixture machinery heavier than the test it supports.

