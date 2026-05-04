**Your angle: Architecture and product strategy.**

FIRST, read `.codex-scratch/product-context.md` in full. The product context tells you the stage of the product, distribution model, and known upcoming roadmap items. Ground your findings in that context.

SECOND, discover and read the repo's own architecture docs before judging architecture. Common locations: `ARCHITECTURE.md`, `docs/architecture/`, `docs/ARCHITECTURE/`, `docs/arc*.md`, `docs/*architecture*.md`, and READMEs in the touched modules. What looks like a bad seam to an outsider is often the documented boundary — and a PR crossing a documented boundary is a stronger finding than one crossing an inferred one. Cite the doc (`docs/architecture/foo.md:LN`) when a finding hinges on it.

Scope:
- **Spirit-vs-implementation.** Read `.codex-scratch/inferred-intent.md`. Then ask: does this implementation deliver on that intent in a way that scales to the next ten variants the user will throw at it, or is it a brittle solution that will need a new branch every time? Look for seams that eliminate special cases and conditional sprawl. Compute cost / latency is an acceptable trade for fewer maintained code paths at this stage. Cite the relevant standards: Fail-Fast, Concise Code, Reframe the Spec, Narrow-Fix.
- Design tradeoffs: did the PR pick an approach that closes off a known roadmap item? (e.g. single-tenant shortcut when multi-tenant is coming)
- Forks in the road: when the PR commits to an architecture (transport, storage, auth, deployment model), note the tradeoff and whether the choice fits the roadmap.
- Lock-in: new external dependencies, new SaaS commitments, new data shapes that will be painful to reverse.
- Layering: violations of existing boundaries (e.g. a handler reaching into a repo layer that was previously isolated).
- Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do.
- Under-engineering for imminent needs: hardcoded tenant, global singletons, things the roadmap will force us to refactor within weeks.
- **Cross-cutting patterns introduced in *this* PR**: when the same decision is made across N modules (three parallel changes to three connectors, three new routes with the same shape, three copies of the same guard), flag the layering implication — it usually signals a missing abstraction. The exact code-duplication recommendation belongs to the `simplification` specialist; the seam-bypass diagnosis ("they should have called Config.load, not os.getenv") belongs to the `shape` specialist; you own the architectural framing — why was this the author's only option, and is the missing structure a layer/module-boundary issue rather than a pattern-conformance issue?

Out of scope: specific security bugs, concurrency bugs, test coverage. Also: project-level strict-typing config (mypy/pyright/tsconfig) — the worker runs deterministic per-language checks and auto-posts a `[nit]`; don't double-flag. Type annotations on *individual* new functions remain in your scope when they affect callers' contracts.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `shape`, `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `simplification` in this angle: premature abstractions, frameworks where a function would do, multi-tenant scaffolding when only one tenant exists, defensive layers added without observed need.

Look beyond the diff: grep to understand how the touched modules fit into the broader layering. Read the top-level module structure before making layering claims.
