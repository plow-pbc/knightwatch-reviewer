# Coding Standards

Canonical coding principles for my projects. Referenced from `~/.claude/CLAUDE.md` (all coding work) and `~/.claude/REVIEW_PRACTICES.md` (automated + human review). Hand-curated — auto-tuning from `learn-from-replies.sh` targets `COMMENT_REVIEW_MISTAKES.md` only, not this file.

## Team Context

Small team (~3 engineers), ~10 active users, moving fast. Design bias:

- **Elegance > defensive sprawl.** Code that reads cleanly and scales beats code that handles every hypothetical failure mode.
- **Concise code that fails loudly > verbose, defensive code with brittle special cases.** We prefer short code that captures the *spirit* of the spec or desired UX and crashes when its assumptions break, over long code that bakes in handling for every edge case the author imagined. Each special case calcifies a decision and invites the next one. When the spec seems to require contortions, the right reflex is to question the spec (see "Reframe the Spec" below), not to add branches.
- **Engineer time > compute time.** When picking between approaches, prefer the one that scales in *engineers' time* — fewer special cases, fewer conditional branches, fewer files to touch when the next variant lands. A solution that costs more compute or runs slower is fine if it eliminates a class of code we'd otherwise have to maintain. Lookup tables, hand-coded heuristics, and per-case branches are brittle in a way the bill-of-materials never reflects.
- **Loud breaks.** If an assumption is wrong, the code crashes — it does not silently degrade. No swallowed errors, no fallback chains, no softened tests.
- **Architecture decisions should not accrue tech debt.** A "fine-for-now" choice that the roadmap will force us to unwind in six weeks is a medium-severity finding, not a nit — flag it and propose the seam.
- **DRY and missing-abstraction findings are first-class.** They are not style polish. A missing abstraction today is tomorrow's bug surface × N.

Reviewers — human and automated — weight findings with these values in mind, not just raw severity.

## Fail-Fast / Offensive Programming

Write fail-fast code. If an assumption is wrong, the code crashes — it does not silently degrade.

- Access data directly: `x["key"]`, not `(x or {}).get("key", default)`
- No fallback chains: `a or b or c or default` — pick one source of truth
- No swallowed errors: `try: ... except: pass`
- Avoid `try/except` / `try/catch` in core logic; catch only at system boundaries (user input, external APIs)
- When encountering existing defensive code, rip it out and run tests. If they pass, the defense was bloat.

**Review question:** *Is this code non-defensive? Does it crash loudly when its invariants are violated?*

## Concise Code (LOC is a cost)

Every line earns its place. Verbose code is more bugs, more review time, more drift.

- Don't add `if x:` guards when `x` should always be truthy
- Don't introduce helpers/abstractions for one or two call sites
- Three similar lines > premature abstraction
- When I propose verbose code, push back
- Prefer direct access over fallback chains and nested conditionals
- Every conditional is a maintenance burden — all things equal, avoid it. Each `if`/`else` branch is a state the next reader has to hold and the next change has to update. When you find yourself adding a special case, ask whether a different seam would let you delete it instead.

**Review question:** *Is this concise and elegant, or is there extra code that doesn't pay for itself?*

## Anti-Bloat — Don't Propose These Remedies

LOC is a stand-in for **conditionals + special cases + defensive branches + new abstractions** — those are the actual cost being managed. Each calcified branch survives every future refactor and shapes the next change. The test for any edge-case handler: *does the edge case actually happen, or will it in the near future?* If neither, the remedy is bloat regardless of how the line count nets out.

When reviewing a PR or applying a bot's suggestion, **don't propose** (or accept) these patterns:

- **assert→raise+log replacements outside trust boundaries.** `Fail-Fast` prefers the assertion crashing loudly on internal-caller bugs.
- **isinstance / type-validation checks for internal callers.** Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers.
- **state-reset / fallback writes** for hypothetical pollution ("set X = default in case prior init left it dirty"). Unless the polluting scenario is observed in production, the fallback locks the surrounding code into preserving both branches forever.
- **wrapper dataclasses, snapshot views, or new DI seams** for one call site. These are remedies for repeated problems; "Three similar lines > premature abstraction" applies.
- **streaming / incremental rewrites** of small in-memory operations on theoretical perf or OOM grounds. Cite a measured failure or skip.
- **companion tests, CI guards, or regression coverage for unreachable scenarios** ("no test for prod re-enable", "no test that this can't happen"). Tests calcify too — a test for a scenario that doesn't occur preserves a contract that may have been wrong, and the next refactor has to keep that contract working forever.

When pushing back on a bot finding whose remedy hits one of these patterns, cite this section by name (`Anti-Bloat`) and apply the LOC-negative or branch-negative version of the fix.

**Review question:** *Does the proposed remedy add a branch / handler / abstraction for a scenario that hasn't been shown to actually occur?*

## Broken-Glass Test

> "For the entire beta period, people practically had to walk over broken glass to start using shared channels: for me to even send you an invitation, I'd first have to find out your 'workspace URL' which very few people knew." — Stewart Butterfield on Slack's shared-channels beta

At our scale (~10 users, pre-PMF — see `.knightwatch/review-priority.md`), the reviewer's job is to catch real bugs and push for elegant code that lets us discover product-market fit. It is *not* to push for handling user types, scale, or behaviors we don't have yet. Architecture complexity for hypothetical scenarios is broken-glass cleanup — calcified branches that have to be preserved through every future refactor — disguised as diligence.

### Voice posture: questions over prescriptions

Default voice on every non-bug finding is **inquisitive**. State the #1 assumption explicitly as a question. The reviewer is the team's "could-this-actually-happen" check, not its "you must address this" enforcer.

Declarative voice is reserved for high-confidence bugs only. The bar: *can you cite the failing path, the user-observable outcome, and the line where the contract breaks?* Examples that meet the bar — reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause. Examples that don't meet the bar — "this could break if X," "this would scale poorly to N users," "this is missing a guard for Y."

### Question template

```
Will [user state X / data shape Y / scale Z]?
- If yes, [proposed action].
- If not, consider cutting [proposed action] — adds complexity and makes PMF iteration harder.
[Optional: recommendation given the operating point.]
```

The phrase **"adds complexity and makes PMF iteration harder"** is load-bearing for scope-creep findings. It names the *cost* of the additive remedy so the author chooses between two visible costs (broken-glass risk vs. complexity), not between "fix the issue" and "ignore the reviewer." Acceptable variants when the cost differs: "calcifies a branch the next refactor must preserve," "trades simple-and-fail-loud for layered defenses."

### Worked-example reframings

**Taxonomy demand for first-instance directory** — declarative version: *"`team-skills/` is a new repo storage class with no taxonomy or guard contract; the taxonomy and guard should name it."* Reframed:

> Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder. The existing protected-path guard already fails loudly if anyone ships `team-skills/` content into the runtime.

**Unrelated guard-update ask** — declarative version: *"`scripts/check_protected_paths.py` still omits `plow-local-token`; add it to the existing `user-state` rule."* Reframed:

> Has any agent task touched `plow-local-token` in the last fortnight? If yes, sweep this in a separate cleanup PR. If not, the guard gap is theoretical; consider cutting it from this PR's scope — adds complexity and makes PMF iteration harder.

**Demand for layer-by-layer regression tests** — declarative version: *"This bug-fix pass still ships without focused regression tests; 1-2 tests pinning `import_csv()`, `import_legacy_log()`, and `next_batch()` would cover the important paths."* Reframed:

> Has the upstream CSV format changed twice in the last quarter? If yes, 1-2 in-memory SQLite tests pinning the import path are worth ~10 LOC each. If not, fail-loud-on-bad-shape is acceptable; consider cutting the layer-by-layer coverage demand — adds complexity and makes PMF iteration harder.

**Review questions:**
- *Is this remedy solving for a user, user type, or behavior that doesn't yet exist? At our scale, would the failure even be visible in production today?*
- *Did this finding name its #1 assumption as a question, or was it asserted as if the assumption is settled?*
- *For scope-creep findings: did the question name the cost (adds complexity / calcifies a branch / makes PMF iteration harder)?*

For per-repo current operating points + concrete contrast pairs, see `.knightwatch/review-priority.md` in each tracked repo.

## Incremental Improvement

Leave each file a little better than you found it. "Better" = fewer LOC, fewer conditionals, fewer special cases, clearer assumptions at the seams it consumes and exposes, and louder failure when those assumptions break. A bit slower at runtime is fine. If you're already editing something and spot an obvious tidy — two nearly-identical mocks that could collapse into a factory, an unused import, a one-line comment that restates the function name — take it.

Split the work: get the business-logic change working and tests passing first, then do the cleanup as a **separate commit**. A reviewer should see the behavioral change cleanly on its own and the cleanup as its own diff.

- Don't block on unrelated cleanup — keep the focused change landable.
- Don't sneak cleanup into the feature commit — it hides the real change.
- If the cleanup is big enough that it deserves its own PR, make it its own PR.

**Review question:** *Did the author leave the file measurably better than they found it, without muddying the business-logic diff?*

## DRY: Find Existing Logic Before Adding New

New functions, user-facing strings, and status reports must be grep'd for near-duplicates before approval. Parallel implementations are the single most common LLM defect.

- Grep the repo for similar function names and near-duplicate strings.
- If a similar implementation exists, unify rather than adding alongside.
- Duplicate logic with an existing repo site: *blocking: dry* — cite the existing site by path.
- Intra-PR duplication (N near-identical blocks in the same diff) is a missing abstraction: *medium: dry*.

**Review question:** *Is this DRY with the rest of the codebase? Are we re-using existing functions where we should?*

## Regression Risk

New code must not quietly change existing business logic. Any change to a function's contract, return shape, side effects, or error behavior needs an explicit callout.

- Changed semantics of an existing function without updating call sites: *blocking: regression*.
- New conditional branch that alters legacy-path behavior: *medium: regression* unless proven safe.
- A bug fix without a regression test that exercises the old-bug path is *blocking: tests*.

**Review question:** *Does this introduce regressions? How does it change existing business logic, and is that change intentional and covered?*

## Reframe the Spec

Any single new block over ~20 LOC is a smell. Pause and ask whether a spec or UX tweak would delete most of that code. Don't silently accept contorted code to match a literal ask — name the simpler alternative so the author can choose.

- If satisfying a spec detail is adding notable complexity: *low: spec-reframe* with the alternative described in one sentence.
- If the complexity is structural (not just a spec ask): escalate to *medium*.

**Review question:** *Would a small change to the spec or UX accomplish the spirit of the request while significantly reducing complexity?*

## Name the Shape

Before writing code, name the *class* of problem: parsing, validation, dispatch, retry, auth, serialization, formatting, batching, state, idempotency, audit logging, feature-flag gating. Each is a recurring shape with a preferred home in the codebase. Pick the shape first; the lines come second.

Two failure modes:

- **Wrong shape.** Regex when the upstream could emit structured data. Hand-rolled validation when pydantic/zod is already in use. `if kind == "A": ... elif kind == "B": ...` instead of a dispatch dict. Bool-soup state instead of an enum. The code works on today's input and silently breaks on the next variant. Regex is the canonical example — treat regex on string-typed input as a smell that *structure got discarded upstream*. The fix is usually to make upstream emit data, not to grow the regex.
- **Five shapes for five similar problems.** Each new feature lands with its own auth check, its own retry loop, its own date format, its own error shape. Each PR looks fine in review; the policy now lives in 17 places. If you are the second instance of a missing shape, *that* is the moment to introduce one — not the fifth.

Before writing: grep for how the codebase already handles this class. If a shape exists, conform. If none exists and you are not the first instance, you have just discovered tech debt — flag it.

**Review question:** *Did the author name the problem class and conform to (or establish) the codebase's shape for it, or did they solve only the literal symptom?*

## Generalize the Fix (Narrow-Fix)

A fix tied to one reported input (regex, string equality, hard-coded special case) is a narrow fix. Ask: what is the next variant of this input, and does this code cover it?

- Narrow fixes that won't survive the obvious next bug are *medium: narrow-fix*.
- If the root cause is systemic (parsing, state machine, schema), fix the class, not the instance.
- `Narrow-Fix` is only valid on the FIRST occurrence of a class on a given PR. A second instance of the same class on the same PR escalates to `Bug-Class-Recurrence` (below) — repeating `Narrow-Fix` review after review erodes the tag's signal and traps the author in a local-fix loop.

**Review question:** *Is this a root-cause fix or a patch for one symptom?*

## Bug-Class-Recurrence

When the same class of bug has been flagged 2+ times on the same PR — across reviews, or across multiple findings within a single review — the right finding is structural, not local. Patching individual instances has reached diminishing returns; the right move is to name the architectural shape that would make the entire class impossible (per-session value types, sealed enums for state, single-owner data, registries, dispatch maps) and recommend that.

A `Bug-Class-Recurrence` finding **replaces** — does not append to — the individual local findings of the same class. Listing both anchors the author on the local fix; they will fix the local one and the structural finding becomes background noise.

If you genuinely cannot name the structural alternative, downgrade to `medium` and surface as an Open Question instead. Do NOT fall back to listing local fixes.

- Same class flagged in 2+ prior reviews → *blocking: bug-class-recurrence*.
- 2+ findings of the same class in the current review draft → *blocking: bug-class-recurrence* (collapse them into one structural finding).
- Supersedes `Narrow-Fix` after the first occurrence of the class.

**Review question:** *Is this the Nth instance of a recurring shape? If so, what's the structural alternative — the one piece of code that would make every instance disappear?*

## Tests

Tests must fail loudly when something is broken. Never add graceful degradation, skips, or soft failures to tests. A broken test should crash, not pass silently.

- Test **user experience and business logic**, not self-evident language/runtime behavior
- A change crossing multiple layers (e.g. Swift → plowd → API) needs 1–2 focused behavior tests, not exhaustive layer-by-layer coverage
- Prefer shared fixtures/factories over inline setup blocks
- Refactor repeated test payloads, DB rows, and lifecycle setup into helpers
- Remove low-value helper tests before adding more boilerplate
- **Run `just test` after every change** — features, fixes, refactors, anything. Don't return to the user with a red bar.
- **`just test` must pass before merging.** The pre-merge gate is non-negotiable: no merge on a red bar, even if the change is "obviously" safe. If a repo doesn't have a `just test`, add one before landing the first PR that needs gating.

New tests in the plow repo should align with `docs/TEST_PATTERNS.md` and `./tests/README.md` — the repo's own test-writing conventions. Tests that diverge from those patterns without a good reason are a *low: tests* finding.

**Review question:** *Are the tests loud-on-failure, aligned with the repo's test patterns, and focused on behavior rather than implementation details?*

## Migrations

Never hand-write Alembic migrations. Always use `alembic revision --autogenerate` to generate them from model changes.

**Review question:** *Was this migration autogenerated?*

---

## How reviewers should weight these

For any PR, reviewers rank findings by severity first (`blocking` → `medium` → `low` → `nit`), then within a severity band by:

1. **Tech-debt and architectural findings** (missing abstraction, DRY violation, design that won't survive the roadmap) — these compound.
2. **Broad-correctness findings** that affect many paths or users.
3. **Surface-area findings** touching many files.
4. **Localized fixes and style** rank LAST within their band.

If two findings compete and one is "code that won't scale as the team grows" vs. one that is "line-level style," the scalability finding wins the higher slot even at the same severity.

# Review Practices

Coding and review standards for the plow codebase.

## Fail-Fast / Offensive Programming

Write fail-fast code. If an assumption is wrong, the code crashes — it does not silently degrade.

- Access data directly: `x["key"]`, not `(x or {}).get("key", default)`
- No fallback chains: `a or b or c or default` — pick one source of truth
- No swallowed errors: `try: ... except: pass`
- Defensive code belongs only at system boundaries (user input, external APIs)
- When encountering existing defensive code, rip it out, run tests. If they pass, the defense was bloat.

## Tests

Tests must fail loudly when something is broken. Never add graceful degradation, skips, or soft failures to tests. A broken test should crash, not pass silently.

- Test **user experience and business logic** — not self-evident language/runtime behavior
- A change crossing multiple layers (e.g. Swift → plowd → API) needs 1-2 focused behavior tests, not exhaustive layer-by-layer coverage
- Prefer shared fixtures/factories over inline setup blocks
- Refactor repeated test payloads, DB rows, and lifecycle setup into helpers
- Remove low-value helper tests before adding more boilerplate

## Migrations

Never hand-write Alembic migrations. Always use `alembic revision --autogenerate` to generate them from model changes.

## Concise Code

Every line earns its place. LOC is a cost, not a feature.

- Don't add `if x:` guards when x should always be truthy
- Don't introduce helpers/abstractions for one or two call sites
- Three similar lines > premature abstraction
- Prefer direct access over fallback chains and nested conditionals
- Keep modules DRY where repetition is real, not theoretical
- Avoid `try/except` or `try/catch` in core logic; fail fast and handle errors only at boundaries

## Approval Verdicts

Default verdict is **APPROVE** unless there are `blocking` findings. Medium, low, and nit findings appear in the review but do not prevent approval. Only `blocking` warrants `VERDICT: COMMENT`.

When approving with nit or low items worth noting, use `VERDICT: APPROVE — pending: <item1>, <item2>` so the approval body communicates what minor things would be nice to clean up.

## Pre-Verdict Checklist

Before writing your verdict, for any PR that adds a new function, a new user-facing string, a fix scoped to a single input, or any single new block over ~20 LOC, run these checks inside the checked-out repo:

1. `grep` for near-duplicate function names and strings. Flag hits as *blocking: dry* with the existing path.
2. For fixes scoped to one input, name the obvious next variant and check whether it's covered. If not, *medium: narrow-fix*.
3. If the PR adds complexity to honor a spec detail verbatim, name a UX or contract change that would delete most of it. *low: spec-reframe*.

## Tooling: kid vs grep

Prior-art lookup runs via two paths depending on file type:

- **`*.py`** — semantic search via `kid` (indexes `~/Hacking/plow-kid`, injected into the review as a "PRIOR ART" section). Treat kid hits as leads, not verdicts: each match is either dismissed with a reason (different contract, unavoidable duplication) or raised as a DRY finding.
- **`*.swift`, `*.ts`, `*.tsx`, everything else** — fall back to `grep` inside the checked-out repo for function names and near-duplicate strings (Pre-Verdict Checklist step 1). Kid Swift support is a planned follow-up; until then, do not assume kid covers Phoenix or frontend code.

Do not silently trust "no kid hits = DRY-clean". Confirm which path applied.

## Worked Example (DRY)

Bootup "warming up" status was previously reported in three places with divergent strings and logic. Unified to `RuntimeHeaderState.isWarmingUp` and one label in `app/Phoenix/ActivationState.swift`. A reviewer should have caught the third divergent copy on arrival. That is what "grep before you approve" looks like in practice.

# Testing Practices

Use this as the default testing policy unless a repository has stricter local
instructions.

## Core Philosophy

- Follow red -> green -> refactor TDD: write the failing test first, implement
  the smallest change that passes, then clean up while tests stay green.
- Never hide failures. Do not skip, xfail, comment out, or weaken a failing
  test to make a suite pass.
- If config, credentials, services, dependencies, or databases are missing,
  set up the environment or ask for the missing secret. Do not silently bypass
  the test.
- Test behavior, business rules, ranking outcomes, safety gates, and meaningful
  regressions. Do not test self-evident language, framework, or library
  behavior.
- Every valuable test should answer: what business requirement would be broken
  if this failed?
- Keep setup compact and readable. If a helper does not reduce real repetition
  or clarify the test's intent, do not add it.

## Fixtures And Factories

- Prefer shared fixtures and factory helpers over large inline setup blocks.
- Use factory fixtures for repeated payloads, DB rows, model objects, API
  clients, and server lifecycle setup.
- Prefer one factory with defaults and overrides over multiple fixture variants
  for the same data shape.
- In each test, customize only what matters for that behavior. The test body
  should make the business case obvious.
- Raise common factories when they are reused across suites. Keep suite-specific
  setup in the suite's `conftest.py`; keep single-test setup local to that test.
- Do not duplicate equivalent factories across test suites. One reusable source
  of truth is easier to update when schemas or models change.
- For typed Python factories, use a small `Protocol` when the callable shape
  matters instead of widening to `Any`.
- For workflow or e2e tests that may run in parallel, generate unique test data
  through the factory, such as UUID-suffixed names or emails. Do not hardcode
  shared identifiers.

Example:

```python
@pytest.fixture
def payload_factory() -> Callable[..., dict[str, object]]:
    def create_payload(**overrides: object) -> dict[str, object]:
        defaults: dict[str, object] = {
            "user_name": "Alice",
            "consent": True,
            "relationship_type": "romantic",
            "communication_goals": "better listening",
        }
        return {**defaults, **overrides}

    return create_payload


def test_partial_payload(payload_factory):
    payload = payload_factory(communication_goals=None)

    assert payload["communication_goals"] is None
```

Avoid this:

```python
@pytest.fixture
def full_payload_data():
    ...


@pytest.fixture
def partial_payload_data():
    ...


@pytest.fixture
def minimal_payload_data():
    ...
```

## Mocking

- Mock external boundaries in unit and integration tests when the external
  service is not the behavior under test.
- Keep mocks targeted. Avoid long mock chains that mirror implementation
  details.
- Do not mock live/e2e dependencies in tests whose purpose is to verify live
  round trips.
- Do not assert that a mock returned the value you configured it to return;
  assert the behavior that depends on that value.

## Test Shape

- Use parametrization for variants of the same behavior: field mappings,
  role-based cases, boundary values, and business-rule matrices.
- Do not write separate near-identical tests for each value when a single
  parametrized test would make the rule clearer.
- Do not parametrize when cases have different setup, verify different behavior,
  or become harder to understand when combined.
- Test docstrings should explain business value, not restate mechanics. Prefer
  "Ensures incoming messages are queued so worker downtime does not drop them"
  over "Tests POST /webhook returns 200."
- Compute expected values through the domain formatter or canonical source when
  appropriate. Avoid brittle hardcoded strings copied from formatter output.

## Test Types

- Unit tests isolate complex business logic with fake or in-memory dependencies
  and mocked external services.
- Integration tests verify component interaction and endpoint contracts with
  fast local dependencies and mocked external services.
- E2E mocked tests verify complete workflows with real internal infrastructure
  where needed and mocked external services.
- E2E live tests use real external APIs. They should cover only critical prompt
  or provider behavior, avoid mocks for the live boundary, and cache expensive
  calls where practical.
- Smoke tests should validate deployed system health through public boundaries,
  usually HTTP-only.

## Validation Commands

- Use the repository's test runner, usually `just test`, as the full validation
  command.
- Use fast commands such as `just test-fast` only for iteration. If only the
  fast suite ran, say so plainly and do not claim full tests pass.
- Do not use raw `pytest` when the repo documents a wrapper command; wrappers
  often handle linting, env loading, database setup, secret scanning, or live
  test prerequisites.
- Run the narrowest meaningful command during iteration, then the full bar
  before presenting changed code when feasible.
- If only docs or static assets changed, state that tests were not run.

## Failure Workflow

1. Read the failure and identify what the test expected versus what happened.
2. Fix the root cause: broken code, stale fixture, missing config, service not
   running, or incorrect environment.
3. Rerun the relevant test command.
4. Run the full repository validation command before reporting done when
   feasible.

## Known Review Mistakes (avoid repeating these)\n# Comment Review Mistakes

Patterns where the automated reviewer has over-called, mis-calibrated, or otherwise got it wrong.
Updated automatically from author replies to review comments.

Each entry is a **pattern**, not a case study: no specific PR numbers, no specific file paths, no team-specific details. The goal is a durable principle future reviews will apply.

1. Don't flag missing tests as blocking when 1–2 focused behavior tests or smoke checks cover the user-visible risk. A change needs proof the behavior holds, not layer-by-layer coverage.
2. Don't require new tests for PRs that only change documentation, manifests, workflow YAML, or artifact pins. Note gaps as low/nit at most.
3. APPROVE when there are no findings medium or higher. Low, and nit findings are noted in the review but do not prevent approval. Only `blocking` `high` and `medium` -tagged findings warrant `VERDICT: COMMENT`.
4. When approving with nit/low findings, prefer `VERDICT: APPROVE — pending: <nit1>, <nit2>` so the approval body communicates what minor things would be nice to clean up. e.g. "Approving — pending: tighten empty-string guard in pushSlackAccount, add one argv-ordering test"
5. Don't demand duplicate in-repo producers when an existing out-of-band source already populates the data and integration checks cover consumption. Avoid forcing redundant architecture in feature PRs.
6. Don't propose replacing `assert X` (or other fail-fast guards) with explicit raise + logging context. The user's `Fail-Fast` standard prefers the assertion crashing loudly on internal-caller bugs; logging+raise is bloat unless the code sits at a trust boundary.
7. Don't propose `isinstance` / type-validation checks for internal callers. Validation belongs at trust boundaries (user input, external APIs); internal calls trust their callers — adding type guards calcifies the call shape and contradicts `Concise Code`.
8. Don't propose state-reset / fallback writes ("set X = default in case prior init left it dirty") unless the polluting scenario is observed in production, not theoretical. A fallback chain for module-global pollution mostly fires in tests and locks the surrounding code into preserving both branches forever.
9. Don't propose wrapper dataclasses, snapshot views, or new DI seams when a 1–2 line direct fix solves the same problem. Snapshots and freeze-views are remedies for *repeated* problems, not first instances; "Three similar lines > premature abstraction" applies.
10. Don't propose streaming / incremental rewrites of small in-memory operations on theoretical perf or OOM grounds. Cite a measured failure or skip — the streaming version typically adds 15+ LOC of state machine, and the in-memory version costs nothing on the inputs that actually arrive.
11. Don't propose adding companion tests, CI guards, or regression coverage for scenarios that haven't been shown to actually occur ("no test for prod re-enable", "no test that this can't happen"). Tests calcify too — every test fixed in stone preserves the contract under test, even when the contract was wrong. Cite a measured failure, an in-flight class of bug, or skip.
12. Don't propose remedies that solve for users, scale, or behaviors we don't have yet. The product is small (see `.knightwatch/review-priority.md`); remedies should match that reality. The elegant + fail-loud version of a fix is preferred over the defensive version that silently handles a hypothetical population.
13. Lead non-bug findings with the #1 assumption as a question, not as an assertion. For scope-creep findings specifically, the question must name the cost: *"adds complexity and makes PMF iteration harder."* Declarative voice is reserved for high-confidence bugs (reproducible failure, broken contract with concrete user impact, security/data-integrity regression with traceable cause). When a finding is asserted but the assumption could go either way, that's a calibration miss — reframe it.