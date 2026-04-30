# Performance + Consumers Specialists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new review specialists to the parallel fan-out — `performance` (anti-premature-optimization framing) and `consumers` (internal call-graph integrity: dead code + internal contract breaks) — plus a two-step dead-code pre-pass (static-analysis tool + LLM grep) that produces structured evidence the `consumers` specialist consumes.

**Architecture:** Two new specialist prompts (`prompts/performance.md`, `prompts/consumers.md`) join the existing six in the parallel fan-out at `lib/review-one-pr.sh:667` (`ANGLES=(...)`). Before fan-out, two new pre-pass steps run sequentially after intent: (1) a static-analysis command per repo (`DEAD_CODE_CMDS[$REPO]` from `repos.conf`) writes raw tool output to `.codex-scratch/dead-code-static.md`, mirroring the `kid` → `prior-art.md` shape; (2) a new LLM pre-pass (`prompts/dead-code-search.md`) reads the static-tool output and the diff, walks the call graph for modified/removed public symbols, verifies static-tool candidates against dynamic-dispatch / decorator / framework-hook patterns, and writes structured evidence to `.codex-scratch/dead-code.md`. The `consumers` specialist consumes the LLM-produced `dead-code.md` (which already incorporates verified static-tool results) and files findings with severity. The `performance` specialist consumes only the diff + product-context. Critic + aggregator are extended to read the two new specialist outputs.

**Tech Stack:** Bash 5.2, `codex exec`. Optional language-specific tools per repo (`vulture`, `knip`, `ts-prune`, `ruff`) — static pre-pass degrades gracefully to absent when the tool is missing; the LLM pre-pass still runs and produces evidence from the diff alone.

---

## Meta Context (read first — applies to every task)

**This plan modifies the live production tree's symlinked code paths.** `~/Hacking/knightwatch-reviewer/` is symlinked into `~/.pr-reviewer/` (`prompts/`, `lib/`, `contexts/`, `repos.conf` are all symlinks). The systemd timers (`pr-reviewer.timer`, `*:0/2`) run scripts directly from this checkout, so a half-applied edit can land in production mid-tick.

**Implementation tree:** `~/Hacking/knightwatch-reviewer2/` — sibling checkout, currently on `main`. **All edits in this plan happen here.** Per `~/.claude/CLAUDE.md`:

> Workspace Isolation — NO git worktrees, ever. I keep parallel checkouts as sibling directories.

**Branch policy:** Never commit to `main`. Task 1 creates `feat/perf-and-consumers-specialists`; all task commits land on it; user merges to `main` and `git pull`s in `~/Hacking/knightwatch-reviewer/` after PR review.

**Deployment:** because `~/.pr-reviewer/prompts/` and `~/.pr-reviewer/repos.conf` symlink into the live tree, once the branch is merged and the live tree pulls main, the next timer tick (≤2 min later) picks up both new specialists, the new ANGLES list, and any new `DEAD_CODE_CMDS`. No restart, no copy.

**Test surface:** `just test` runs (a) `bash -n` syntax check on every tracked `.sh` and (b) the smoke suite under `lib/tests/`. No existing smoke enumerates angle names, so adding angles needs no test updates. The pre-pass shells out to language tools — those are exercised by manual review of the first few production runs, not by the smoke suite (consistent with how `kid` is unit-untested).

**Reference precedent:** `docs/plans/2026-04-28-shape-specialist.md` is the closest analog (also added a specialist + critic/aggregator wiring). The current `ANGLES=(security data-integrity architecture simplification tests shape)` array in `lib/review-one-pr.sh:667` is the single edit point for fan-out — the five-line edit pattern from the shape plan no longer applies.

---

## Design Rationale (read before executing — push back here, not mid-task)

**Why one `consumers` specialist instead of separate `dead-code` + `internal-contracts`?** Both are call-graph scans of the same set of symbols (modified/removed public symbols in this PR). They differ only in the filter: zero remaining callers = dead, mismatched callers = broken contract. Combining shares the scan, halves token spend on critic/aggregator dedupe, and keeps the specialist roster from sprawling. The user's "additive over substitutive" memory applies to *the same concern from multiple angles* (e.g. shape/architecture/simplification all looking at seam-bypass) — this is closer to *one scan with two filters*, which combining captures naturally.

**If we want belt-and-suspenders later,** the `consumers` specialist can be split into two with no architecture change — both halves consume `dead-code.md` and the diff. Don't pre-split.

**Why both a static-tool pre-pass AND an LLM grep pre-pass?** Static tools are exact on "no callers in their language's source files" but miss dynamic-dispatch (decorators, framework hooks, runtime-resolved names, reflection, registry pattern) and don't catch *modified* symbols at all (broken callers). LLM grep can investigate dynamic dispatch and modified-symbol shape mismatches but hallucinates if asked to enumerate callers from scratch. Combining: the static tool produces a high-recall low-precision candidate list; the LLM verifies candidates against dynamic-dispatch patterns AND extends the search to walk modified/removed public symbols' callers. Both produce **evidence** (caller lists, mismatch annotations, false-positive dismissals), not findings — the `consumers` specialist files findings from that evidence.

**Why a separate LLM pre-pass instead of folding the grep into the consumers specialist?** Investigation and judgment are different cognitive shapes. A specialist that has to *both* exhaustively grep callers *and* file calibrated review findings produces worse output on both — the prompt context fills with grep output and severity discipline slips. Separating the steps lets the pre-pass be high-effort exhaustive investigation (exactly the work the LLM is bad at when also doing other things) and lets the specialist be focused judgment (severity, framing, dedupe). Mirrors the `intent` pre-pass / `kid` pre-pass pattern: pre-pass produces evidence → specialists consume it.

**Cost of the second LLM pre-pass.** Adds one sequential codex-exec call (~30s wall-clock) before fan-out, alongside the existing `intent` pass. Token cost is comparable to one specialist. Acceptable for the bug class — internal contract breaks are runtime failures that no other specialist owns reliably.

**Why not fold contract-break into `architecture`?** Once the user's clarification narrowed scope to *internal* consumers (no external customers yet), the surviving concern is mechanically a call-graph walk, not an architectural framing. Architecture stays focused on layering / lock-in / roadmap fit.

**Why no edits to `simplification`?** The drive-by-tidies bullet ("an unused import") rarely overlaps with consumers' findings, and when it does the critic dedupes. Per the redundancy memory, intentional small overlap is preferred over a fragile boundary edit.

**Why no `performance` overlap with `data-integrity`?** Both walk unhappy edges, but data-integrity asks "is the result correct?" and performance asks "does this scale past the demo with a small fix?". Different filters on the same walk. Some overlap is fine.

**Out-of-scope perf findings (DO NOT FILE — encoded in the prompt):** Redis/memcached, DB switch, hand-rolled SQL for X% gain, denormalize, CDN, microservice split, language change. Anything that grows infra or trades readability for throughput. The user's stage prioritizes engineer-hours over CPU.

---

## File Structure

**New files:**

| Path | Purpose |
|---|---|
| `prompts/performance.md` | The `performance` specialist's prompt — anti-premature-optimization framing, allowed bug classes, severity rules, disallowed-findings list. ~75 lines. |
| `prompts/consumers.md` | The `consumers` specialist's prompt — reads structured evidence from `dead-code.md` and files findings (severity, framing). Lean — investigation work happens in the pre-pass. ~60 lines. |
| `prompts/dead-code-search.md` | LLM pre-pass prompt — investigation-only. Reads static-tool output + diff, walks call graph for modified/removed public symbols, verifies static-tool candidates against dynamic-dispatch patterns, writes structured evidence. ~70 lines. |

**Modified files:**

| Path | Change |
|---|---|
| `lib/review-one-pr.sh` | (a) Insert static-tool pre-pass block after the kid block (after line 549) — output to `dead-code-static.md`. (b) Add LLM `dead-code-search` pre-pass block after the static block, mirroring the `intent` pre-pass pattern at lines 637-665 — output to `dead-code.md`. (c) Add `performance` and `consumers` to `ANGLES` at line 667. (d) Write both `dead-code-static.md` and `dead-code.md` scratch files. |
| `repos.conf` | Add `DEAD_CODE_CMDS` associative array with per-repo static-analysis commands. Empty string = no static tool for that repo (LLM pre-pass still runs from the diff alone). |
| `lib/tracked-repos.sh` | Pre-declare `DEAD_CODE_CMDS` empty so it's safe under `set -u` in test sandboxes that don't source `repos.conf`. |
| `prompts/critic.md` | Add `.codex-scratch/specialists/{performance,consumers}.md` to the read list; update specialist count "Six" → "Eight"; add `[performance]` and `[consumers]` rows to the output template. |
| `prompts/aggregator.md` | Add `.codex-scratch/specialists/{performance,consumers}.md` to the read list; update specialist count "Six" → "Eight"; extend Step 3 ranking guidance to call out (a) consumers' stale-caller findings as `blocking` runtime failures and (b) perf findings only when the fix is small. |
| `prompts/common-header.md` | Add `.codex-scratch/dead-code.md` to the inputs list (consumed by `consumers` but documented in the shared header for transparency). |

**Files NOT changed (deliberate):**

- `prompts/simplification.md` — drive-by-tidies bullet stays; rare overlap with consumers is dedupe-able by the critic. Per the user's redundancy memory.
- `prompts/architecture.md` — no API/contract fold-in needed; once internal-only, the concern is call-graph not architecture.
- `prompts/{security,data-integrity,tests,shape,intent}.md` — orthogonal to both new specialists.
- `lib/run-specialist.sh`, `lib/prompt-build.sh` — angle-agnostic; no update needed.
- `lib/tests/*` — no smoke enumerates angle names. The static-tool pre-pass degrades gracefully when tools are absent, matching the `kid` precedent which is also unit-untested.
- `~/.claude/CODING_STANDARDS.md` — `## Concise Code` and `## Fail-Fast` already exist and are cited by the new perf prompt.

---

## Task 1: Create feature branch and commit this plan

**Files:**
- Create: `docs/plans/2026-04-29-perf-and-consumers-specialists.md` (this file)

- [ ] **Step 1: Create feature branch off main**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git checkout -b feat/perf-and-consumers-specialists
```

Expected: `Switched to a new branch 'feat/perf-and-consumers-specialists'`.

- [ ] **Step 2: Stage and commit this plan**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git add docs/plans/2026-04-29-perf-and-consumers-specialists.md
git commit -m "$(cat <<'EOF'
Plan: performance + consumers specialists

Adds two new specialists to the parallel fan-out:
- performance: anti-premature-optimization framing — only flags real
  perf bugs whose fix is small/idiomatic. Disallows infra/redesign/
  caching-layer recommendations. Engineer-hours, not CPU.
- consumers: internal call-graph integrity — dead code (zero callers)
  + internal contract breaks (mismatched callers) on modified/removed
  public symbols. External APIs out of scope (no external consumers
  yet).

Plus a deterministic static-tool pre-pass that feeds candidate dead
symbols to the consumers specialist (mirrors the kid → prior-art
pattern). Per-repo command in repos.conf; degrades to LLM-only when
the tool is missing.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add the `performance` specialist

This task lands the perf specialist as one atomic commit. Splitting prompt creation from orchestrator wiring would leave a window where the orchestrator references a missing prompt file — `bash -n` won't catch it but a live timer tick would crash.

**Files:**
- Create: `prompts/performance.md`
- Modify: `lib/review-one-pr.sh` (line 667 — `ANGLES=(...)`)
- Modify: `prompts/critic.md` (intro count + read list + output template)
- Modify: `prompts/aggregator.md` (intro count + read list + Step 3 ranking guidance)

- [ ] **Step 1: Create `prompts/performance.md`**

Write the following exact content to `/home/odio/Hacking/knightwatch-reviewer2/prompts/performance.md`:

```markdown
**Your angle: Performance and scale — bias toward concise/elegant fixes only.**

FIRST, read `.codex-scratch/standards.md` § Concise Code and § Fail-Fast. Your bias is anti-premature-optimization. Engineer-hours are the cost we minimize, not CPU. Simple infra wins (sqlite + readable ORM > distributed caches + hand-rolled queries).

ALSO read: `.codex-scratch/inferred-intent.md`, `.codex-scratch/diff.patch`, `.codex-scratch/product-context.md`.

**The failure mode you exist to catch:** code that ships, passes CI, then OOMs / times out / falls over in prod under realistic load — *with a fix that is small and idiomatic*. You are NOT here to find "could be faster" cases that need new infra or restructuring. You are here to catch real bugs whose fix is a one-liner the author would have written if they'd thought of it.

**Method (walk the diff for unhappy edges, like data-integrity but for cost):**

For each new code path, ask:
- Will this run for every request, per-N-records, or per-user? Multiply by current scale.
- Is there a loop with a DB / HTTP / file call inside that should be batched?
- Is there a SELECT / fetch without a LIMIT or pagination on data that grows with users?
- Is there sync I/O on an async path? (Blocks the event loop — one slow request stalls everything.)
- Is there `O(n²)` work where `n` is user-controlled and growing?
- Is `.count()` or `.all()` used where `.exists()` or `.filter().exists()` would do?
- Is invariant work (regex compile, dict construction, lookup) inside a loop body?

**Common bug classes — and the canonical fix shape:**

| Bug class | Example | Fix shape |
|---|---|---|
| N+1 ORM | `for user in users: user.posts.count()` | `select_related` / `prefetch_related` / batched fetch |
| Unbounded fetch | `Model.objects.all()` returned to a handler | `LIMIT` + pagination, or `.iterator()` |
| Sync-in-async | `requests.get(...)` inside an `async def` | `httpx.AsyncClient` or move to a worker |
| Count-instead-of-exists | `if Q.count() > 0:` | `if Q.exists():` |
| Re-compile in loop | `re.compile(...)` inside a loop | hoist to module level |
| Load-to-count | `len(list(qs))` | `qs.count()` |
| O(n²) membership | `for x in a: if x in b:` where `b` is a list | `set(b)` once |

**Severity:**
- `blocking` — *either* (a) this WILL OOM / time out / crash at current or known-near-term scale, *OR* (b) the fix is one-line idiomatic AND the bug is real (not theoretical). Either condition is independently sufficient.
- `medium` — real perf concern with a clear simple fix, no crash imminent.
- `low` — observation worth noting; fix would add complexity.
- Don't pad with "no findings." The Surveyed section is where you prove you looked.

**Disallowed findings (DO NOT FILE):**

- "Add Redis / memcached / a caching layer." — adds infra.
- "Switch from sqlite / Postgres to <X>." — infrastructure decision.
- "Hand-roll this ORM query as raw SQL for X% speedup." — degrades readability for real cost.
- "Denormalize the schema." — cross-cutting redesign.
- "Add a CDN / queue / worker pool." — infra.
- "Split this into a microservice." — architecture, not perf.
- "Use Cython / Rust / a faster language." — out of scope.

The bar: if the fix grows infra, adds dependencies, or trades readability for throughput, the finding is out of scope here. **Engineer-hours, not CPU.** A 2× speedup that costs a week of engineer time and adds a moving part is a *bad* finding for this team's stage.

Where this overlaps with other specialists:
- `data-integrity` walks unhappy edges for correctness; you walk them for cost.
- `simplification` may catch a verbose pattern that's also slow — let them own DRY/concision; you own the perf framing.

Out of scope: correctness bugs, security, test coverage, architecture fit.

Look beyond the diff: grep how the touched function is invoked across the repo. The same code is `blocking`-perf in a request handler and `low`-perf in a daily report job.
```

- [ ] **Step 2: Wire `performance` into `lib/review-one-pr.sh`**

One edit — append `performance` to the `ANGLES` array.

```diff
-ANGLES=(security data-integrity architecture simplification tests shape)
+ANGLES=(security data-integrity architecture simplification tests shape performance)
```

The fan-out / wait / log-summary loops at lines 671, 689, 699, 708 already use `${ANGLES[@]}`, so no other edits to this file are needed in this task.

- [ ] **Step 3: Update `prompts/critic.md`**

**Edit (a):** the intro line — change "Six specialists" → "Seven specialists" (this task adds one; Task 3 will bump to "Eight").

```diff
-You are the devil's advocate in a multi-specialist PR review. Six specialists have surfaced findings.
+You are the devil's advocate in a multi-specialist PR review. Seven specialists have surfaced findings.
```

**Edit (b):** add `performance.md` to the read list, after `shape.md`.

```diff
 - `.codex-scratch/specialists/shape.md`
+- `.codex-scratch/specialists/performance.md`
```

**Edit (c):** add a `[performance]` row to the output template, mirroring the existing pattern after `[shape]`.

```diff
 ### [shape] Finding N — <status>
 ...
+
+### [performance] Finding N — <status>
+...
```

- [ ] **Step 4: Update `prompts/aggregator.md`**

**Edit (a):** intro — "Six specialists" → "Seven specialists".

```diff
-You are the aggregator in a multi-specialist PR review. Six specialists produced raw findings;
+You are the aggregator in a multi-specialist PR review. Seven specialists produced raw findings;
```

**Edit (b):** add `performance.md` to the read list, after `shape.md`.

```diff
 - `.codex-scratch/specialists/shape.md`
+- `.codex-scratch/specialists/performance.md`
```

**Edit (c):** Step 3 ranking guidance — add a paragraph about perf findings.

Find the existing tech-debt-band paragraph (item `a` of Step 3 ranking guidance) and add a new paragraph after it:

```diff
       The `shape` specialist owns this beat ... [existing closing of paragraph (a)]
+
+      **Performance findings are only worth the author's time when the fix is small and idiomatic.** A perf finding that proposes a one-line idiomatic change (`select_related`, batched fetch, `.exists()` instead of `.count()`) belongs in the band where the standard cost-benefit math wins. Drop perf findings whose remedy adds infra (Redis, CDN, microservice split), trades readability for throughput (hand-rolled SQL), or restructures storage. Engineer-hours, not CPU — at this stage, "we can scale this later when we hit the wall" is the right answer for almost every non-trivial perf concern.
```

- [ ] **Step 5: Run `just test`**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
```

Expected: all checks pass — `bash -n` clean on the modified `lib/review-one-pr.sh`, smoke tests green.

If `bash -n` flags `lib/review-one-pr.sh`: typo in the `ANGLES` edit. Fix and re-run. If a smoke test fails on something unrelated to ANGLES: investigate before committing.

- [ ] **Step 6: Commit**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git add prompts/performance.md lib/review-one-pr.sh prompts/critic.md prompts/aggregator.md
git commit -m "$(cat <<'EOF'
Add performance specialist with anti-premature-optimization framing

Catches the perf-bug class no other specialist owns: code that ships
and OOMs/times out/falls over in prod under realistic load — but only
when the fix is small and idiomatic (one-line ORM tweak, batched
fetch, `.exists()` instead of `.count()`).

Disallowed findings encoded in the prompt: Redis/memcached/CDN, DB
switch, hand-rolled SQL, denormalize, microservice split, language
change. Anything that grows infra or trades readability for throughput
is out of scope at this stage. Engineer-hours, not CPU.

Severity: blocking when (a) crashes/OOMs at current or near-term scale
OR (b) fix is one-line idiomatic and the bug is real. Either alone
suffices — small fix is its own license to block.

Wires `performance` into the parallel fan-out (now 7 specialists).
Critic and aggregator extended; aggregator's ranking guidance drops
infra-growing perf findings explicitly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add the `consumers` specialist (no pre-pass yet — arrives in Task 4)

This task adds the specialist as judgment-only: reads `.codex-scratch/dead-code.md` if present, files findings with severity. The prompt is written to handle both an empty/absent `dead-code.md` (does its own diff walk + grep — degraded mode) and a populated one (consumes structured evidence — primary mode). Task 4 then lands the two-step pre-pass that produces the populated `dead-code.md` for the primary mode.

Order matters: landing the specialist first means every intermediate state is healthy. After Task 3, the specialist runs in degraded mode (LLM grep on the diff). After Task 4, it runs in primary mode (consumes evidence).

**Files:**
- Create: `prompts/consumers.md`
- Modify: `lib/review-one-pr.sh` (`ANGLES` line 667)
- Modify: `prompts/critic.md` (intro count + read list + output template)
- Modify: `prompts/aggregator.md` (intro count + read list + Step 3 ranking guidance)

- [ ] **Step 1: Create `prompts/consumers.md`**

Write the following exact content to `/home/odio/Hacking/knightwatch-reviewer2/prompts/consumers.md`:

```markdown
**Your angle: Internal consumers and call-graph integrity.**

FIRST, read `.codex-scratch/dead-code.md` if it exists and is non-empty — language-specific static-tool output (vulture / knip / ts-prune / ruff F401 / etc.) listing candidate dead symbols in the touched files. The list is *candidates*, not findings — every entry needs verification (dynamic dispatch, decorator hooks, framework registration, runtime-constructed names, reflection). Empty file or no file means the pre-pass had no tool wired up for this repo, OR the tool found nothing — in either case, fall back to LLM grep alone.

ALSO read: `.codex-scratch/diff.patch`, `.codex-scratch/file-history.md`.

**The failure mode you exist to catch:** the PR modified or removed a public symbol (function, class, route path, schema field, model field, env var, JSON shape, queue/event payload), and a caller in this repo (or a sibling tracked repo on this machine) no longer matches. Either the caller will fail at runtime (broken contract — `blocking`), or there is no caller at all (dead code — usually `low` or `medium`). Both classes show up in the same call-graph scan; you own both.

**External / public-API consumers are NOT your concern** — this product is not yet consumed by external customers. Walk *internal* call sites only: this repo plus sibling tracked repos under `~/Hacking/` (the `KID_PATHS` entries in `repos.conf`) when a public symbol from this repo plausibly has cross-repo consumers (shared libraries, server-side schemas consumed by client repos).

**Method (walk the diff):**

1. **List every public symbol the PR modified, removed, or renamed.** Function/method signatures, route paths and shapes, exported types, schema fields, model fields, env-var names, queue/event payload keys, CLI args, exception class names. (New symbols don't have callers yet — skip them. Renamed-only-no-shape-change is in scope: the old name's callers are now broken.)

2. **For each modified/removed symbol, grep call sites.** Use `grep -rn "<symbol>" --include="*.<ext>"` in the repo and in sibling tracked-repos directories when relevant. Be aware of dynamic dispatch (decorators, runtime-resolved names, framework hooks, reflection) — a zero-grep result is a *signal*, not proof.

3. **Classify each modified/removed symbol:**
   - **stale-caller** — callers exist but no longer match the new shape/signature/payload. Severity: `blocking` — call site fails at runtime. Cite caller path:line and the mismatch.
   - **dead** — zero remaining callers, or all remaining callers are tests-of-itself / disabled paths. Severity:
     - public/exported symbol with zero callers → `medium`. Confusing to keep around; either delete in this PR or open a follow-up issue.
     - private/local helper now unused → `low`. Drive-by deletion candidate.
   - **clean** — symbol still consumed, callers all match.

4. **Verify static-tool candidates from `dead-code.md`.** For each entry the tool flagged, decide:
   - **confirmed-dead** — promote to a finding (severity per above).
   - **false-positive** — name the dynamic-dispatch / decorator / framework-hook reason and dismiss in the Surveyed section.
   - **uncertain** — note it; surface to the author so they can confirm.

5. **Bonus pass: walk the diff for conditionals that became unreachable** because of upstream changes in this PR — a removed feature flag, a narrowed type, a dropped enum case, an `if False:`, `elif` chains where an earlier branch now matches everything. These are dead-code findings the static tools usually miss. Severity: `medium` for non-trivial code; `low` for one-line guards.

**Severity tuning:**
- `blocking` — stale-caller (runtime failure pending) or unreachable conditional that would let bad data through.
- `medium` — public symbol with no remaining callers, or unreachable non-trivial code block.
- `low` — private dead helper, unused import the static tool flagged.
- Don't pad with "clean" findings. Surveyed proves you looked.

**Where this overlaps with other specialists:**
- `simplification` owns DRY / intra-PR duplication / drive-by tidies *within* the touched code (formatting, redundant guards inside a function). You own *call-graph effects* (zero callers, mismatched callers, unreachable branches due to upstream change).
- `tests` owns "this bug-fix needs a regression test." You own "this regression *is* happening now because a caller wasn't updated."
- `shape` owns "did the author bypass an existing seam?" You own "did the author break an existing seam by changing it?"

Some duplicate findings between you and these others are expected — the critic dedupes via `DUPLICATE OF`.

Out of scope: external API contract breaks (no external consumers yet), security, performance, architecture fit.

Look beyond the diff: the sibling tracked-repos paths from `repos.conf`'s `KID_PATHS` are already on this machine; grep them when a public symbol from this repo plausibly has cross-repo consumers.
```

- [ ] **Step 2: Wire `consumers` into `lib/review-one-pr.sh`**

```diff
-ANGLES=(security data-integrity architecture simplification tests shape performance)
+ANGLES=(security data-integrity architecture simplification tests shape performance consumers)
```

- [ ] **Step 3: Update `prompts/critic.md`**

**Edit (a):** intro count — "Seven" → "Eight".

```diff
-You are the devil's advocate in a multi-specialist PR review. Seven specialists have surfaced findings.
+You are the devil's advocate in a multi-specialist PR review. Eight specialists have surfaced findings.
```

**Edit (b):** read list — add `consumers.md` after `performance.md`.

```diff
 - `.codex-scratch/specialists/performance.md`
+- `.codex-scratch/specialists/consumers.md`
```

**Edit (c):** output template — add `[consumers]` row after `[performance]`.

```diff
 ### [performance] Finding N — <status>
 ...
+
+### [consumers] Finding N — <status>
+...
```

- [ ] **Step 4: Update `prompts/aggregator.md`**

**Edit (a):** intro count — "Seven" → "Eight".

```diff
-You are the aggregator in a multi-specialist PR review. Seven specialists produced raw findings;
+You are the aggregator in a multi-specialist PR review. Eight specialists produced raw findings;
```

**Edit (b):** read list — add `consumers.md` after `performance.md`.

```diff
 - `.codex-scratch/specialists/performance.md`
+- `.codex-scratch/specialists/consumers.md`
```

**Edit (c):** Step 3 ranking guidance — add a paragraph about consumers' findings.

Find the perf paragraph added in Task 2 and add a new paragraph after it:

```diff
       **Performance findings are only worth the author's time ...** [Task 2 paragraph]
+
+      **Stale-caller findings from the `consumers` specialist are runtime failures pending — rank them at the top of the blocking band**, alongside data-integrity and security blockers. A modified public symbol with a caller that no longer matches will crash at the next request / cron / message — there is no "fine to ship today" framing for these. Dead-code findings from `consumers` (zero remaining callers) are tech-debt-band — usually `medium` for public symbols, `low` for private helpers — and don't need to block; a follow-up issue is enough.
```

- [ ] **Step 5: Run `just test`**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
```

Expected: all checks pass.

- [ ] **Step 6: Commit**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git add prompts/consumers.md lib/review-one-pr.sh prompts/critic.md prompts/aggregator.md
git commit -m "$(cat <<'EOF'
Add consumers specialist for internal call-graph integrity

Owns two finding classes that no specialist currently catches:

  1. stale-caller: PR modified a public symbol; a caller in this repo
     (or sibling tracked repo on this machine) no longer matches the
     new signature/shape. Runtime failure pending — blocking.
  2. dead: PR removed callers of a symbol, or upstream changes left
     conditionals unreachable. Zero callers / dead branches.
     Usually medium for public, low for private helpers.

External / public-API contract breaks are explicitly out of scope —
this product has no external consumers yet, so the only contracts
worth defending are internal seams.

LLM-only in this commit; Task 4 layers a deterministic static-tool
pre-pass (vulture / knip / ts-prune) on top to catch what the LLM
grep misses (and vice versa).

Wires `consumers` into the parallel fan-out (now 8 specialists).
Critic and aggregator extended; aggregator's ranking guidance puts
stale-caller findings at the top of the blocking band.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Add dead-code two-step pre-pass (static tool + LLM grep)

This task lands the investigation infrastructure that produces `.codex-scratch/dead-code.md` for the `consumers` specialist. Two sequential steps before fan-out:

1. **Static-tool pre-pass** (bash) — runs `DEAD_CODE_CMDS[$REPO]` on touched files, captures stdout to `.codex-scratch/dead-code-static.md`. Mirrors the kid pattern: per-repo command, graceful degrade on failure, never aborts the review.
2. **LLM dead-code-search pre-pass** (codex) — reads `dead-code-static.md` + `diff.patch`, walks the call graph for modified/removed public symbols, verifies static-tool candidates against dynamic-dispatch / decorators / framework hooks, writes structured evidence to `.codex-scratch/dead-code.md`. Mirrors the `intent` pre-pass pattern at `lib/review-one-pr.sh:637-665`.

The repos in this manifest do not currently have static tools wired across the board — only the Python repos get `vulture` initially. Other repos start with empty `DEAD_CODE_CMDS` entries; the LLM grep pre-pass still runs and produces evidence from the diff alone for those repos. Adding more static tools is a per-repo follow-up, not a blocker.

**Files:**
- Create: `prompts/dead-code-search.md`
- Modify: `repos.conf` (add `DEAD_CODE_CMDS` declaration + entries)
- Modify: `lib/tracked-repos.sh` (pre-declare `DEAD_CODE_CMDS` empty for `set -u` safety)
- Modify: `lib/review-one-pr.sh` (insert static-tool block + LLM pre-pass block; add `dead-code-static.md` and `dead-code.md` scratch writes)
- Modify: `prompts/common-header.md` (add `.codex-scratch/dead-code.md` to inputs list)
- Modify: `prompts/consumers.md` (sharpen language: now consumes structured evidence as primary mode; LLM grep is fallback for degraded state)

- [ ] **Step 1: Add `DEAD_CODE_CMDS` to `repos.conf`**

Append the following block to `/home/odio/Hacking/knightwatch-reviewer2/repos.conf`:

```bash

# Per-repo dead-code static-analysis commands. Run by the
# lib/review-one-pr.sh pre-pass on touched files; stdout is captured
# to .codex-scratch/dead-code.md for the `consumers` specialist to
# verify. Empty string = LLM-only for that repo (the specialist still
# runs; it just does its own grep).
#
# The command is `eval`'d with cwd = the PR's per-PR workdir. The
# variable $TOUCHED_FILES expands to a space-separated list of files
# the diff touched (paths relative to repo root). Tools that auto-
# scan the repo (knip, ts-prune) ignore $TOUCHED_FILES; tools that
# need explicit file args (vulture, ruff) consume it. Non-zero exit
# logs and degrades to LLM-only — the review never aborts on a
# pre-pass failure.
declare -A DEAD_CODE_CMDS=(
    ["cncorp/plow"]='vulture --min-confidence 80 $TOUCHED_FILES'
    ["cncorp/plow-content"]='vulture --min-confidence 80 $TOUCHED_FILES'
    ["srosro/tkmx-client"]=''
    ["srosro/tkmx-server"]=''
    ["srosro/knightwatch-reviewer"]=''
    ["srosro/vibe-engineering"]=''
)
```

(The non-Python repos start empty — the consumers specialist still runs LLM-only on those. Add tools as we wire them up; that's a per-repo follow-up, not a blocker for landing this plan.)

- [ ] **Step 2: Pre-declare `DEAD_CODE_CMDS` in `lib/tracked-repos.sh`**

Open `/home/odio/Hacking/knightwatch-reviewer2/lib/tracked-repos.sh` and find the existing `declare -A KID_PATHS=()` line. Add `DEAD_CODE_CMDS` next to it.

```diff
 declare -A KID_PATHS=()
+declare -A DEAD_CODE_CMDS=()
```

(This pre-declaration makes the lookup `${DEAD_CODE_CMDS[$REPO]:-}` safe under `set -u` even when `repos.conf` is absent in a sandboxed test — same pattern the file already uses for `KID_PATHS`.)

Also update the `# Source repos.conf if present` block's exported-variables comment if the file has one — keep documentation in sync. (Read the file first to confirm; if no such comment exists, skip this sub-step.)

- [ ] **Step 3: Add the pre-pass block to `lib/review-one-pr.sh`**

Open `/home/odio/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh`. Find the kid-prior-art block ending at line 549 (the line containing `fi` after the `elif [ -n "$KID_PROJECT_PATH" ]` branch). Insert the following block immediately after the closing `fi` of that block (so it runs after kid but before the `write_scratch` calls at line 553+):

```bash

# ---- dead-code static-tool pre-pass ----
# Mirrors the kid block above: per-repo command, graceful degrade on
# failure, output to a scratch file consumed by ONE specialist
# (`consumers`). DEAD_CODE_CMDS was loaded at file scope via the
# tracked-repos.sh loader; the pre-declared empty assoc array makes
# the lookup safe under `set -u` even in sandboxes without
# repos.conf.
DEAD_CODE=""
DEAD_CODE_CMD="${DEAD_CODE_CMDS[$REPO]:-}"
if [ -n "$DEAD_CODE_CMD" ]; then
    # TOUCHED_FILES = paths relative to repo root, extracted from the
    # diff's `+++ b/<path>` lines. Used by tools that need explicit
    # file args (vulture, ruff); ignored by tools that auto-scan
    # (knip, ts-prune).
    TOUCHED_FILES=$(printf '%s' "$KID_INPUT_DIFF" | grep -E '^\+\+\+ b/' | sed 's|^+++ b/||' | tr '\n' ' ')
    if [ -n "$TOUCHED_FILES" ]; then
        DEAD_CODE_STDERR=$(mktemp)
        DEAD_CODE=$(cd "$REPO_DIR" && eval "$DEAD_CODE_CMD" 2>"$DEAD_CODE_STDERR")
        DEAD_CODE_EXIT=$?
        if [ $DEAD_CODE_EXIT -ne 0 ]; then
            DC_ERR_SUMMARY=$(tail -n 3 "$DEAD_CODE_STDERR" | tr '\n' ' ')
            log "$PR_ID: dead-code pre-pass failed (exit $DEAD_CODE_EXIT) — degrading to LLM-only. stderr tail: $DC_ERR_SUMMARY"
            DEAD_CODE=""
        elif [ -n "$DEAD_CODE" ]; then
            CANDIDATE_COUNT=$(printf '%s\n' "$DEAD_CODE" | wc -l)
            log "$PR_ID: dead-code pre-pass produced $CANDIDATE_COUNT candidate line(s)"
        fi
        rm -f "$DEAD_CODE_STDERR"
    fi
fi
```

Then find the existing `write_scratch` calls (line 553-562) and add a new line for `dead-code.md`. Insert after the `prior-art.md` write (line 557), so the dead-code scratch is sandwiched between prior-art and standards:

```diff
 write_scratch "$REPO_DIR" "prior-art.md"       "${PRIOR_ART:-}"
+write_scratch "$REPO_DIR" "dead-code.md"       "${DEAD_CODE:-}"
 write_scratch "$REPO_DIR" "standards.md"       "$STANDARDS"
```

- [ ] **Step 4: Update `prompts/common-header.md`**

Find the `**Inputs already prepared for you:**` list and add a `dead-code.md` entry after the `prior-art.md` bullet.

```diff
 - `.codex-scratch/prior-art.md` — knightwatch-kid dry-check prior-art surface, if applicable. May be empty.
+- `.codex-scratch/dead-code.md` — language-specific static-tool candidates (vulture / knip / etc.) for unused symbols in touched files. Consumed by the `consumers` specialist; other specialists ignore it. Empty when no tool is wired for this repo, or when the tool found nothing.
 - `.codex-scratch/standards.md` — coding/testing standards and known review mistakes to avoid.
```

- [ ] **Step 5: Run `just test`**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
```

Expected: all checks pass — `bash -n` clean on the modified files, smoke tests green. The repos-conf-smoke checks the loader-contract; verify it still passes after adding `DEAD_CODE_CMDS` (the existing smoke loads `repos.conf` and checks `REPOS` and `KID_PATHS` are populated — adding a third assoc array shouldn't break it, but confirm).

If a `set -u` failure shows up: `lib/tracked-repos.sh` pre-declaration is missing or wrong. Fix and re-run.

If `repos-conf-smoke.sh` fails: the smoke may assert "no other top-level vars" — read its assertions and decide whether to extend the smoke (preferred) or whether the smoke's contract was unintentionally tight.

- [ ] **Step 6: Manual sanity check on one Python touched-file pre-pass (optional but recommended)**

Skip if `vulture` is not installed. Otherwise:

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
which vulture && vulture --min-confidence 80 lib/review-one-pr.sh || echo "vulture not installed — skip"
```

Expected: command runs cleanly (with or without findings — both are fine; we're checking the call path works).

- [ ] **Step 7: Commit**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git add repos.conf lib/tracked-repos.sh lib/review-one-pr.sh prompts/common-header.md
git commit -m "$(cat <<'EOF'
Wire dead-code static-tool pre-pass into consumers specialist

Adds a per-repo static-analysis command (DEAD_CODE_CMDS in repos.conf)
that runs on touched files and writes candidate dead symbols to
.codex-scratch/dead-code.md. The consumers specialist consumes that
file and verifies each candidate against dynamic-dispatch / decorator
/ framework-hook patterns the tools can't see.

Mirrors the existing kid → prior-art pattern: per-repo command,
graceful degrade on failure (stderr logged, scratch file empty,
review continues LLM-only). Pre-declared empty in tracked-repos.sh
for set -u safety in sandboxed tests.

Wired up: vulture for cncorp/plow + cncorp/plow-content. Other repos
start empty — consumers specialist runs LLM-only there until tools
are added per-repo (follow-up; not blocking).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Verify, push, open PR

- [ ] **Step 1: Final verification**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
just test
git log --oneline main..HEAD
git diff main..HEAD --stat
```

Expected `git log` (5 commits in this order):

1. `Plan: performance + consumers specialists`
2. `Add performance specialist with anti-premature-optimization framing`
3. `Add consumers specialist for internal call-graph integrity`
4. `Wire dead-code static-tool pre-pass into consumers specialist`

Expected `git diff --stat` covers:
- `docs/plans/2026-04-29-perf-and-consumers-specialists.md` (new, this file)
- `prompts/performance.md` (new, ~75 lines)
- `prompts/consumers.md` (new, ~80 lines)
- `prompts/common-header.md` (1-line addition)
- `prompts/critic.md` (3 small edits — count, read list, output template)
- `prompts/aggregator.md` (3 small edits — count, read list, ranking guidance)
- `lib/review-one-pr.sh` (1-line `ANGLES` extension + ~25-line pre-pass block + 1-line scratch write)
- `lib/tracked-repos.sh` (1-line pre-declaration)
- `repos.conf` (~15 lines for `DEAD_CODE_CMDS` + comments)

- [ ] **Step 2: Push and open PR**

```bash
cd /home/odio/Hacking/knightwatch-reviewer2
git push -u origin feat/perf-and-consumers-specialists
gh pr create --title "Add performance + consumers specialists" --body "$(cat <<'EOF'
## Summary

- Adds `performance` specialist with anti-premature-optimization framing — only flags real perf bugs whose fix is small/idiomatic. Disallows infra/redesign/caching-layer recommendations explicitly. Engineer-hours, not CPU.
- Adds `consumers` specialist for internal call-graph integrity — owns dead-code (zero callers) AND internal contract breaks (mismatched callers) on modified/removed public symbols. External APIs out of scope (no external consumers yet).
- Adds a deterministic dead-code static-tool pre-pass (per-repo command in `repos.conf`) that feeds candidate dead symbols to `consumers`. Mirrors the existing `kid` → `prior-art` pattern. Initially wired with `vulture` for the Python repos; other repos start LLM-only and wire tools as follow-ups.

## Why

Survey of 4 recent aggregator outputs (PR#22, #23, #24, vibe-engineering#3) showed two persistent gaps:

- Internal-contract-break is currently caught *by accident* — e.g. PR#22's blocking finding ("after merge, repos.conf is missing on existing installs → next tick hard-exits") was redundantly surfaced by data-integrity, simplification, AND shape, none of which actually owns "consumers no longer work after this change."
- Dead code and perf bugs are invisible — across all four reviews, zero findings of either class.

Per the calibration principle in `~/.claude/CODING_STANDARDS.md`, the perf specialist is anti-premature-optimization by construction — its disallowed-findings list explicitly rules out infra growth, hand-rolled SQL, and architecture changes. Severity is `blocking` only when (a) crash/OOM is imminent at current/near-term scale OR (b) the fix is one-line idiomatic.

## Test plan

- [x] `just test` green (bash -n + smoke suite)
- [ ] After merge + live-tree pull, trigger `/srosro-review` on a real PR; confirm 8 specialists launch and `performance.md` + `consumers.md` are produced.
- [ ] Review the next 5-10 generated reviews. Calibration checks:
  - perf findings: any that propose Redis / DB switch / hand-rolled SQL? If so, sharpen the disallowed-findings language.
  - consumers findings: any that flag external-API breaks despite the explicit scope rule? If so, sharpen.
  - stale-caller findings: any that landed `medium` instead of `blocking`? Aggregator ranking guidance may need a sharpen.
- [ ] On a Python PR (cncorp/plow), confirm `dead-code.md` is non-empty when vulture finds candidates. On a non-Python PR, confirm `dead-code.md` is empty and the consumers specialist still produces output (LLM-only path).

## Deployment note

`~/.pr-reviewer/{prompts,lib,repos.conf}` are all symlinks into `~/Hacking/knightwatch-reviewer/`. After merge, `git pull` in `~/Hacking/knightwatch-reviewer/` and the next timer tick (≤2 min) picks up the two new specialists, the new ANGLES list, and the pre-pass — no restart, no copy.

## Follow-ups (not blockers)

- Wire `knip` for `srosro/tkmx-client` and `srosro/tkmx-server` once we settle on TS dead-code tooling (separate PR).
- After 5-10 reviews, decide whether to split `consumers` into `dead-code` + `internal-contracts` if the prompt is over-loaded. Both halves would still consume the same `dead-code.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Return PR URL to user**

The PR URL printed by `gh pr create` is the handoff. User reviews, merges, and `git pull`s in the live tree.

---

## Self-Review Notes

- **Spec coverage:** every concern in the design conversation (perf framing with the OR-not-AND blocking rule, consumers covering both dead-code and internal-contract-break, static tools running before the specialist as a pre-pass, no architecture edit since external contracts are out of scope, no simplification trim since rare overlap is fine) is in a task.
- **Type/name consistency:** angle names are `performance` and `consumers` everywhere — `ANGLES` array, prompt filenames, scratch path (`.codex-scratch/specialists/{name}.md`), critic read list, aggregator read list. Pre-pass scratch is `.codex-scratch/dead-code.md` — singular, consumed by `consumers` only. `DEAD_CODE_CMDS` (plural-uppercase, matches `KID_PATHS` style) for the per-repo command map.
- **Placeholder scan:** none. All code blocks are concrete; severity rules and disallowed-findings lists are explicit.
- **Order dependency:** Task 3 lands consumers LLM-only; Task 4 layers the pre-pass on top. Reverse order would temporarily reference a missing specialist if Task 3 stalled. The chosen order means a stale `dead-code.md` reference in `consumers.md` resolves cleanly at every intermediate state (the file is just empty / absent).
- **Critic/aggregator count drift:** Task 2 bumps "Six → Seven", Task 3 bumps "Seven → Eight". If only Task 2 ships (and Tasks 3-4 stall), the count is consistent at "Seven." If Tasks 2-3 ship but Task 4 stalls, the consumers specialist runs LLM-only and reads an absent `dead-code.md` — the prompt's first paragraph handles that case explicitly.
- **Irony check:** the `consumers` prompt describes its own concern ("the PR modified or removed a public symbol; a caller no longer matches"). After this PR lands, *this PR's own diff* invites the consumers specialist to review the changes — i.e. did we modify any prompt's read-list contract without updating its consumer? The answer is no: critic and aggregator are updated in lockstep with the specialist additions; `common-header.md`'s inputs list documents `dead-code.md` for consistency. No consumer left behind.
- **Calibration follow-up plan:** the PR's test plan flags a 5-10-review review window for severity-calibration sharpening. The plan does not pre-bake calibration adjustments — that's iterative tuning the user does on real reviews, not something to encode now.
