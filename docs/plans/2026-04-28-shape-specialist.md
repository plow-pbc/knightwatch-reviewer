# Shape Specialist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 6th review specialist, `shape`, whose sole job is to catch the LLM failure mode of inventing a new pattern parallel to an existing seam in the repo (rather than extending the canonical one). Sharpen the existing `simplification.md` and `architecture.md` prompts to delegate this concern, and update the critic + aggregator consumers to read and rank the new specialist's output.

**Architecture:** A new `prompts/shape.md` is added alongside the existing five specialist prompts. The orchestrator's existing parallel fan-out loop in `lib/review-one-pr.sh` is extended from 5 to 6 angles — no new infrastructure, no new scratch files, no new tests. The existing `run-specialist.sh` and `build_specialist_prompt` already handle arbitrary angle names. The critic and aggregator are extended to read `.codex-scratch/specialists/shape.md` and to call out shape-bypass findings as a high-rank LLM failure mode.

**Tech Stack:** Bash 5.2, `codex exec`. All existing — no new dependencies.

---

## Meta Context (read first — applies to every task)

**This plan modifies the live production tree's symlinked code paths.** `~/Hacking/knightwatch-reviewer/` is symlinked into `~/.pr-reviewer/` (`prompts/`, `lib/`, `contexts/` are all symlinks). The systemd timers (`pr-reviewer.timer` etc., `*:0/2`) run scripts directly from this checkout, so a half-applied edit can land in production mid-tick.

**Implementation tree:** `~/Hacking/knightwatch-reviewer2/` — sibling checkout, currently on `main` at `5f2b769`. **All edits in this plan happen here.** Per `~/.claude/CLAUDE.md`:

> Workspace Isolation — NO git worktrees, ever. I keep parallel checkouts as sibling directories.

**Branch policy:** Never commit to `main`. Task 1 creates `feat/shape-specialist`; all task commits land on it; user merges to `main` and `git pull`s in `~/Hacking/knightwatch-reviewer/` after PR review.

**Deployment:** because `~/.pr-reviewer/prompts/` symlinks to `~/Hacking/knightwatch-reviewer/prompts/`, once `feat/shape-specialist` is merged and the live tree pulls main, the next timer tick (≤2 min later) picks up the new prompt and the orchestrator's new angle loop. No restart, no copy.

**Test surface:** `just test` runs (a) `bash -n` syntax check on every tracked `.sh`, and (b) three smoke tests (`state-io`, `build-specialist-prompt`, `orchestrator-skip`). The smoke tests don't enumerate angles, so they need no updates. After `lib/review-one-pr.sh` is edited, `bash -n` is the gate that catches typos.

---

## File Structure

**New files:**

| Path | Purpose |
|---|---|
| `prompts/shape.md` | The new specialist's prompt — pattern-conformance / Name the Shape angle. ~50 lines, similar shape and length to `architecture.md` and `simplification.md`. |

**Modified files:**

| Path | Change |
|---|---|
| `lib/review-one-pr.sh` | Add `shape` to the three `for angle in ...` loops (launch fan-out, post-wait failure check, log-line summary). Update the two log messages from "5 specialists" → "6 specialists". |
| `prompts/critic.md` | Add `.codex-scratch/specialists/shape.md` to the read list; add `[shape]` row to the output template; update "Five specialists" → "Six specialists". |
| `prompts/aggregator.md` | Add `.codex-scratch/specialists/shape.md` to the read list; add a sentence in the Step 3 ranking guidance calling out shape-bypass findings as the top of the tech-debt band; update "Five specialists" → "Six specialists". |
| `prompts/simplification.md` | One-line edit to the wrong-shape bullet: delegate the heavy lifting to the new `shape` specialist; raise here only when bound to a simplification finding. |
| `prompts/architecture.md` | One-line edit to the cross-cutting bullet: delegate the seam-bypass diagnosis to `shape`; architecture keeps the layer/module-boundary framing. |

**Files NOT changed (deliberate):**

- `prompts/common-header.md` — does not enumerate specialists by name; no update needed.
- `lib/run-specialist.sh`, `lib/prompt-build.sh` — angle-agnostic; no update needed.
- `lib/tests/*` — none of the existing smoke tests enumerate angles; no update needed.
- `~/.claude/CODING_STANDARDS.md` — `## Name the Shape` already exists and the new specialist cites it. No change.

---

## Task 1: Create feature branch and commit this plan

**Files:**
- Create: `docs/plans/2026-04-28-shape-specialist.md` (this file)

- [ ] **Step 1: Create feature branch off main**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git checkout -b feat/shape-specialist
```

Expected: `Switched to a new branch 'feat/shape-specialist'`.

- [ ] **Step 2: Stage and commit this plan**

```bash
git add docs/plans/2026-04-28-shape-specialist.md
git commit -m "$(cat <<'EOF'
Plan: shape specialist for pattern conformance / Name the Shape

Adds a 6th review specialist whose only job is to catch the LLM failure
mode of inventing a new pattern parallel to an existing seam — single
instance, where DRY-style detection misses it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the shape specialist (prompt + orchestrator + consumers)

This task lands the new specialist as one atomic commit. Splitting prompt creation from orchestrator wiring would leave a window where the orchestrator references a missing prompt file — `bash -n` won't catch it but a live timer tick would crash.

**Files:**
- Create: `prompts/shape.md`
- Modify: `lib/review-one-pr.sh` (lines 497, 498, 513, 524, 525)
- Modify: `prompts/critic.md` (intro count + read list + output template)
- Modify: `prompts/aggregator.md` (intro count + read list + ranking guidance)

- [ ] **Step 1: Create `prompts/shape.md`**

Write the following exact content to `/home/odio/Hacking/knightwatch-reviewer2/prompts/shape.md`:

```markdown
**Your angle: Pattern conformance — Name the Shape.**

FIRST, read `.codex-scratch/standards.md` § Name the Shape. That section names exactly what this specialist owns; cite it when grading.

ALSO read: `.codex-scratch/inferred-intent.md`, `.codex-scratch/file-history.md`, `.codex-scratch/prior-art.md`, `.codex-scratch/diff.patch`.

**The failure mode you exist to catch:** the author solved a problem by inventing a new pattern parallel to one that already exists in this repo — bypassing the canonical seam instead of extending it. This is the single most common LLM defect. It often surfaces as a *single new instance* (one inline `os.getenv()`, one raw `psycopg2.connect()`, one `threading.Thread()`), so DRY-style "N copies in this PR" detection misses it. Your job is to catch it at instance-1.

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
- `simplification` owns DRY (N copies in this PR), kid-prior-art, verbose code, drive-by tidies.
- `architecture` owns layering, lock-in, roadmap fit, cross-cutting *strategic* decisions.
- You own: instance-1 bypass, "second instance — establish now," and wrong-shape (regex on structured input, hand-rolled when canonical exists).

Some duplicate findings between you and the other two are expected — that's by design, this failure mode is high-stakes. The critic dedupes via `DUPLICATE OF`.

Out of scope: specific security bugs, concurrency bugs, test coverage, line-level style.

Severity tuning: instance-1 bypass of an established seam is `blocking`. Second-instance-no-canonical is `medium`. Wrong-shape is `medium` if internal, `blocking` if it ships brittleness to users. Don't pad with "clean" findings — the Surveyed section is where you prove you looked.

Look beyond the diff: the repo's canonical shapes live in `lib/`, `core/`, base classes, decorator modules, the framework's docs. Grep for the symbols you're evaluating (e.g. `grep -rn "Config" --include="*.py"` to find a Config helper before judging an `os.getenv` call).
```

- [ ] **Step 2: Wire `shape` into `lib/review-one-pr.sh`**

Five edits — three loop bodies and two log messages.

**Edit (a):** line 497 — log message before launch.

```diff
-log "$PR_ID: launching 5 specialists in parallel..."
+log "$PR_ID: launching 6 specialists in parallel..."
```

**Edit (b):** line 498 — launch loop angle list.

```diff
-for angle in security data-integrity architecture simplification tests; do
+for angle in security data-integrity architecture simplification tests shape; do
```

**Edit (c):** line 513 — post-wait failure-check loop.

```diff
-for angle in security data-integrity architecture simplification tests; do
+for angle in security data-integrity architecture simplification tests shape; do
```

**Edit (d):** line 524 — completion log.

```diff
-log "$PR_ID: all 5 specialists completed"
+log "$PR_ID: all 6 specialists completed"
```

**Edit (e):** line 525 — log-summary loop.

```diff
-for angle in security data-integrity architecture simplification tests; do
+for angle in security data-integrity architecture simplification tests shape; do
```

- [ ] **Step 3: Update `prompts/critic.md`**

**Edit (a):** line 1 (`Five specialists have surfaced findings.`).

```diff
-You are the devil's advocate in a multi-specialist PR review. Five specialists have surfaced findings.
+You are the devil's advocate in a multi-specialist PR review. Six specialists have surfaced findings.
```

**Edit (b):** read list — insert `shape.md` after `tests.md`.

```diff
 - `.codex-scratch/specialists/security.md`
 - `.codex-scratch/specialists/data-integrity.md`
 - `.codex-scratch/specialists/architecture.md`
 - `.codex-scratch/specialists/simplification.md`
 - `.codex-scratch/specialists/tests.md`
+- `.codex-scratch/specialists/shape.md`
```

**Edit (c):** output template — add `[shape]` row after `[tests]`.

```diff
 ### [tests] Finding N — <status>
 ...
+
+### [shape] Finding N — <status>
+...
```

- [ ] **Step 4: Update `prompts/aggregator.md`**

**Edit (a):** line 1 (`Five specialists produced raw findings`).

```diff
-You are the aggregator in a multi-specialist PR review. Five specialists produced raw findings;
+You are the aggregator in a multi-specialist PR review. Six specialists produced raw findings;
```

**Edit (b):** read list — insert `shape.md` after `tests.md`.

```diff
 - `.codex-scratch/specialists/tests.md`
+- `.codex-scratch/specialists/shape.md`
 - `.codex-scratch/critic.md` — **critic counterarguments + missed findings. READ FIRST.**
```

**Edit (c):** Step 3 ranking guidance — extend item (a) with shape-bypass framing.

```diff
    a. Tech-debt and architectural findings — missing abstraction, DRY violation, design that won't survive the roadmap. These compound.
+      **Shape-bypass / parallel-pattern findings** (where the PR invented a new pattern instead of extending an existing seam — e.g. a new `os.getenv()` next to a `Config` class, a new `threading.Thread` next to the queue, a new wrapper next to an existing client) belong at the top of this band. They compound the fastest because each bypass calcifies and the next change extends the wrong seam. When a `shape` finding survives the critic, name it explicitly in Findings — "the new X should have gone through Y; extend that seam, don't bypass it" — rather than burying it in generic refactor language. This is the most common, highest-leverage class of LLM defect we catch.
```

- [ ] **Step 5: Run `just test`**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
```

Expected: all checks pass — `bash -n` clean on the modified `lib/review-one-pr.sh`, three smoke tests green.

If `bash -n` flags `lib/review-one-pr.sh`: a typo in one of the angle-loop edits. Fix and re-run.

- [ ] **Step 6: Commit**

```bash
git add prompts/shape.md lib/review-one-pr.sh prompts/critic.md prompts/aggregator.md
git commit -m "$(cat <<'EOF'
Add shape specialist for pattern conformance (Name the Shape)

The 6th specialist catches the LLM failure mode of inventing a new
pattern parallel to an existing seam — at instance-1, where DRY-style
detection misses it. Common forms: `os.getenv` inline next to a Config
helper, raw DB access next to a Repository, `threading.Thread` next to
an existing queue, magic strings next to an enum, hand-rolled error
envelopes next to a framework mapper.

Wires `shape` into the existing parallel fan-out (no new infra). Critic
and aggregator extended to read .codex-scratch/specialists/shape.md;
aggregator ranks shape-bypass at the top of the tech-debt severity band
and calls it out explicitly in Findings.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Sharpen handoff in `simplification.md` and `architecture.md`

Both existing prompts already touch on this concern; sharpen the language so they delegate the heavy lifting to the new `shape` specialist while keeping their own framings.

**Files:**
- Modify: `prompts/simplification.md` (the wrong-shape bullet)
- Modify: `prompts/architecture.md` (the cross-cutting bullet)

- [ ] **Step 1: Update `prompts/simplification.md`**

Find the bullet beginning **`UX / shape:`** and append a delegation sentence.

```diff
-- **UX / shape**: can the public surface be simplified? Would a different decomposition cut call-site code in half? Is a class doing the work of a function? **Wrong-shape smells:** regex on string-typed input (ask where the structure got discarded upstream — the fix is usually to make upstream emit data, not to grow the regex), hand-rolled validation/retry/dispatch/formatting when the repo already has a canonical shape, bool-soup state where an enum or state machine belongs. See `standards.md` § Name the Shape.
+- **UX / shape**: can the public surface be simplified? Would a different decomposition cut call-site code in half? Is a class doing the work of a function? **Wrong-shape smells:** regex on string-typed input (ask where the structure got discarded upstream — the fix is usually to make upstream emit data, not to grow the regex), hand-rolled validation/retry/dispatch/formatting when the repo already has a canonical shape, bool-soup state where an enum or state machine belongs. The `shape` specialist owns this beat and goes deep on it; raise it here only when it's tightly bound to a simplification finding you're already calling out. See `standards.md` § Name the Shape.
```

- [ ] **Step 2: Update `prompts/architecture.md`**

Find the **Cross-cutting patterns introduced in *this* PR** bullet and reword the closing parenthetical to delegate seam-bypass diagnosis.

```diff
-- **Cross-cutting patterns introduced in *this* PR**: when the same decision is made across N modules (three parallel changes to three connectors, three new routes with the same shape, three copies of the same guard), flag the layering implication — it usually signals a missing abstraction. The exact code-duplication recommendation belongs to the `simplification` specialist; you own the architectural framing (why was this the author's only option? what's the seam they missed?).
+- **Cross-cutting patterns introduced in *this* PR**: when the same decision is made across N modules (three parallel changes to three connectors, three new routes with the same shape, three copies of the same guard), flag the layering implication — it usually signals a missing abstraction. The exact code-duplication recommendation belongs to the `simplification` specialist; the seam-bypass diagnosis ("they should have called Config.load, not os.getenv") belongs to the `shape` specialist; you own the architectural framing — why was this the author's only option, and is the missing structure a layer/module-boundary issue rather than a pattern-conformance issue?
```

- [ ] **Step 3: Run `just test`**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
```

Expected: all checks pass. (Pure markdown edits — `bash -n` is unaffected; smoke tests don't read these prompts.)

- [ ] **Step 4: Commit**

```bash
git add prompts/simplification.md prompts/architecture.md
git commit -m "$(cat <<'EOF'
Sharpen simplification + architecture handoffs to shape specialist

Both prompts touched the seam-bypass concern; tighten their language so
the heavy lifting moves to the new `shape` specialist while each keeps
its own framing — simplification stays focused on DRY/intra-PR/verbose,
architecture stays on layer/module-boundary issues. Three angles still
look at this concern from different sides; the critic dedupes overlap.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Verify, push branch, open PR

- [ ] **Step 1: Final verification**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
git log --oneline main..HEAD
git diff main..HEAD --stat
```

Expected output of `git log`: three commits — plan, shape specialist + consumers, handoff sharpening. Expected diff stat: `prompts/shape.md` (new, ~50 lines), `lib/review-one-pr.sh` (~5 line edits), `prompts/{critic,aggregator,simplification,architecture}.md` (small edits each), `docs/plans/2026-04-28-shape-specialist.md` (new).

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/shape-specialist
gh pr create --title "Add shape specialist for pattern conformance" --body "$(cat <<'EOF'
## Summary

- Adds a 6th review specialist, `shape`, whose only job is to catch the LLM failure mode of inventing a new pattern parallel to an existing seam — at instance-1, where DRY-style detection misses it.
- Sharpens `simplification.md` and `architecture.md` to delegate the heavy lifting and keep their own framings (DRY/verbose, layer/module-boundary).
- Extends critic + aggregator to read `.codex-scratch/specialists/shape.md` and ranks shape-bypass at the top of the tech-debt severity band.

## Test plan

- [x] `just test` green (bash -n + 3 smoke tests)
- [ ] Trigger a `/review` on a real PR after merge + live-tree pull; confirm 6 specialists launch and `shape.md` is produced
- [ ] Review the next 3-5 generated reviews for shape-bypass findings; confirm severity calibration matches the prompt (blocking on instance-1 bypass, medium on second-instance, omit on clean)

## Deployment note

`~/.pr-reviewer/prompts/` is a symlink into `~/Hacking/knightwatch-reviewer/prompts/`. After merge, `git pull` in `~/Hacking/knightwatch-reviewer/` and the next timer tick (≤2 min) picks up the new specialist with no restart.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Return PR URL to user**

The PR URL printed by `gh pr create` is the handoff. User reviews, merges, and `git pull`s in the live tree.

---

## Self-Review Notes

- **Spec coverage:** every change in the design discussion (new specialist, three-angle overlap, aggregator callout, simplification/architecture handoff) is in a task.
- **Type/name consistency:** angle name is `shape` everywhere — orchestrator loops, prompt filename, scratch-file path (`.codex-scratch/specialists/shape.md`), critic read list, aggregator read list. No drift.
- **Placeholder scan:** none. All code/diffs are concrete.
- **Scope:** single concern (the new specialist + handoffs). No unrelated cleanup.
- **Irony check:** adding a 6th specialist *is* itself adding a new pattern parallel to the existing five. The argument for it: `simplification` is already doing four jobs and tacking a fifth on dilutes; per the standard's own rule ("If you are the second instance of a missing shape, *that* is the moment to introduce one — not the fifth"), pulling Name-the-Shape into a focused owner *is* introducing the shape rather than letting it diffuse. Documented in commit messages.
