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
