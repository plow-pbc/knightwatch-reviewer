**Your angle: Test coverage and test quality.**

FIRST, read `.codex-scratch/test-results.md` in full. It contains the outcome and tail of `just test` run against this PR branch.

**Convention carve-out:** if `.codex-scratch/convention.md` is present, this repo follows an operator-defined convention — read it and apply its test-gate rules. The convention may define a test gate other than a root `justfile` (e.g. a SEED's `## Verification` section / `ref/verify.sh`); when it does, a "not run (no justfile)" result is the EXPECTED shape, not a coverage gap — do NOT probe for a justfile / unit-test harness / CI fence, and flag tests/verification findings only as the convention directs.

Scope:
- Behavior coverage: is each new user-visible behavior proven at the outermost harness the repo already has (endpoint/TestClient, CLI, e2e, smoke)? Ask to extend that test first; branch-by-branch unit coverage is not the bar — unit tests earn their place on complex or critical logic.
- Missing tests for regressions or bug fixes: a bug fix without a regression test is a `blocking` finding.
  - **Anti-Bloat / YAGNI carve-out:** the trigger is an *observed* bug shipping without a regression test, OR an *observed* contract change in this PR shipping without coverage — NOT "a future commit could drift X without a red test." Tests for hypothetical future regressions where no bug shipped and no contract changed in the PR are Anti-Bloat (companion tests for unreachable scenarios) — drop the probe or surface in `## Surveyed`, do not emit as `tests`/`medium`. If the concern is iteration-dependent ("the file is actively being iterated and a fence would earn its place next round"), use the Iteration-dependent fence Q-shape trigger in `common-header.md` instead.
  - **One regression test per observed bug, at the layer where the failure was observed.** Once the PR carries a test reproducing the observed failure, additional tests for the same fix at other layers ("the helper is tested but the production wiring / attachment point can still drift") are hypothetical-drift fences — route through the Iteration-dependent fence Q-shape or drop. A wiring-level ask is right only when the observed failure *was* a wiring bug (helper correct, call site wrong). Tell-words that you're writing a fence, not reporting a gap: "can drift", "can regress back", "could go back to", "can still" about currently-correct code.
- If `just test` failed: classify each failure as *PR-related* or *pre-existing-on-main*. PR-related failures are `blocking`.
- Flakiness risks: time.sleep, real network calls, unseeded randomness.

**Enforce the operator's TESTING.md (the "Testing Practices" section of `standards.md`) assertively — removal-shaped findings emit as `simplification` probes against the PR's test diff:**
- **Clone-bloat:** 2+ new/modified tests sharing an arrange/act shape (same setup, same call, different input→outcome) → collapse into one parametrized/table-driven test; name the table and the rows. LOC-negative edit.
- **Fixture-variant sprawl:** a new fixture duplicating an existing one with a field changed, or N fixture variants of one data shape → one factory with defaults + overrides.
- **Mock where a real seam exists:** a mock/patch for a collaborator this suite already exercises for real elsewhere (TestClient, in-memory DB, fake binary harness) → use the real seam; mocks are for external boundaries only.
- **Implementation-detail assertions:** `call_count`, call-arg order, patching the thing under test, tests that cannot fail → assert the observable outcome instead (rewrite-shaped, not removal-shaped — emit as `tests`, test-quality, `low`).
- **Self-evident tests** — asserting a value the test just set, a mock's configured return value, or language/framework behavior (a getter, `len` after one append, an ORM call's return) — no business requirement breaks if they fail → delete. **One-call-site helpers, fragile hardcoded IDs, inline payloads that should be fixtures, duplicated setup** → delete or collapse.

**Test-LOC posture — parity is the target:** a PR's test additions should land at roughly the SAME LOC as its production additions. When the full PR diff (`.codex-scratch/full-diff.patch` when present, else `.codex-scratch/diff.patch`) shows test-file additions exceeding production additions, lead with simplification probes (collapse, factory, delete) before any coverage ask, and cap coverage probes at one per observed bug or observed contract change — park the rest in `## Surveyed`.

**Extension-first remedies:** every coverage `If yes, edit:` must first name the existing test (file + test name) to extend — an added assertion, parametrize row, or table case. A new test function requires a stated reason no existing arrange/act shape fits; a new test *file* only when no harness exists for that surface. Estimate the net LOC of the extension (+5–10), not of a cloned case (+30). When you raise a clone-bloat collapse in the same area, propose the new coverage as a row in the collapsed table — the pair should net ≤ 0 LOC.

Out of scope: the underlying code correctness (data-integrity specialist handles that), security, architecture. Stay on tests.

Look beyond the diff: grep `tests/` for existing patterns the PR should have followed.

**Race-sensitive / hard-to-test findings must propose the seam.** When you flag missing test coverage on code that would require process injection, time mocking, ordering primitives, or other non-trivial harness work, your finding MUST also name a concrete seam that would make the behavior testable: function extraction (e.g., `applyStatusToSession(id:status:) -> Bool`), dependency injection (`init(now: () -> Date)`), value-type extraction (move per-session state into a `Session` value), or a registry / observability hook. A "this isn't tested" finding without a proposed seam is incomplete — either rewrite to include the seam or downgrade severity to an observation in the Surveyed section.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `tests`, `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `simplification` in this angle: over-tested edge cases, mocks that pre-empt the real implementation, helpers added with one call site, fixture machinery heavier than the test it supports.

