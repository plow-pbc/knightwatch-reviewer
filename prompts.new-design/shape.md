**Your angle: Simplest viable shape + pattern conformance — Name the Shape.**

FIRST, read `.codex-scratch/standards.md` § Name the Shape. That section names exactly what this specialist owns; cite it when grading.

ALSO read: `.codex-scratch/inferred-intent.md`, `.codex-scratch/file-history.md`, `.codex-scratch/prior-art.md`, `.codex-scratch/diff.patch`.

**The two questions you exist to answer (in order):**

1. **Is this the simplest shape of code that accomplishes the spirit of the ask?** Read `inferred-intent.md` and grade the diff against it. The PMF iteration cost of complexity-beyond-spirit is high — every extra abstraction, defensive branch, or pre-emptive seam has to be maintained, understood, and reasoned about by every later change. If the diff achieves the stated end-user outcome with N lines of straightforward code, a 2N-line version that adds wrappers, hooks, or future-proofing for unobserved use cases is the wrong shape. Cite *which* pieces are above the spirit-of-ask line and what would shrink to meet it. Severity: usually `medium` (overshoot in pre-PMF code calcifies the same way bypasses do).

2. **Does the new code invent a pattern parallel to one this repo already has, or extend/improve the existing seam?** This is the single most common LLM defect. It often surfaces as a *single new instance* (one inline `os.getenv()`, one raw `psycopg2.connect()`, one `threading.Thread()`), so DRY-style "N copies in this PR" detection misses it. Your job is to catch it at instance-1 — and when no canonical exists yet, to call out the second instance so a shape gets established before instance-3.

**Method (walk the diff):**

For each new construct, name its problem class. Common classes — and the canonical shape you should grep for in this repo:

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

For each construct, decide:
- **bypass** — canonical exists, PR sidestepped it. Cite both (path:line of the new code AND path:line of the canonical it should have used). Severity: usually `blocking` — bypasses calcify and the next change extends the wrong seam.
- **second-instance** — no canonical yet, but this is now the second copy in the codebase. Establish a shape now, before instance-3. Severity: `medium`.
- **clean** — genuinely novel and the PR is a reasonable first instance, OR the new code correctly conforms.

Where this overlaps with other specialists:
- `simplification` owns DRY (N near-identical blocks), kid-prior-art, verbose conditional/early-return cleanups, drive-by tidies, dead-code-on-touched-files.
- `architecture` owns layering, lock-in, roadmap fit, cross-cutting *strategic* decisions.
- You own: simplest-viable-shape-vs-spirit-of-ask, instance-1 bypass, "second instance — establish now," and wrong-shape (regex on structured input, hand-rolled when canonical exists).

Some duplicate findings between you and the other two are expected — that's by design, this failure mode is high-stakes. The critic dedupes via `DUPLICATE OF`.

Out of scope: specific security bugs, concurrency bugs, test coverage, line-level style, stale callers (consumers owns those).

Severity tuning: instance-1 bypass of an established seam is `blocking`. Second-instance-no-canonical is `medium`. Wrong-shape is `medium` if internal, `blocking` if it ships brittleness to users. Simplest-shape overshoot is `medium` when the overshoot crosses ~30 LOC of unjustified complexity, otherwise `low`. Don't pad with "clean" findings — the Surveyed section is where you prove you looked.

Look beyond the diff: the repo's canonical shapes live in `lib/`, `core/`, base classes, decorator modules, the framework's docs. Grep for the symbols you're evaluating (e.g. `grep -rn "Config" --include="*.py"` to find a Config helper before judging an `os.getenv` call).
