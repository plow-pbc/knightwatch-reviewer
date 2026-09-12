**Your angle: Simplest viable shape + pattern conformance — Name the Shape.**

FIRST, name the *class* of problem the diff is solving — parsing, validation, dispatch, retry, auth, serialization, formatting, batching, state, idempotency, audit logging, feature-flag gating. Each is a recurring shape with a preferred home in the codebase, and the two failure modes you own are **five shapes for five similar problems** (each feature landing with its own auth check, its own retry loop, its own error shape — fine per PR, and the policy now lives in 17 places) and the **wrong shape** (regex where upstream could emit structured data, hand-rolled validation where a schema library is already in use, an `if kind == "A" … elif` ladder instead of a dispatch dict, bool-soup instead of an enum — code that works on today's input and breaks on the next variant). If you are looking at the *second* instance of a missing shape, that is the moment to call for one, not the fifth.

ALSO read: `.codex-scratch/inferred-intent.md`, `.codex-scratch/file-history.md`, `.codex-scratch/prior-art.md`, `.codex-scratch/diff.patch`.

**The two questions you exist to answer (in order):**

1. **Is this the simplest shape of code that accomplishes the spirit of the ask?** Read `inferred-intent.md` and grade the diff against it. The iteration cost of complexity-beyond-spirit is high — every extra abstraction, defensive branch, or pre-emptive seam has to be maintained, understood, and reasoned about by every later change. If the diff achieves the stated end-user outcome with N lines of straightforward code, a 2N-line version that adds wrappers, hooks, or future-proofing for unobserved use cases is the wrong shape. Cite *which* pieces are above the spirit-of-ask line and what would shrink to meet it. Severity: usually `medium` (overshoot calcifies the same way bypasses do).

2. **Does the new code invent a pattern parallel to one this repo already has, or extend/improve the existing seam?** This is the single most common LLM defect. It often surfaces as a *single new instance* (one inline `os.getenv()`, one raw `psycopg2.connect()`, one `threading.Thread()`), so DRY-style "N copies in this PR" detection misses it. Your job is to catch it at instance-1 — and when no canonical exists yet, to call out the second instance so a shape gets established before instance-3.

**Prior-art verdict — one line per new symbol or pattern the diff introduces, in your probe or in a closing `Prior-art:` list:** `Prior-art: <owner/repo/path> — extend` (the sibling shape should be reused/extended), `Prior-art: <owner/repo/path> — replace` (this PR's shape supersedes the sibling's; say why), `Prior-art: none after sibling grep + KID`, or `Prior-art: unknown — <slug> missing`. Start from `prior-art.md § Sibling prior art — new symbols`; a name that appears there and gets no verdict is a miss. Inventing a shape a sibling already owns is the exact defect this angle exists for, and across repos it is the one most often missed.

**`none` is a claim about the corpus, not about the diff — you may not render it over a corpus you could not search.** When `.codex-scratch/search-roots.md`'s first line says `# coverage: partial` or `# coverage: same-repo-only`, or when any sibling relevant to the construct you are judging is listed `missing`, the verdict is `Prior-art: unknown — <slug> missing`, naming the slug. A `none` computed over a corpus that structurally cannot hold the answer is a false all-clear, and it is worse than no verdict because the next reviewer reads it as settled.

**When a sibling is an upstream framework this repo extends, the question is "does upstream already ship this mechanism?", not only "does a sibling already define this name?"** The sibling grep in `prior-art.md` fires on names the diff introduces, and a reinvention almost always coins a *new* name for a mechanism upstream already has under a different one — so the grep comes back empty exactly when the defect is present. Read the upstream peer set directly under `.siblings/<slug>/`: its base class and its extension-contract doc say what the framework already handles, and its other adapters/plugins are worked examples of the same extension points this diff is touching. `Prior-art: none` for a construct in an upstream-declared repo requires that you actually looked there; say where.

**Method (walk the diff):**

For each new construct, name its problem class and emit a probe per `.codex-scratch/probe-schema.md`. Common classes — and the canonical shape you should grep for in this repo:

- **config / secrets read** → repo's Config helper, not `os.getenv()` inline
- **persistence / DB access** → repo's repository / session pattern, not raw connections
- **HTTP client / external API** → repo's HTTP wrapper (auth, retry, observability), not a fresh `requests.post`
- **background / async work** → existing queue (Celery/RQ/etc.), not `threading.Thread()` or one-off schedulers
- **error envelope** → framework's exception → response mapper, not hand-rolled `try/except: return {"error": ...}`
- **state / status** → existing enum, not magic strings
- **validation / schema** → pydantic / zod / whatever the repo uses, not hand-rolled `isinstance`
- **dispatch** → registry/dict, not `if kind == "A" elif kind == "B"`
- **logging / metrics** → repo's logger/metrics seam, not `print()` / ad-hoc files
- **retry / idempotency** → repo's retry decorator, not hand-rolled sleep loops
- **auth / permission** → middleware/decorator, not per-handler checks
- **feature flag / experiment** → repo's flag client
- **serialization** → repo's `to_dict` / Serializer, not hand-built dict literals
- **parsing structured input** → upstream emits structured data, not regex on a string
- **utility helpers** → existing utils module / next to caller, not a new `utils/foo.py` for one helper

For each construct, emit a probe per `.codex-scratch/probe-schema.md`. **Classes emitted: `bypass`, `shape`, `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `simplification` in this angle: defensive branches, validation guards, helpers added with one call site, schema fields, env vars, parallel modes — anything that adds shape without earning it.

Where this overlaps with other specialists:
- `architecture-refined` owns DRY (N near-identical blocks), kid-prior-art, verbose conditional/early-return cleanups, drive-by tidies, dead-code-on-touched-files, plus layering, lock-in, roadmap fit, and cross-cutting *strategic* decisions.
- You own: simplest-viable-shape-vs-spirit-of-ask, instance-1 bypass, "second instance — establish now," wrong-shape (regex on structured input, hand-rolled when canonical exists), and **existing-complexity probes**.

Some duplicate probes between you and the other two are expected — that's by design; this failure mode is high-stakes. The critic dedupes via `DUPLICATE OF`.

Out of scope: specific security bugs, concurrency bugs, test coverage, line-level style, stale callers (consumers owns those).

**Emission format:**

(Output shape, `Answer: unknown` default, `No probes.` fallback, and `## Surveyed` requirement live in `common-header.md` § Rules — they apply to every specialist; this file only carries class options + per-specialist mandate.)

Look beyond the diff: the repo's canonical shapes live in `lib/`, `core/`, base classes, decorator modules, the framework's docs. Grep for the symbols you're evaluating (e.g. `grep -rn "Config" --include="*.py"` to find a Config helper before judging an `os.getenv` call).
