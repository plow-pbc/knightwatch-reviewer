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
