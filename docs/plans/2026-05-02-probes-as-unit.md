# Probes-as-the-Unit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the LLM review pipeline so every specialist emits **probes** (one schema covering today's findings AND open-questions) with explicit specialist attribution. Critic's job becomes generating + answering probes with evidence rather than counter-arguing findings. Aggregator publishes a single ranked probe list with per-line `[from: <specialist>]` attribution. Removes the Findings/Open-Questions duality, the voice-posture rewrite-pass, and the REFRAME-AS-QUESTION funnel. Adds always-on complexity-cut probes and an AI-author callout (visible + hidden HTML comment).

**Architecture:** Probe schema lives in `prompts/standards.md` as the canonical contract. Each specialist prompt is rewritten to emit probes natively (replacing finding emission). The critic prompt is rewritten to (a) generate additional probes the specialists missed and (b) answer each probe with evidence (`grep`, `git log`, `decline-history.md`, `prior-art.md`); answered probes carry an explicit `Answer:` field that re-ranks them. The aggregator collapses Findings + Open Questions into one section, renders every line with `[from: <specialist>]`, and prepends both a human-visible AI-author callout and a hidden `<!-- knightwatch-reviewer:ai-author -->` HTML comment block. Replay-validation against historical PR SHAs uses an external `lib/replay.sh` shipping separately from `~/Hacking/knightwatch-reviewer feat/replay-harness` — this plan does not reproduce that tool.

**Tech Stack:** bash 5, codex CLI, gh CLI, jq, awk, gnu sed. Prompt files are Markdown.

**Branching (per CLAUDE.md):** This plan ships on `feat/probes-as-unit`. Each phase is its own PR via `/babysit-pr`. Do NOT auto-merge — merge decisions stay with the human.

---

## Why this is one plan, not two

The user's stated goal is *both* improving reviewer output (more complexity-cut questions, attribution, AI-author callout) *and* reducing complexity. The output improvements alone could ship as a sidecar (a new specialist that emits questions). But that would *add* concepts on top of an already-duplicative pipeline. The DRY refactor is what *removes* concepts. Both deliverables share a single underlying change — the probe schema — so they are one plan. Phases are gated so each is independently shippable; you can pause at the end of Phase 3 or Phase 5 and the system is coherent.

## File Structure

**Created:**

- `prompts/probe-schema.md` (~60 LOC, sourced into other prompts) — the probe contract referenced by every specialist + the critic + aggregator.
- `lib/tests/probe-schema-smoke.sh` (~80 LOC) — parses probe outputs, asserts schema fields present.

**Modified — prompts:**

- `prompts/standards.md` — add § Probe (the canonical unit) section.
- `prompts/common-header.md` — point specialists at probe-schema.md, drop voice-posture rewrite language (now native to the probe shape).
- `prompts/security.md`, `data-integrity.md`, `architecture.md`, `simplification.md`, `tests.md`, `shape.md`, `performance.md`, `consumers.md` — emit probes natively (Phase 2 + Phase 3).
- `prompts/critic.md` — generate-and-answer model; remove counter-argument structure, REFRAME-AS-QUESTION mechanics, voice-posture rewrite (Phase 4).
- `prompts/aggregator.md` — single ranked probe list, per-line attribution, AI-author callout (visible + hidden HTML comment) (Phase 5).
- `prompts/momentum.md` — emit a single probe, not prose (Phase 5).
- `prompts/go-deep.md` — re-key trigger from "≥20 LOC remedy" to "high-cost unanswered probe"; recommendations renamed to align with probe semantics (deferred to follow-up; not this plan).

**Modified — code:**

- `lib/critic-splitter.sh` — adapt to split probe-format critic output by `[from: <angle>]` instead of `[<angle>]` finding tags.
- `lib/orchestrate.sh` — minor logging change reflecting probe vocabulary.
- `lib/tests/anti-bloat-contract-smoke.sh` — new token fences for probe schema; remove fences referencing dropped concepts (REFRAME-AS-QUESTION, "Open Questions" section header).
- `lib/tests/critic-splitter-smoke.sh` — fixture updated to probe format.
- `lib/tests/critic-fallback-smoke.sh` — fallback emits an empty probe list.
- `justfile` — wire 1 new smoke (`probe-schema-smoke`).
- `README.md` — update specialist-pipeline description; reference probes.

**Out of scope for this plan (follow-up plan after Phase 5 lands):**

- Phase 6: go-deep re-keying. Probes-as-unit makes the trigger semantically simpler, but go-deep keeps working unchanged through Phase 5 (it reads the layered specialist files; probes are still per-angle text).
- Phase 7: deeper cleanup of dead voice-posture machinery and dual-rendering shims left as feature flags during the migration.

---

## Replay validation corpus

**Replay tool — external.** This plan does NOT build a replay tool; replay scaffolding ships in parallel from `~/Hacking/knightwatch-reviewer` on `feat/replay-harness`. When phases below say `./lib/replay.sh ...`, invoke `~/Hacking/knightwatch-reviewer/lib/replay.sh ...` instead — same CLI. Baselines (the rendered review for each corpus PR before any prompt changes) should also be captured from that repo before Phase 1 begins, OR fall back to manual spot-check against the publicly-posted bot reviews on each corpus PR (sampled at session start; broadly representative).

Every phase from Phase 1 onward includes a replay step. The fixed corpus is:

| Repo | PR | Why in corpus |
|---|---|---|
| `cncorp/plow` | 578 | small chore PR, OQ=None — floor case (does the new pipeline emit probes when current emits nothing?) |
| `cncorp/plow` | 576 | bug fix with OQ=None — bug case (does declarative-equivalent probe emerge?) |
| `srosro/knightwatch-reviewer` | 43 | substantive refactor with 1 OQ — mid case |
| `plow-pbc/watchmepivot` | 3 | gold-standard: bug findings AND a strong shape question — ceiling case |

For each replay, the spot-check is:

1. **No bug regressed**: every `[blocking]` finding in the old output appears as a probe with `Answer: yes (high)` in the new output.
2. **Attribution present**: every probe carries `[from: <specialist>]`.
3. **Complexity-cut probes appear**: at least one new probe surfaces an existing-complexity question with an inverted cost-naming clause that the old output didn't surface (subjective, but spot-checked per PR).
4. **LOC delta on rendered review**: total rendered review LOC stays flat or drops vs old output. A net-LOC increase on the same input set means we DRY'd into the wrong shape.

---


## Phase 1 — Probe schema + dual-format aggregator with attribution

The aggregator learns to render BOTH probe input AND legacy finding input, with `[from: <specialist>]` attribution on every line. No specialist or critic changes yet. Internal-only; user-visible review output is identical to baseline (because no specialist emits probes yet) — except every line now carries attribution.

This phase is shippable on its own: the only user-visible delta is `[from: …]` per line, which is the spot-check signal you asked for.

### Task 1.1: Define the probe schema

**Files:**
- Create: `prompts/probe-schema.md`
- Modify: `prompts/standards.md` (add § Probe section)

- [ ] **Step 1.1.1: Write `prompts/probe-schema.md`**

```markdown
# Probe — the unit of reviewer pushback

Every specialist (and the critic) emits zero or more **probes**. A probe is a single observation about the diff with the following fields:

```
### Probe N
- **From:** <specialist name>          # e.g. shape, security, simplification
- **Class:** <bug|bypass|shape|DRY|tests|dead-code|perf|complexity-cost>
- **Q:** <one sentence — the assumption being asserted as if settled, in question form>
- **Files:** <path:line>, <path:line>, …
- **If yes, edit:** <concrete code change this unlocks — name files + LOC delta>
- **If no, cost:** <one clause naming what calcifies if we keep current shape>
- **Confidence:** <high|medium|low>    # specialist's prior on Q being yes
- **Severity if yes:** <blocking|medium|low|nit>
- **Answer:** <yes|no|unknown>         # filled by critic with evidence; specialists default to "unknown"
- **Evidence:** <one line citing the grep/git-log/file-history finding that produced the answer; "—" if Answer=unknown>
```

## Posture

A probe with `Confidence: high, Answer: yes` and a cited failing path IS today's `[blocking]` declarative finding — the question is just compressed out at the rendering layer. A probe with `Confidence: low, Answer: unknown` IS today's Open Question. There is no separate "Findings" vs "Open Questions" concept. The same data type covers the spectrum.

## Cost-naming requirement

Every probe's `If no, cost:` clause MUST name what calcifies (a branch, a seam, a defensive guard, a shape) — not just "adds complexity". Bare cost-naming ("adds complexity and makes PMF iteration harder") is the floor; specific cost-naming ("calcifies a 3-branch dispatch that future routes must extend") is the ceiling.

## Inverted-cost probes

Probes about **existing complexity in the diff** invert the polarity: `If yes, edit:` becomes "delete the branch / collapse the abstraction / drop the schema field"; `If no, cost:` names what already-in-PR shape we're keeping. The Class for these is `complexity-cost`. Specialists are required to emit at least one `complexity-cost` probe per non-trivial PR — if none, the specialist's surveyed list MUST explain why.

## Rendering

The aggregator renders probes by `Answer`:

- `Answer: yes` → declarative outcome line + edit. Severity badge from `Severity if yes`.
- `Answer: unknown` → question line + if-yes/if-no cost. No severity badge.
- `Answer: no` → dropped entirely with a one-line footnote (`Probe dropped: <evidence>`).

Every rendered line carries `[from: <specialist>]`.
```

- [ ] **Step 1.1.2: Add § Probe section to `prompts/standards.md`**

Read the current standards.md, locate where § Broken-Glass Test ends, insert this AFTER that section:

```markdown
## Probe

The unit of reviewer pushback. See `prompts/probe-schema.md` for the full schema. Specialists emit probes; the critic answers them; the aggregator renders them. There is no separate Finding vs Open Question concept — both are probes at different points on the (Confidence, Answer) axis.

The pre-PMF cost-naming requirement applies to every probe's `If no, cost:` clause. The probe schema makes the question-posture native rather than retrofitted via an aggregator rewrite-pass.
```

- [ ] **Step 1.1.3: Commit**

```bash
git add prompts/probe-schema.md prompts/standards.md
git commit -m "feat(prompts): probe schema as canonical reviewer-pushback unit"
```

### Task 1.2: Probe-schema smoke test

**Files:**
- Create: `lib/tests/probe-schema-smoke.sh`

The smoke parses a probe-formatted input and asserts every probe has all required fields. This is the deterministic test infrastructure that every later phase uses to verify specialist/critic output adheres to the schema.

- [ ] **Step 1.2.1: Write the smoke**

```bash
#!/bin/bash
# Asserts a probe-formatted input has all required fields per probe.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Fixture: a valid probe block
FIXTURE_OK="$(cat <<'EOF'
### Probe 1
- **From:** shape
- **Class:** complexity-cost
- **Q:** Does the new `_stub_oauth_flow_proc.returncode = None` lifecycle ever fire?
- **Files:** tests/test_oauth.py:120
- **If yes, edit:** keep the lifecycle simulation
- **If no, cost:** calcifies a fake-state branch tests must preserve
- **Confidence:** medium
- **Severity if yes:** low
- **Answer:** unknown
- **Evidence:** —
EOF
)"

# Fixture: a missing-field input
FIXTURE_BAD="$(cat <<'EOF'
### Probe 1
- **From:** shape
- **Q:** missing other fields
EOF
)"

# Source the parser (Phase 1.3 will add it)
. "$REPO_ROOT/lib/probe-parse.sh"

if probe_validate <<<"$FIXTURE_OK"; then
    echo "OK: valid probe accepted"
else
    echo "FAIL: valid probe rejected"; exit 1
fi

if ! probe_validate <<<"$FIXTURE_BAD"; then
    echo "OK: invalid probe rejected"
else
    echo "FAIL: invalid probe accepted"; exit 1
fi
```

- [ ] **Step 1.2.2: Run smoke and verify it fails (probe-parse.sh missing)**

```bash
bash lib/tests/probe-schema-smoke.sh
# Expected: FAIL — sourcing nonexistent file
```

### Task 1.3: Probe parser

**Files:**
- Create: `lib/probe-parse.sh`

- [ ] **Step 1.3.1: Implement parser**

```bash
#!/bin/bash
# Probe parser. Sourceable. Functions:
#   probe_validate    — read probe-formatted text on stdin, exit 0 if all probes
#                       have required fields, exit 1 otherwise. Logs to stderr.
#   probe_extract_field FIELD — read on stdin, print the value of FIELD per probe.
#
# Required fields (from prompts/probe-schema.md):
REQUIRED_PROBE_FIELDS=(From Class Q Files "If yes, edit" "If no, cost" Confidence "Severity if yes" Answer Evidence)

probe_validate() {
    local input
    input="$(cat)"
    [ -z "$input" ] && return 0
    local missing=0 probe_block field
    # Split on "### Probe " headers
    while IFS= read -r probe_block; do
        [ -z "$probe_block" ] && continue
        for field in "${REQUIRED_PROBE_FIELDS[@]}"; do
            if ! grep -q "^- \*\*${field}:\*\*" <<<"$probe_block"; then
                echo "missing field: $field" >&2
                missing=1
            fi
        done
    done < <(awk '/^### Probe / {if (block) print block "\n---SPLIT---"; block=$0; next} {block = block ORS $0} END {if (block) print block}' <<<"$input" | tr '\n' '\037' | sed 's/\x1f---SPLIT---\x1f/\n/g' | tr '\037' '\n')
    return "$missing"
}

probe_extract_field() {
    local field="$1"
    grep "^- \*\*${field}:\*\*" | sed "s/^- \*\*${field}:\*\* //"
}
```

- [ ] **Step 1.3.2: Run smoke and verify it passes**

```bash
bash lib/tests/probe-schema-smoke.sh
# Expected: OK lines for both fixtures
```

- [ ] **Step 1.3.3: Wire smoke into justfile and commit**

Add to `justfile` test recipe:

```make
    echo ""
    echo "=== probe-schema smoke test ==="
    bash lib/tests/probe-schema-smoke.sh
```

```bash
just test
git add lib/probe-parse.sh lib/tests/probe-schema-smoke.sh justfile
git commit -m "feat(probe-parse): validator + extractor for probe-formatted text"
```

### Task 1.4: Aggregator dual-format rendering with attribution

The aggregator currently reads `specialists/<angle>.md` files (each containing legacy findings). It now learns: if the file contains `### Probe N` blocks, render those; if it contains legacy findings, render those WITH `[from: <angle>]` injected on each finding line. After Phase 2-3 every specialist emits probes, but the dual path is what lets the migration be incremental.

**Files:**
- Modify: `prompts/aggregator.md`

- [ ] **Step 1.4.1: Add probe-rendering instructions to aggregator.md**

Find the `**Findings**` template block (around `aggregator.md:156-158`). Insert before it:

```markdown
**Probe rendering — read each `specialists/<angle>.md` and detect format.**

- If the file contains one or more `### Probe N` blocks (probe format), render each probe per `prompts/probe-schema.md` § Rendering. Carry `From:` through as `[from: <specialist>]` on the rendered line.
- If the file contains legacy findings (no `### Probe` headers), render them as before, but inject `[from: <angle>]` immediately after the severity badge on every line. The `<angle>` is the filename stem of the specialist file.

Until every specialist emits probes, the rendered review will be a mix of both formats. Order all rendered items by:

1. `Answer: yes` with `Severity if yes: blocking` (or legacy `[blocking]`)
2. `Answer: yes` with `Severity if yes: medium` (or legacy `[medium]`)
3. `Answer: unknown` (probe form only; legacy "Open Questions" items are absent here)
4. `Answer: yes` with `Severity if yes: low` / `nit` (or legacy `[low]`/`[nit]`)

Drop `Answer: no` probes entirely (footnote allowed: `Probe dropped: <evidence>`).
```

- [ ] **Step 1.4.2: Add temporary attribution to the existing legacy template**

Find the existing `**Findings**` line-format template (`aggregator.md:157`):

```markdown
1. [blocking|medium|low|nit] <one paragraph, cite Files: path:line, cite the standard violated where applicable (Fail-Fast, Tests, Concise Code, DRY, Narrow-Fix, Spec-Reframe, Migrations)>
```

Replace with:

```markdown
1. [blocking|medium|low|nit] [from: <specialist>] <one paragraph, cite Files: path:line, cite the standard violated where applicable (Fail-Fast, Tests, Concise Code, DRY, Narrow-Fix, Spec-Reframe, Migrations)>
```

The attribution is now on every Findings line. Open Questions items also get attribution; find the Open Questions example (`aggregator.md:166`) and prepend `[from: <specialist>]` to the example pattern.

- [ ] **Step 1.4.3: Add Open Questions attribution to its template**

Find `aggregator.md:162`:

```markdown
- **Q: <name the choice in 5-10 words>** — <state-trigger sentence>. <If-yes branch.> <If-not branch with cost-naming.> <Optional: recommendation given operating point.>
```

Replace with:

```markdown
- [from: <specialist>] **Q: <name the choice in 5-10 words>** — <state-trigger sentence>. <If-yes branch.> <If-not branch with cost-naming.> <Optional: recommendation given operating point.>
```

- [ ] **Step 1.4.4: Update the example output line in aggregator.md**

Find the example (`aggregator.md:166`):

```markdown
- **Q: Permanent fourth taxonomy class, or one-off?** — Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder.
```

Replace with:

```markdown
- [from: shape] **Q: Permanent fourth taxonomy class, or one-off?** — Will we add a 2nd `team-skills/` bundle in the next month? If yes, the taxonomy row pays for itself now. If not, consider cutting the taxonomy demand — adds complexity and makes PMF iteration harder.
```

- [ ] **Step 1.4.5: Anti-bloat fence for the new attribution token**

Edit `lib/tests/anti-bloat-contract-smoke.sh`. Find the existing `Open Questions` token assertion (`anti-bloat-contract-smoke.sh:127`). Add immediately after:

```bash
echo "  asserting [from: <specialist>] attribution token in aggregator.md..."
grep -q '\[from: <specialist>\]' "$REPO_ROOT/prompts/aggregator.md" \
    || { echo "FAIL: aggregator.md missing [from: <specialist>] attribution token"; exit 1; }
```

- [ ] **Step 1.4.6: Run full smoke and commit**

```bash
just test
git add prompts/aggregator.md lib/tests/anti-bloat-contract-smoke.sh
git commit -m "feat(aggregator): per-line specialist attribution + probe-format support"
```

### Task 1.5: Replay corpus and verify Phase 1 baseline

**Files:** none changed; this is a verification step.

- [ ] **Step 1.5.1: Replay all 4 corpus PRs with Phase 1 prompts**

```bash
for spec in \
    "cncorp/plow 578" \
    "cncorp/plow 576" \
    "srosro/knightwatch-reviewer 43" \
    "plow-pbc/watchmepivot 3"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" \
        --output-dir "replays/phase1/${repo//\//-}-${pr}"
done
```

- [ ] **Step 1.5.2: Spot-check assertion: every line carries attribution**

```bash
for f in replays/phase1/*/aggregator-output.md; do
    echo "=== $f ==="
    # Every Findings line + every OQ line should have [from: ...]
    grep -E '^[0-9]+\.|^- \*\*Q:' "$f" | grep -v '\[from: ' && {
        echo "FAIL: lines missing attribution"; exit 1;
    } || echo "OK: all attributed"
done
```

- [ ] **Step 1.5.3: Commit replay output as a one-off artifact (NOT to repo — they're in .gitignore)**

No commit. The replay output is a local working artifact. The phase-completion signal is the spot-check passing.

---

## Phase 2 — Migrate `shape` specialist to probes (canary)

`shape.md` is the canary because it's already the most question-shaped of the 8 specialists (its "two questions you exist to answer" frame, `shape.md:7`). Migrating it first proves the schema works for a question-rich specialist before touching bug-emitting ones.

### Task 2.1: Rewrite `prompts/shape.md` to emit probes

**Files:**
- Modify: `prompts/shape.md`

- [ ] **Step 2.1.1: Update `shape.md` to emit probes natively**

The existing prompt's structure (read inputs, walk diff, classify each construct, emit findings) is preserved. Only the **emission format** changes — instead of severity-tagged finding paragraphs, emit a numbered list of probe blocks per `prompts/probe-schema.md`.

Replace the existing emission section (everything from `**Method (walk the diff):**` through the end of the file's emission instructions, around line 47) with:

```markdown
**Method (walk the diff):**

For each new construct, name its problem class and emit a probe per `prompts/probe-schema.md`. Common classes — and the canonical shape you should grep for in this repo:

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

For each construct, emit a probe with:

- `Class: bypass` — canonical exists, PR sidestepped it. Cite both files. `Confidence: high`, `Severity if yes: blocking`. `If yes, edit:` "rewrite to call the canonical at <path:line>". `If no, cost:` "establishes a parallel seam future routes must reckon with".
- `Class: shape` — second-instance, no canonical yet. `Confidence: medium`, `Severity if yes: medium`. `If yes, edit:` "extract <name> at <path:line> as the canonical shape". `If no, cost:` "third instance will be cheaper to write than to refactor — pattern established by inertia".
- `Class: complexity-cost` — existing complexity in the diff that may not be needed (defensive branches, validation guards, helpers added with one call site, schema fields, env vars, abstractions, parallel modes). `Confidence: low|medium`. `If yes, edit:` "delete <specific code> — fewer LOC, fewer seams". `If no, cost:` name the specific shape that calcifies if kept.

You MUST emit at least one `complexity-cost` probe on any non-trivial PR. If none applies, append to your Surveyed section: "No complexity-cost probe — explanation: <one sentence>".

Where this overlaps with other specialists:
- `simplification` owns DRY (N near-identical blocks), kid-prior-art, verbose conditional/early-return cleanups, drive-by tidies, dead-code-on-touched-files.
- `architecture` owns layering, lock-in, roadmap fit, cross-cutting *strategic* decisions.
- You own: simplest-viable-shape-vs-spirit-of-ask, instance-1 bypass, "second instance — establish now," wrong-shape (regex on structured input, hand-rolled when canonical exists), and **existing-complexity probes**.

Some duplicate probes between you and the other two are expected — that's by design; this failure mode is high-stakes. The critic dedupes via `DUPLICATE OF`.

Out of scope: specific security bugs, concurrency bugs, test coverage, line-level style, stale callers (consumers owns those).

**Emission format:**

Emit a numbered list of probe blocks per `prompts/probe-schema.md`. Set `Answer: unknown` and `Evidence: —` on every probe — the critic fills these in via grep/git-log. Do NOT emit legacy `[severity]` finding paragraphs. If you have nothing to emit, write `No probes.` on a single line followed by a `## Surveyed` section explaining what you looked at and why nothing surfaced (≥1 probe is expected on non-trivial PRs; zero probes signals either a perfect PR or a missed angle, and the Surveyed section is how you prove you looked).

Look beyond the diff: the repo's canonical shapes live in `lib/`, `core/`, base classes, decorator modules, the framework's docs. Grep for the symbols you're evaluating (e.g. `grep -rn "Config" --include="*.py"` to find a Config helper before judging an `os.getenv` call).
```

- [ ] **Step 2.1.2: Add anti-bloat fence for `complexity-cost` token**

Edit `lib/tests/anti-bloat-contract-smoke.sh`, add (next to existing fences):

```bash
echo "  asserting complexity-cost probe class in shape.md..."
grep -q 'Class: complexity-cost' "$REPO_ROOT/prompts/shape.md" \
    || { echo "FAIL: shape.md missing complexity-cost class"; exit 1; }
```

- [ ] **Step 2.1.3: Run smoke and commit**

```bash
just test
git add prompts/shape.md lib/tests/anti-bloat-contract-smoke.sh
git commit -m "feat(shape): emit probes natively, require complexity-cost probe"
```

### Task 2.2: Replay corpus, validate shape's probe output

**Files:** none changed.

- [ ] **Step 2.2.1: Replay corpus**

```bash
for spec in \
    "cncorp/plow 578" \
    "cncorp/plow 576" \
    "srosro/knightwatch-reviewer 43" \
    "plow-pbc/watchmepivot 3"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" \
        --output-dir "replays/phase2/${repo//\//-}-${pr}"
done
```

- [ ] **Step 2.2.2: Validate shape probes are well-formed**

```bash
for f in replays/phase2/*/agents/shape/output.md; do
    if grep -q '^### Probe ' "$f"; then
        bash lib/probe-parse.sh probe_validate < "$f" || {
            echo "FAIL: $f probes malformed"; exit 1
        }
    fi
done
```

- [ ] **Step 2.2.3: Spot-check ceiling case**

For `replays/phase2/plow-pbc-watchmepivot-3/agents/shape/output.md`: confirm at least one `complexity-cost` probe surfaces and the existing 3 shape findings (single-owner seam violation around `vad-rotate.py:232/auto-rotate.py:342/347`) appear as probes with `Confidence: high` and `Severity if yes: blocking`.

- [ ] **Step 2.2.4: Spot-check floor case**

For `replays/phase2/cncorp-plow-578/agents/shape/output.md`: a chore PR may produce `No probes.` with a Surveyed section — that's correct. Confirm Surveyed exists.

- [ ] **Step 2.2.5: Commit Phase 2 PR**

This is the natural PR boundary. Push the branch, open a PR, run `/babysit-pr`. Phase 2 lands behind that PR before Phase 3 begins.

```bash
git push -u origin feat/probes-as-unit
gh pr create --title "feat: probes-as-unit foundation (Phases 1-2)" --body "$(cat <<'EOF'
## Summary
- Phase 1: probe schema + per-line specialist attribution in aggregator output
- Phase 2: `shape` specialist migrated to probe-native emission with mandatory complexity-cost probe

Foundation for the probes-as-unit refactor. Output format adds `[from: <specialist>]` to every line; `shape` emissions are now probe-formatted while other 7 specialists still emit legacy findings (aggregator handles both). Replay validation is via the external `~/Hacking/knightwatch-reviewer feat/replay-harness` tool.

## Test plan
- [ ] `just test` green
- [ ] Replay corpus shows shape probes well-formed and at least one complexity-cost probe per non-trivial PR
- [ ] `[from: shape]` visible on shape's items in rendered review
EOF
)"
```

Then `/babysit-pr <PR#>`. **Stop here until that PR is merged.**

---

## Phase 3 — Migrate remaining 7 specialists in batches

Three batches, each its own PR. Each batch follows the same pattern as Task 2.1 — rewrite the specialist's emission section to produce probes, run replay, spot-check.

### Task 3.1: Batch A — `simplification` + `architecture`

These two are next-most question-shaped and least likely to interact with safety-critical bug findings.

**Files:**
- Modify: `prompts/simplification.md`
- Modify: `prompts/architecture.md`

- [ ] **Step 3.1.1: Branch off main, fast-forward main first**

```bash
git checkout main && git pull --ff-only
git checkout -b feat/probes-as-unit-batch-a
```

- [ ] **Step 3.1.2: Rewrite simplification.md emission section to probes**

Read the current file. Replace the severity-tuning + look-beyond-the-diff tail with explicit probe emission instructions analogous to shape.md:

```markdown
**Emission format:**

Emit a numbered list of probe blocks per `prompts/probe-schema.md`. Class options:

- `Class: DRY` — kid-hit or intra-PR duplication that should collapse into a helper. `Confidence: medium|high`. `Severity if yes: medium` (or `blocking` for the well-established-utility-was-already-there case). `If yes, edit:` name the shared helper with LOC delta. `If no, cost:` name the third-copy threshold this PR is approaching.
- `Class: complexity-cost` — verbose implementation, missing early-return, defensive `(x or {}).get(...)`-style code, drive-by-tidy unused import / dead local helper. `Confidence: medium`. `Severity if yes: low|nit`. `If yes, edit:` "delete <code> / collapse to <shorter shape> — N LOC delta". `If no, cost:` name the specific defensive shape that calcifies.

You MUST emit at least one `complexity-cost` probe on any non-trivial PR. If none applies, append to your Surveyed section: "No complexity-cost probe — explanation: <one sentence>".

Set `Answer: unknown` and `Evidence: —` on every probe — the critic fills these. Do NOT emit legacy `[severity]` finding paragraphs.

If you have nothing to emit, write `No probes.` on a single line followed by a `## Surveyed` section.

Look beyond the diff: grep the repo for existing utilities/base classes that the PR's new code should have reused.
```

- [ ] **Step 3.1.3: Rewrite architecture.md emission section to probes**

Read current file. Replace severity-tuning section with probe emission analogous to above. Architecture probes are typically `Class: shape` or `Class: complexity-cost`. Same `Answer: unknown` default, same complexity-cost mandate.

- [ ] **Step 3.1.4: Run smoke, replay, validate, commit**

```bash
just test
for spec in "cncorp/plow 576" "plow-pbc/watchmepivot 3" "srosro/knightwatch-reviewer 43"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" \
        --output-dir "replays/phase3a/${repo//\//-}-${pr}"
done

# Validate
for f in replays/phase3a/*/agents/{simplification,architecture}/output.md; do
    if grep -q '^### Probe ' "$f"; then
        bash lib/probe-parse.sh probe_validate < "$f" || { echo "FAIL: $f"; exit 1; }
    fi
done

git add prompts/simplification.md prompts/architecture.md
git commit -m "feat(prompts): probe-native emission for simplification + architecture"
git push -u origin feat/probes-as-unit-batch-a
gh pr create --title "feat: probe-native simplification + architecture" --body "Batch A of probes-as-unit Phase 3."
```

Then `/babysit-pr <PR#>`. Stop until merged.

### Task 3.2: Batch B — `consumers` + `tests` + `performance`

Same pattern. These three are mostly observation-class specialists; tests is largely yes/no on coverage gaps and tends to produce few probes.

**Files:**
- Modify: `prompts/consumers.md`
- Modify: `prompts/tests.md`
- Modify: `prompts/performance.md`

- [ ] **Step 3.2.1: Branch from main**

```bash
git checkout main && git pull --ff-only
git checkout -b feat/probes-as-unit-batch-b
```

- [ ] **Step 3.2.2: Rewrite each prompt's emission section**

For each of the 3 files, replace the severity-tuning + emission instructions with probe-format instructions analogous to Task 3.1.2. Probe classes per specialist:

- `consumers.md` → `Class: dead-code` (stale callers, dead public symbols), `Class: complexity-cost`.
- `tests.md` → `Class: tests` (coverage gap or test-shape problem), `Class: complexity-cost` (over-tested edge cases, mock-vs-real divergence).
- `performance.md` → `Class: perf`, `Class: complexity-cost` (premature optimization).

Each must include the mandatory `complexity-cost` probe + Surveyed-explanation rule.

- [ ] **Step 3.2.3: Run smoke, replay, validate, commit, PR, babysit**

```bash
just test
# Replay corpus, validate, commit (analogous to Task 3.1.4)
for spec in "cncorp/plow 576" "plow-pbc/watchmepivot 3" "srosro/knightwatch-reviewer 43"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" --output-dir "replays/phase3b/${repo//\//-}-${pr}"
done

git add prompts/consumers.md prompts/tests.md prompts/performance.md
git commit -m "feat(prompts): probe-native emission for consumers + tests + performance"
git push -u origin feat/probes-as-unit-batch-b
gh pr create --title "feat: probe-native consumers + tests + performance" --body "Batch B of probes-as-unit Phase 3."
```

Then `/babysit-pr <PR#>`. Stop until merged.

### Task 3.3: Batch C — `security` + `data-integrity`

These two emit safety-critical bug findings. The probe schema MUST preserve their declarative blocking voice when the bug is real. The probe with `Confidence: high, Severity if yes: blocking, Answer: unknown (specialist's prior)` renders identically to today's `[blocking]` finding once the critic answers `Answer: yes` with the cited failing path.

**Files:**
- Modify: `prompts/security.md`
- Modify: `prompts/data-integrity.md`

- [ ] **Step 3.3.1: Branch**

```bash
git checkout main && git pull --ff-only
git checkout -b feat/probes-as-unit-batch-c
```

- [ ] **Step 3.3.2: Rewrite security.md emission section**

These are bug specialists. Probes here typically have `Confidence: high` (the specialist saw the failing path) and `Severity if yes: blocking`. The Q form is "Is this code path reachable in production with the cited input?" — when the path is named, the answer is effectively `yes`.

Replace the existing emission instructions with:

```markdown
**Emission format:**

Emit a numbered list of probe blocks per `prompts/probe-schema.md`. Class options:

- `Class: bug` — security defect: secret leak, auth bypass, command injection, path traversal, sandbox escape, exposed control plane, credential logging. `Confidence: high` when you can cite the failing path; `medium` when the trigger requires a configuration the diff doesn't change but the repo permits. `Severity if yes: blocking` for high-confidence + user-observable; `medium` for hardening notes. `If yes, edit:` name the specific code change. `If no, cost:` "—" (security probes don't take an inverted-cost stance).
- `Class: complexity-cost` — security-defensive code that may be overkill at the operating point: extra signature checks, defense-in-depth not requested, wrap-once-then-wrap-again validation. `Confidence: low|medium`. `If yes, edit:` "delete <code> — N LOC". `If no, cost:` name the threat model that justifies keeping it.

You MUST emit at least one `complexity-cost` probe on any PR that adds new defensive code. If none applies (PR adds no defensive surface), append to your Surveyed section: "No complexity-cost probe — explanation: <one sentence>".

When the failing path is fully cited (the specialist saw the bug), set `Confidence: high` and the critic will likely confirm `Answer: yes` immediately. The aggregator renders that as a declarative `[blocking] [security]` line — the question is compressed out at the rendering layer per `prompts/probe-schema.md` § Rendering.

Set `Answer: unknown` and `Evidence: —` on every probe — the critic fills these.
```

- [ ] **Step 3.3.3: Rewrite data-integrity.md emission section**

Same pattern. Bug class is `data-integrity`: silent drops, lost writes, money-affecting state inconsistency, race conditions, transactional violations. Same complexity-cost mandate (defensive transactional wrappers, retry layers added without observed need).

- [ ] **Step 3.3.4: Replay, validate that bugs do NOT regress**

This is the most critical replay check in the entire plan: every `[blocking]` finding the security/data-integrity specialists currently produce on the corpus must reappear as a high-confidence probe in the new format.

```bash
just test

# Replay all 4 corpus PRs
for spec in "cncorp/plow 578" "cncorp/plow 576" "srosro/knightwatch-reviewer 43" "plow-pbc/watchmepivot 3"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" --output-dir "replays/phase3c/${repo//\//-}-${pr}"
done

# Spot-check: watchmepivot#3 baseline had 2 [blocking] security/data-integrity items
# (public noVNC exposure, fourth-instance deploy-contract drift). Confirm both reappear.
for finding in "noVNC" "deploy-contract drift\\|deploy contract"; do
    grep -E "$finding" "replays/phase3c/plow-pbc-watchmepivot-3/aggregator-output.md" \
        || { echo "FAIL: bug regressed — $finding missing"; exit 1; }
done

# Same for cncorp/plow#575 if it's still a comparable case (check baseline first).
```

If any bug regresses, the cause is almost certainly that the prompt rewrite dropped detection language. Diff the prompt against baseline, restore the missing detection guidance, replay until green.

- [ ] **Step 3.3.5: Commit, push, PR, babysit**

```bash
git add prompts/security.md prompts/data-integrity.md
git commit -m "feat(prompts): probe-native emission for security + data-integrity"
git push -u origin feat/probes-as-unit-batch-c
gh pr create --title "feat: probe-native security + data-integrity (bug-class)" --body "Batch C of probes-as-unit Phase 3 — last specialist migration. Replay corpus confirms no bug regressed."
```

`/babysit-pr <PR#>`. Stop until merged.

---

## Phase 4 — Critic refactor: generate + answer probes

The critic stops being a counter-argument layer and becomes a **probe-resolver**. For each specialist's probe, the critic does one of three things: (a) answer with evidence (`Answer: yes` + cited grep/git-log + `Severity if yes` confirmed) → renders declaratively; (b) drop with evidence (`Answer: no` + cited grep showing zero firings or operator-already-declined) → renders as a one-line footnote; (c) leave open (`Answer: unknown` confirmed + reason) → renders as an Open Question. The critic ALSO **generates** probes the specialists missed (replacing today's "surface findings the specialists collectively missed" instruction), in the same probe format.

REFRAME-AS-QUESTION goes away. Voice-posture rewrite goes away. The Pre-PMF lens is collapsed into the answer-with-evidence step (its job was always to ask "does this fire at our operating point?" — that IS what answering a probe means).

### Task 4.1: Rewrite `prompts/critic.md` to probe-resolver model

**Files:**
- Modify: `prompts/critic.md`

- [ ] **Step 4.1.1: Branch**

```bash
git checkout main && git pull --ff-only
git checkout -b feat/probes-as-unit-critic
```

- [ ] **Step 4.1.2: Replace critic.md core section**

This is the biggest single prompt rewrite in the plan. The full new file is below; replace the existing `prompts/critic.md` content from line 28 (`**Your job:**`) through end of file with:

```markdown
**Your job — probe resolution.**

For each probe in `.codex-scratch/specialists/<angle>.md` files (per `prompts/probe-schema.md`), determine its `Answer` field with evidence and update the probe in place. ALSO: generate any probes the specialists collectively missed and append them to a new `.codex-scratch/specialists/critic.md` file with `From: critic`.

For each probe, set `Answer:` to one of:

- **`yes`** — the assumption is true. Cite evidence: a grep result, git-log line, file-history entry, decline-history mention, or the specialist's own cited `Files:` confirms the question. The probe will render as a declarative outcome with severity.
- **`no`** — the assumption is false. Cite evidence: grep showing zero call-sites, git-log showing the case never occurred, decline-history showing the operator already declined this class ≥3 rounds, or your own diff-read showing the probe misread the code. The probe will be dropped from the rendered review with a one-line footnote.
- **`unknown`** — the question is real, the evidence is genuinely ambiguous, the author should answer. Use this when (a) the assumption is plausible but neither grep nor history can confirm or deny, OR (b) the probe is a `complexity-cost` probe whose answer depends on whether a future case appears. The probe will render as an open question.

For each probe you set `Answer: yes`, also set `Evidence:` to a one-line citation. The same applies to `Answer: no` (cite the drop reason). For `Answer: unknown`, set `Evidence:` to a one-line note explaining what evidence is missing (so the author can supply it).

**Generation pass.** After resolving every input probe, scan the diff yourself for assumptions stated as if settled that no specialist probed. For each, emit a new probe (per `prompts/probe-schema.md`) with `From: critic` and `Answer: unknown` (let the next critic pass or the operator close it). The 8 specialists necessarily have angle-blind spots; this pass is your generative role.

**Carry-forward stress-test (re-reviews only).** If `previous-review.md` is non-empty, also resolve every probe in it (parsed from the prior review's rendered probes). Specialists only see the incremental diff and won't re-emit probes about unchanged code, so without this pass a probe that was answered `yes` once becomes immune to re-evaluation.

**K-decay (engagement-aware re-evaluation).** For each carried-forward probe, count rounds since author engaged with it (engagement = a commit on this branch touching the cited files OR an author comment quoting/replying). Then:

- K = 1–2: keep `Answer:` as set; author is presumably working on it.
- K ≥ 3 with no engagement and Class ≠ bug: change `Answer:` to `unknown`. Either the probe is mis-scoped or the author has materially deferred it; silence at K ≥ 3 is signal. The Severity stays as set; the probe just becomes Open instead of Blocking.
- K ≥ 5 with no engagement and Class ≠ bug: change `Answer:` to `no` with `Evidence: dropped — K=5 silence, see decline-history.md`.
- Class = bug: never K-decay; answer stays as set.

**Decline-history channel.** Two channels in `.codex-scratch/decline-history.md`:

- *Explicit class markers* (`<!-- decline:class=X -->` count ≥ 3): set `Answer: no`, `Evidence: declined N rounds, class=X`.
- *Free-form prose*: read for context; if the operator's prose pushes back on a class similar to a probe's Class, cite the prior decline reason in `Evidence:` and set `Answer: unknown` (operator's reasoning is the evidence; this PR's diff may or may not change the calculus).

**Self-referential spec guard.** If a probe cites the PR's own newly-added spec/plan/doc as the contract being violated, set `Answer: no` with `Evidence: self-referential — spec is mutable in this PR`.

**Output format — exactly this:**

```
## Resolved probes (per specialist)

For each input file `.codex-scratch/specialists/<angle>.md`, emit one section:

### [from: <angle>] Probe N
- **Answer:** <yes|no|unknown>
- **Evidence:** <one-line citation>
- **Severity if yes:** <blocking|medium|low|nit — confirm or override the specialist's prior>

(Repeat for every probe in the input file.)

## Generated probes (critic-originated)

Probe blocks per `prompts/probe-schema.md`, with `From: critic` and `Answer: unknown`.
```

The orchestrator's critic-splitter (`lib/critic-splitter.sh`) reads this output and updates each `specialists/<angle>.md` file in place: each Probe N block gets its `Answer:`, `Evidence:`, `Severity if yes:` fields filled in by the corresponding `### [from: <angle>] Probe N` section above. The Generated probes section is appended to `specialists/critic.md`.
```

- [ ] **Step 4.1.3: Update `lib/critic-splitter.sh` to apply probe answers**

Read the current splitter. The current code splits critic output by `[<angle>]` finding tags and appends to per-specialist files. The new model UPDATES probe fields in place. This is more involved, but bounded.

```bash
# Skeleton of the new lib/critic-splitter.sh (replace the existing split function)
split_critic_to_specialists() {
    local critic_out="$1"
    local specialists_dir="$2"

    # Section 1: parse "## Resolved probes (per specialist)" — for each
    # "### [from: <angle>] Probe N" block, find Probe N in
    # specialists/<angle>.md and update its Answer/Evidence/Severity-if-yes
    # fields in place using awk.
    awk '
        /^### \[from: ([a-z-]+)\] Probe ([0-9]+)$/ {
            match($0, /\[from: ([a-z-]+)\] Probe ([0-9]+)/, m);
            angle = m[1]; probe_n = m[2];
            in_block = 1; answer = ""; evidence = ""; severity = "";
            next;
        }
        in_block && /^- \*\*Answer:\*\* / { answer = $0; next }
        in_block && /^- \*\*Evidence:\*\* / { evidence = $0; next }
        in_block && /^- \*\*Severity if yes:\*\* / { severity = $0; next }
        in_block && /^$/ {
            in_block = 0;
            cmd = "lib/probe-update.sh " specialists_dir "/" angle ".md " probe_n;
            print answer | cmd; print evidence | cmd; print severity | cmd;
            close(cmd);
        }
    ' "$critic_out"

    # Section 2: append generated probes to specialists/critic.md
    awk '/^## Generated probes/{p=1; next} p' "$critic_out" \
        > "$specialists_dir/critic.md"
}
```

Plus a small helper `lib/probe-update.sh` that takes a specialist file + probe number and replaces the matching probe's Answer/Evidence/Severity-if-yes lines in place.

- [ ] **Step 4.1.4: Update `lib/tests/critic-splitter-smoke.sh` for the new probe-resolver shape**

Replace the existing fixture with a probe-formatted critic output and assert the splitter correctly updates a fixture `specialists/<angle>.md`.

- [ ] **Step 4.1.5: Update `lib/tests/critic-fallback-smoke.sh`**

The fallback path (when critic codex run fails) should produce an empty resolved-probes block + empty generated-probes block. The aggregator handles `Answer: unknown` (the specialists' default) gracefully — every probe just renders as Open.

- [ ] **Step 4.1.6: Run smoke, replay corpus, validate**

```bash
just test
for spec in "cncorp/plow 578" "cncorp/plow 576" "srosro/knightwatch-reviewer 43" "plow-pbc/watchmepivot 3"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" --output-dir "replays/phase4/${repo//\//-}-${pr}"
done

# Validate: every probe in every specialist file has a non-default Answer.
for f in replays/phase4/*/agents/*/output.md; do
    if grep -q '^### Probe ' "$f"; then
        unanswered=$(grep -c '\*\*Answer:\*\* unknown$' "$f" || true)
        # Some unknowns are correct (open probes); just log the count
        echo "$f: $unanswered probes still Answer=unknown after critic"
    fi
done

# Bug-regression check: same as Task 3.3.4 — no [blocking] watchmepivot#3 bug missing
```

- [ ] **Step 4.1.7: Commit, push, PR, babysit**

```bash
git add prompts/critic.md lib/critic-splitter.sh lib/probe-update.sh lib/tests/critic-splitter-smoke.sh lib/tests/critic-fallback-smoke.sh
git commit -m "refactor(critic): probe-resolver + generator (replaces counter-argument model)"
git push -u origin feat/probes-as-unit-critic
gh pr create --title "refactor(critic): probe-resolver + generator" --body "Phase 4 of probes-as-unit. Critic now answers probes with evidence + generates missed ones; REFRAME-AS-QUESTION mechanism replaced by Answer: unknown/yes/no triplet."
```

`/babysit-pr <PR#>`. Stop until merged.

---

## Phase 5 — Aggregator output collapse + AI-author callout

The aggregator stops emitting separate Findings + Open Questions sections. Single ranked probe list. Adds the AI-author callout — visible block + hidden HTML comment marker. This is the user-visible payoff phase.

### Task 5.1: Collapse Findings + Open Questions into single ranked probe list

**Files:**
- Modify: `prompts/aggregator.md`

- [ ] **Step 5.1.1: Branch**

```bash
git checkout main && git pull --ff-only
git checkout -b feat/probes-as-unit-aggregator
```

- [ ] **Step 5.1.2: Replace the output template (around `aggregator.md:149-173`)**

Replace the current output structure block with:

```markdown
7. Produce the final posted review in EXACTLY this structure. Target 300-500 words for typical PRs; flex to 1000 for large diffs only if length carries content. Step-back signal mode (above) overrides this length contract — a redirect review is 200-400 words even when the underlying PR has 20 probes.

```
_<intent line, italicized — see formatting rule below>_

**Overview** — 2-3 sentences on what the PR does.

**Strengths** — non-obvious things done right so the author repeats them. Omit this section if none.

**Probes** — read every `specialists/<angle>.md` and `specialists/critic.md` file. Render the resolved probes in this order:

1. `Answer: yes` AND `Severity if yes: blocking` — declarative outcome line, descending by Class severity (bug > bypass > shape > DRY > complexity-cost).
2. `Answer: yes` AND `Severity if yes: medium`.
3. `Answer: unknown` — open probes, ordered by `Confidence: high` first then `medium` then `low`.
4. `Answer: yes` AND `Severity if yes: low|nit`.

Rendering format:

For `Answer: yes`:
```
N. [<severity>] [from: <specialist>] [<class>] <Q recast as declarative outcome — name the failing path / structural shape / cost — one paragraph>. Files: <path:line>, …. Edit: <If yes, edit: clause verbatim>.
```

For `Answer: unknown`:
```
N. [open] [from: <specialist>] [<class>] **Q: <Q in 5-10 words>** — <Q full text>. If yes, <If yes, edit clause>. If no, <If no, cost clause>.
```

Drop `Answer: no` probes. If you want to acknowledge a notable drop, footnote it under the Probes block: `Probe dropped: <one-line rationale + evidence>`.

**Security** — one sentence summary keyed off the highest-severity `Class: bug, Specialist: security` probe, or "None" if no security probes are answered yes.

**Test coverage** — summary keyed off the highest-severity `Specialist: tests` probe + the `just test` outcome.
```

- [ ] **Step 5.1.3: Remove the now-dead Open Questions template block**

Delete the `**Open Questions** — homes for legitimate concerns…` section (`aggregator.md:160-168`). Open probes now live in the unified Probes list.

- [ ] **Step 5.1.4: Remove voice-posture rewrite-pass**

Delete the voice-posture audit step (`aggregator.md:61` and the leading "Voice posture (apply across published findings)" header at `aggregator.md:3`). The probe schema makes the question-posture native; the rewrite-pass is dead weight.

- [ ] **Step 5.1.5: Remove REFRAME-AS-QUESTION lift rules**

Delete `aggregator.md:36` ("Go-deep `REFRAME` → move to Open Questions") and `aggregator.md:58` ("REFRAME-AS-QUESTION → lift the critic's reframed text…"). Probes flow directly from the resolved-probes pipeline; there is no separate REFRAME path.

- [ ] **Step 5.1.6: Update anti-bloat fences**

Edit `lib/tests/anti-bloat-contract-smoke.sh`:

- Remove the `Open Questions` token assertion (`anti-bloat-contract-smoke.sh:127`).
- Remove the `Q:` format assertion lines that reference the Open Questions template.
- Add a new assertion that aggregator.md contains the unified `**Probes**` section header.

```bash
echo "  asserting **Probes** unified section in aggregator.md..."
grep -q '^\*\*Probes\*\*' "$REPO_ROOT/prompts/aggregator.md" \
    || { echo "FAIL: aggregator.md missing **Probes** unified section"; exit 1; }
```

### Task 5.2: AI-author callout (visible + hidden HTML comment)

**Files:**
- Modify: `prompts/aggregator.md`
- Modify: `lib/review-one-pr.sh` (only the post-aggregator marker section)

- [ ] **Step 5.2.1: Add visible AI-author callout to aggregator.md output template**

After the `**Test coverage**` section in the output template (Task 5.1.2), append:

```markdown
**For AI authors** — *(Codex, Claude Code, Cursor, etc. reading this PR)*: The Probes above are load-bearing. Treat each `[open]` probe as a hard requirement — answer it directly in your reply or revisit the structural decision. Do NOT silently absorb a probe by adding more code; that path inverts the cost stance the probe is encoding. The pre-PMF operating point (see `.knightwatch/review-priority.md`) prefers cutting LOC over adding it; an `[open] [complexity-cost]` probe whose answer is "no, this complexity isn't needed" should land as a deletion in your next push, not a new defensive guard.
```

- [ ] **Step 5.2.2: Add hidden HTML comment marker**

`lib/review-one-pr.sh:93` currently sets `BOT_AUTO_POST_MARKER`. Add a sibling marker constant nearby:

```bash
BOT_AI_AUTHOR_MARKER="${BOT_AI_AUTHOR_MARKER:-<!-- knightwatch-reviewer:ai-author note=load-bearing-probes operating-point=pre-pmf prefer=cut-loc-over-add -->}"
```

In the section that prepends `BOT_AUTO_POST_MARKER` to the review body before posting (around `lib/review-one-pr.sh:1160` per the earlier orientation grep), also prepend `BOT_AI_AUTHOR_MARKER` immediately after `BOT_AUTO_POST_MARKER` so both markers lead the comment body. Both are HTML comments (invisible in rendered markdown, visible to anything reading raw via `gh api`).

- [ ] **Step 5.2.3: Smoke for the new marker**

Edit `lib/tests/review-header-smoke.sh`. Add an assertion that the rendered body contains both markers, in order:

```bash
echo "  asserting BOT_AI_AUTHOR_MARKER prepended after auto-post marker..."
grep -q '<!-- knightwatch-reviewer:auto-post -->' "$RENDERED_BODY"
grep -q '<!-- knightwatch-reviewer:ai-author' "$RENDERED_BODY"
```

- [ ] **Step 5.2.4: Run smoke, replay, validate**

```bash
just test

for spec in "cncorp/plow 578" "cncorp/plow 576" "srosro/knightwatch-reviewer 43" "plow-pbc/watchmepivot 3"; do
    repo="${spec% *}"; pr="${spec##* }"
    sha="$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)"
    ./lib/replay.sh --repo "$repo" --pr "$pr" --sha "$sha" --output-dir "replays/phase5/${repo//\//-}-${pr}"
done

# Per-probe attribution check
for f in replays/phase5/*/aggregator-output.md; do
    grep -E '^[0-9]+\.' "$f" | grep -v '\[from: ' && {
        echo "FAIL: probe lines missing attribution in $f"; exit 1
    }
done

# Single section check
for f in replays/phase5/*/aggregator-output.md; do
    if grep -q '^\*\*Findings\*\*' "$f"; then
        echo "FAIL: $f still has **Findings** section — should be **Probes**"; exit 1
    fi
    if grep -q '^\*\*Open Questions\*\*' "$f"; then
        echo "FAIL: $f still has **Open Questions** section — should be unified"; exit 1
    fi
done

# AI-author markers present
for f in replays/phase5/*/run.log; do
    grep -q 'knightwatch-reviewer:ai-author' "$f" || {
        echo "FAIL: ai-author marker missing in $f"; exit 1
    }
done

# Ceiling-case bug regression check (same as Phase 3.3.4)
for finding in "noVNC" "deploy-contract drift\\|deploy contract"; do
    grep -E "$finding" "replays/phase5/plow-pbc-watchmepivot-3/aggregator-output.md" \
        || { echo "FAIL: bug regressed — $finding missing"; exit 1; }
done

# LOC delta sanity: phase5 rendered review should be no longer than baseline
for repo_pr in plow-pbc-watchmepivot-3 srosro-knightwatch-reviewer-43; do
    base_loc=$(wc -l < "replays/baseline/$repo_pr/aggregator-output.md")
    new_loc=$(wc -l < "replays/phase5/$repo_pr/aggregator-output.md")
    echo "$repo_pr: baseline $base_loc → phase5 $new_loc"
    [ "$new_loc" -le "$((base_loc + 5))" ] || {
        echo "WARN: phase5 grew >5 LOC vs baseline — investigate"
    }
done
```

- [ ] **Step 5.2.5: Update README.md**

The README's "How it works" section (`README.md:33`) currently describes the pipeline using "specialists" + "critic" + "aggregator" with verdicts of `APPROVE` or "blocking findings". Update the prose to reference probes instead of findings — keep it brief, just reflect the unified vocabulary.

- [ ] **Step 5.2.6: Commit, push, PR, babysit**

```bash
git add prompts/aggregator.md lib/review-one-pr.sh lib/tests/review-header-smoke.sh lib/tests/anti-bloat-contract-smoke.sh README.md
git commit -m "feat(aggregator): unified probe rendering + AI-author callout"
git push -u origin feat/probes-as-unit-aggregator
gh pr create --title "feat: unified probe rendering + AI-author callout (Phase 5)" --body "$(cat <<'EOF'
## Summary
- Aggregator output collapses Findings + Open Questions into a single ranked **Probes** section.
- Per-line `[from: <specialist>]` attribution on every rendered probe.
- AI-author callout: visible block + hidden `<!-- knightwatch-reviewer:ai-author -->` HTML comment.
- Removes voice-posture rewrite-pass, REFRAME-AS-QUESTION lift rules.

## Test plan
- [ ] `just test` green
- [ ] Replay corpus: every line attributed, single Probes section, ai-author marker present, no bug regressed
- [ ] LOC delta: rendered review no longer than baseline on watchmepivot#3 + knightwatch#43
EOF
)"
```

`/babysit-pr <PR#>`. Stop until merged.

---

## Self-Review

**1. Spec coverage:**
- "Improve reviewer output (more complexity-cut questions)" → Phase 2-3 mandate `complexity-cost` probes per non-trivial PR (Task 2.1.1, 3.1.2, 3.2.2, 3.3.2, 3.3.3).
- "Reduce complexity (DRY findings/questions)" → Phase 4 collapses critic counter-argument + REFRAME-AS-QUESTION + Pre-PMF lens into one probe-resolver model (Task 4.1.2). Phase 5 collapses Findings + Open Questions sections (Task 5.1.2-5.1.5).
- "Deterministically name the specialist for every probe" → Phase 1 adds `[from: <specialist>]` to every aggregator-rendered line (Task 1.4.2-1.4.4).
- "AI-author callout" → Phase 5 (Task 5.2.1-5.2.3) — visible block + hidden HTML comment marker `<!-- knightwatch-reviewer:ai-author -->`.
- "Replay-validatable per Sam's preference" → external replay tool ships from `~/Hacking/knightwatch-reviewer feat/replay-harness`; every phase below ends with a replay validation step that invokes that tool against the same 4-PR corpus.

**2. Placeholder scan:** no `TBD`, `implement later`, `add appropriate error handling`. Each prompt-rewrite step shows the actual replacement text. Each smoke test shows the actual fixture.

**3. Type consistency:**
- Probe schema fields are introduced in Task 1.1.1 and used identically in every later task: `From`, `Class`, `Q`, `Files`, `If yes, edit`, `If no, cost`, `Confidence`, `Severity if yes`, `Answer`, `Evidence`.
- `[from: <specialist>]` token format is consistent across Task 1.4.2, 1.4.3, 5.1.2, 5.2.4 spot-checks.
- Marker constants follow existing convention (`BOT_AUTO_POST_MARKER`, `BOT_AI_AUTHOR_MARKER`).
- Class enumerations: `bug, bypass, shape, DRY, tests, dead-code, perf, complexity-cost` introduced in `prompts/probe-schema.md` (Task 1.1.1) and used consistently in Task 2.1.1, 3.1.2, 3.2.2, 3.3.2.

---

## Out-of-scope follow-ups

After this plan ships:

- **Phase 6: go-deep re-keying.** Change trigger from "≥20 LOC remedy finding" to "high-cost unanswered probe (Confidence: medium+ AND Severity if yes: blocking|medium AND Answer: unknown)". Same fan-out machinery; just a different selection function. Probably 1-2 days of work.
- **Phase 7: deeper cleanup.** Remove the legacy-finding rendering path from the aggregator (Task 1.4.1 said it would render both formats; after Phase 3 every specialist emits probes, so the legacy path is dead code). Remove the Pre-PMF-lens conditional logic in any prompts that still reference it. Final smoke-test pass to ensure no orphaned tokens remain in `anti-bloat-contract-smoke.sh`.

These are smaller, both bounded by Phase 5's structure. Recommend writing one follow-up plan covering both after Phase 5 lands and the team has lived with the new format for a week.
