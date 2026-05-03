# Three-way Review-Quality Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Empirically validate that the two prompt-quality bugs we diagnosed (Bug 1: solution-shaped questions; Bug 2: Broken-Glass Test inversion as a brake on simplification) account for the regression observed across `cncorp/plow#563/#565/#569`, by producing a single comparison artifact: bot's May-1 production review (OLD), today's HEAD-prompts replay (CURRENT), and a NEW-design replay against prompts patched per the diagnosis. The deliverable is `docs/comparison-2026-05-02.md` — a per-PR side-by-side of all three infrastructures, including specialist outputs and quality notes.

**Architecture:** Use the existing replay harness (`lib/replay.sh` with `PROMPTS_DIR` override, shipped on PR #48) plus production run-dirs from wakeup (`/home/odio/.pr-reviewer/runs/`) which already contain every specialist output, critic output, and aggregator output from the bot's actual May-1 reviews. No new tooling — this is a comparison study using existing infrastructure.

The NEW-design variant is **not the full probes-as-unit refactor**. It's a minimum-viable patch to current prompts that addresses both diagnosed bugs:
- Bug 1 fix: tighten Q-field shape rules in `prompts/standards.md` § Broken-Glass Test (state-shaped Qs only) + add WRONG/RIGHT examples
- Bug 2 fix: add explicit Broken-Glass-as-pro-simplification rule + anti-inversion examples in the same section
- Critic: tighten REFRAME-AS-QUESTION criteria so it only fires on genuinely-uncertain assumptions, not on declined-simplification findings
- No specialist file changes (keeps blast radius small for this experiment)

If the NEW-design replay shows finding-density and severity recovering toward OLD-baseline levels, that motivates executing the full `feat/probes-as-unit` plan with confidence. If it doesn't, we've ruled out a hypothesis cheaply.

**Tech Stack:** bash, codex CLI via `ssh odio@wakeup`, `lib/replay.sh` from PR #48, `gh` CLI, `jq`, `scp`, markdown.

**Cost budget:** ~$8 (4 codex replays × ~$2 each) + free wakeup-state archeology.

**Branching:** This plan ships on `feat/probes-as-unit` (the user's existing branch). The NEW-design prompt patches go in a working `prompts.new-design/` dir scoped to this experiment; if the results justify it, those edits get folded into the probes-as-unit Phase 1+ specs.

---

## File Structure

**Created:**
- `prompts.new-design/` (copy of `prompts/` with surgical Bug 1 + Bug 2 fixes — only `standards.md`, `common-header.md`, `critic.md` differ from `prompts/`)
- `docs/comparison-2026-05-02.md` — the artifact (markdown table + analysis)
- `replays/comparison/<pr>/old/` — production run-dir copies (1 per PR)
- `replays/comparison/<pr>/current/` — symlinks to existing replay outputs (post-#45 HEAD prompts)
- `replays/comparison/<pr>/new/` — fresh replays against NEW-design prompts

**Modified:**
- (none in this plan; `prompts.new-design/` is a sibling directory not touching production prompts)

---

## Pre-flight check (operator-run, not a task)

Before starting, verify on the local Mac:
- Branch is `feat/probes-as-unit` (`git status` shows clean working tree)
- Wakeup SSH works (`ssh odio@wakeup 'echo ok'`)
- Codex on wakeup is authenticated and not at usage limit (`ssh odio@wakeup 'PATH=/home/odio/.npm-global/bin:$PATH codex --version'`)
- `lib/replay.sh` exists and is from PR #48's branch (cherry-picked or merged)

If `lib/replay.sh` doesn't exist on `feat/probes-as-unit`, abort and merge PR #48 first.

---

## Task 1: Collect OLD-infrastructure baseline (production run-dirs from wakeup)

**Files:**
- Create: `replays/comparison/cncorp-plow-569/old/`
- Create: `replays/comparison/cncorp-plow-563/old/`
- Create: `replays/comparison/cncorp-plow-565/old/`

The R1 production run-dirs on wakeup contain everything needed: per-specialist `output.md`, critic `output.md`, aggregator `output.md`, `meta.json`, `run.log`, and (under `inputs/`) the full diff + scratch files the bot saw. These are **the actual May-1 production reviews** we're using as the OLD-infra baseline. No codex calls — just file copy.

The exact run-dirs (R1 reviews matching the SHAs we already audited):
- `#569` R1 → `cncorp_plow__569__20260501T170623735Z__dcb80a5` (sha `dcb80a5a3d…`, posted 2026-05-01T17:27:02Z)
- `#563` R1 → `cncorp_plow__563__20260430T222823066Z__48419b4` (sha `48419b4b1a…`, posted 2026-04-30T22:42:20Z)
- `#565` R1 → `cncorp_plow__565__20260501T020010565Z__852beef` (sha `852beef00a…`, posted 2026-05-01T02:09:52Z)

- [ ] **Step 1.1: Pull each R1 run-dir from wakeup**

```bash
cd ~/Hacking/knightwatch-reviewer
mkdir -p replays/comparison/cncorp-plow-569/old replays/comparison/cncorp-plow-563/old replays/comparison/cncorp-plow-565/old

scp -q -r odio@wakeup:/home/odio/.pr-reviewer/runs/cncorp_plow__569__20260501T170623735Z__dcb80a5 replays/comparison/cncorp-plow-569/old/run-dir
scp -q -r odio@wakeup:/home/odio/.pr-reviewer/runs/cncorp_plow__563__20260430T222823066Z__48419b4 replays/comparison/cncorp-plow-563/old/run-dir
scp -q -r odio@wakeup:/home/odio/.pr-reviewer/runs/cncorp_plow__565__20260501T020010565Z__852beef replays/comparison/cncorp-plow-565/old/run-dir
```

- [ ] **Step 1.2: Verify each run-dir is structurally complete**

```bash
for pr in 569 563 565; do
    dir=replays/comparison/cncorp-plow-$pr/old/run-dir
    test -f "$dir/meta.json" || { echo "FAIL: missing meta.json in $dir"; exit 1; }
    test -f "$dir/agents/aggregator/output.md" || { echo "FAIL: missing aggregator/output.md in $dir"; exit 1; }
    for s in security data-integrity architecture simplification tests shape performance consumers intent critic; do
        test -f "$dir/agents/$s/output.md" || { echo "FAIL: missing $s/output.md in $dir"; exit 1; }
    done
    echo "OK: $dir is complete"
done
```

Expected: 3 `OK:` lines.

- [ ] **Step 1.3: Pull the GitHub-posted review text (with header notes) per PR**

Production posts the aggregator output to GitHub with deterministic header notes prepended (`> 📋 First review of this PR. ...`). The aggregator's raw `output.md` doesn't include those. Pull the exact posted comment text:

```bash
for pr in 569 563 565; do
    case "$pr" in
        569) ts="2026-05-01T17:27:02Z" ;;
        563) ts="2026-04-30T22:42:20Z" ;;
        565) ts="2026-05-01T02:09:52Z" ;;
    esac
    gh api "repos/cncorp/plow/issues/$pr/comments" --paginate \
        --jq "[.[] | select(.user.login==\"srosro\") | select(.body | startswith(\"<!-- knightwatch-reviewer:auto-post -->\")) | select(.body | (contains(\"review aborted\")|not))][0] | .body" \
        > replays/comparison/cncorp-plow-$pr/old/posted-review.md
    test -s replays/comparison/cncorp-plow-$pr/old/posted-review.md || { echo "FAIL: empty posted-review for #$pr"; exit 1; }
    echo "OK: pulled #$pr posted review ($(wc -c < replays/comparison/cncorp-plow-$pr/old/posted-review.md) bytes)"
done
```

Expected: 3 `OK:` lines, each with body bytes > 1000.

- [ ] **Step 1.4: Commit the OLD-baseline data (no LLM calls; deterministic)**

```bash
git add replays/comparison/
git commit -m "$(cat <<'EOF'
data(comparison): old-infra baseline — production R1 run-dirs + posted reviews

Pull the May-1 actual production-review run-dirs for cncorp/plow#563/565/569
R1 from wakeup, plus the posted GitHub comment text. These are the
gold-standard "old infrastructure" baseline for the three-way comparison.

Includes per-specialist output.md, critic output.md, aggregator output.md,
meta.json, run.log per PR. ~3MB per run-dir.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Consolidate CURRENT-infrastructure baseline (already-replayed outputs)

**Files:**
- Symlink/move: existing `replays/cncorp-plow-{569-dcb80a5,563-48419b4,565-852beef}/` → `replays/comparison/<pr>/current/`

The post-#45 HEAD-prompts replays from earlier work are already on disk under `replays/cncorp-plow-*-` (without the `comparison/` prefix and without `-pre45`/`-variant-X` suffixes). Move them into the comparison structure.

- [ ] **Step 2.1: Move current-infra replay artifacts into the comparison structure**

```bash
cd ~/Hacking/knightwatch-reviewer
mv replays/cncorp-plow-569-dcb80a5  replays/comparison/cncorp-plow-569/current
mv replays/cncorp-plow-563-48419b4  replays/comparison/cncorp-plow-563/current
mv replays/cncorp-plow-565-852beef  replays/comparison/cncorp-plow-565/current
```

- [ ] **Step 2.2: Verify each has aggregator-output.md + per-specialist outputs**

```bash
for pr in 569 563 565; do
    dir=replays/comparison/cncorp-plow-$pr/current
    test -f "$dir/aggregator-output.md" || { echo "FAIL: missing aggregator-output.md in $dir"; exit 1; }
    test -d "$dir/agents" || { echo "FAIL: missing agents/ in $dir"; exit 1; }
    echo "OK: $dir is complete"
done
```

Expected: 3 `OK:` lines.

- [ ] **Step 2.3: Commit the move**

```bash
git add replays/comparison/
git commit -m "$(cat <<'EOF'
data(comparison): current-infra baseline — consolidate existing post-#45 replays

Move the already-run post-#45 HEAD-prompts replays into the comparison
structure under replays/comparison/<pr>/current/. No new replays;
existing artifacts from the replay-harness validation work.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Build NEW-design prompts (`prompts.new-design/`)

**Files:**
- Create: `prompts.new-design/` (copy of current `prompts/` with surgical edits to 3 files)
- Modify in copy: `prompts.new-design/standards.md`, `prompts.new-design/common-header.md`, `prompts.new-design/critic.md`

The NEW-design variant patches three issues into the existing prompt set without restructuring:

1. **Bug 1 (state-shaped Qs)**: add a § Q-field shape block in `standards.md` § Broken-Glass Test, with WRONG/RIGHT examples; reference it from `common-header.md` and `critic.md`.
2. **Bug 2 (Broken-Glass anti-inversion)**: add an explicit "Broken-Glass NEVER means decline-to-simplify" anti-pattern block in the same standards section.
3. **REFRAME-AS-QUESTION tightening**: in `critic.md`, narrow the criteria so REFRAME-AS-QUESTION only fires when the critic genuinely doubts the underlying assumption — not when the finding's remedy is small/legitimate but reframable.

- [ ] **Step 3.1: Copy current prompts to a sibling directory**

```bash
cd ~/Hacking/knightwatch-reviewer
rm -rf prompts.new-design
cp -r prompts prompts.new-design
diff -rq prompts prompts.new-design
```

Expected: empty output (perfect copy).

- [ ] **Step 3.2: Patch `prompts.new-design/standards.md` — add the Q-field shape block**

Locate the `## Broken-Glass Test` section in `prompts.new-design/standards.md`. Find the existing subsection `### Question template` (which currently shows the bare template `Will [user state X / data shape Y / scale Z]?`). Immediately AFTER that subsection, insert this new subsection:

```markdown
### Q-field shape — required

The Q must be about external state: user behavior, data shape, OS contract,
deadline, scale, or production observation. NOT a question about whether to
apply the proposed code change.

The test: replace "Q" with "Will [Q's premise] hold in the world?" — does
that read as a fact you could in principle verify by looking at user data,
an OS manual, or production logs? If yes, the Q is well-formed. If no — if
the only way to "verify" the Q is to make the code change and see — the Q
is begging the question and must be rewritten.

Wrong-shape examples (these are the failure modes seen in production):

✗ "Does the lifecycle ever fire?"     — about code paths; circular
✗ "Can the parser live in one helper?" — about the proposed solution
✗ "Will we maintain X as one contract?" — begs the question (asks the
   author to validate the action, not the world-state premise)
✗ "Should we extract this into a helper?" — asks about the action

Right-shape examples (each Q is about an external fact whose answer dictates
whether the proposed action is worth the cost):

✓ "Will hdiutil's output format drift across macOS versions?"
   (external fact — checkable via macOS release notes; answer dictates
   whether a shared helper is needed)
✓ "Do users ever have negative bank account balances?"
   (data-shape fact — checkable via a prod query)
✓ "Will the connector list grow past 8 entries before PMF?"
   (scale fact — checkable via roadmap / user feedback)
✓ "Will errors here be observed in production at our current call volume?"
   (state fact — checkable via logs / bug tracker)

Inverted-cost questions (about EXISTING complexity in the diff) follow the
same rule: ask whether the SCENARIO the existing complexity handles is real,
not whether the simplification is "worth it":

✗ "Should we extract this into a helper?" (asks about the action)
✓ "Will hdiutil's output format diverge between the 3 call sites' macOS
   versions before this branch ships?"
   (asks about the world; answer informs whether the helper pays for itself)

### Broken-Glass is pro-simplification

Broken-Glass means *push for elegant code that lets the team validate the
product faster*. DRY refactors, removing duplication, collapsing branches,
deleting dead code — all of these are aligned WITH the rule, not against it.

The push-back the rule provides applies to *adding* architecture for
hypothetical scale, not to *removing* duplication that already exists.

Wrong-application example (this is the failure mode seen in production):

✗ "Broken-Glass Test: this is a code-quality question, not a failing-path
   bug — keep the duplicate parser code as-is."

Right-application example:

✓ Broken-Glass favors collapsing the 3-place parser into one helper. Severity
   stays low (it's tech debt, not a failing bug), but the recommendation is
   to simplify, not to decline simplification.

If a finding asks to *remove* code (DRY, dead code, unreachable branch), the
remedy-cost framing inverts: the **default** is to apply it, and the burden
shifts to naming why keeping the existing complexity is worth it.
```

- [ ] **Step 3.3: Patch `prompts.new-design/common-header.md` — point at the new section**

Locate the existing `**Operating point and voice posture (READ FIRST):**` block. Append one sentence at the end of that block:

```markdown
**Q-field shape:** every non-bug question MUST follow `standards.md` § Q-field shape — Qs are about external state (user data, OS contract, scale, deadline), never about whether to apply the proposed code change. Wrong-shape Qs are pre-merge gates the reviewer enforces on its own output before submitting.
```

- [ ] **Step 3.4: Patch `prompts.new-design/critic.md` — tighten REFRAME-AS-QUESTION**

Locate the existing REFRAME-AS-QUESTION section (around line 70–100). Find the bullet that defines when REFRAME-AS-QUESTION applies:

```
**REFRAME-AS-QUESTION** — finding's underlying concern is real (so it's not FALSE POSITIVE), AND the proposed remedy is additive (adds defensive code, abstraction, validation, test, branch, file), AND the author could legitimately decide either way once the assumption is named.
```

Replace that bullet with:

```
**REFRAME-AS-QUESTION** — applies ONLY when the critic genuinely doubts the underlying assumption. Three required conditions, ALL must hold:
  (a) the finding's underlying concern is real (not FALSE POSITIVE),
  (b) the critic can articulate a plausible world-state where the finding
      would not apply (e.g. "if hdiutil output stays stable, three local
      parsers are fine") — this articulation IS the reframed Q,
  (c) the remedy is additive (adds defensive code, abstraction, validation,
      branch, file) — REMOVAL findings (DRY, dead code, unreachable branch)
      DO NOT qualify; per `standards.md` § Broken-Glass is pro-simplification,
      removal findings stay declarative even when severity is low.

  When applied, the reframed Q MUST follow `standards.md` § Q-field shape —
  state-shaped, not solution-shaped. A reframed Q that asks "should we apply
  this remedy" is malformed; the critic must rewrite it as a question about
  external state whose answer dictates whether the remedy pays for itself.
```

- [ ] **Step 3.5: Sanity-check the diff is exactly 3 files**

```bash
cd ~/Hacking/knightwatch-reviewer
diff -rq prompts prompts.new-design | wc -l
# Expected: 3 (one diff line per file: standards.md, common-header.md, critic.md)
diff -rq prompts prompts.new-design
```

Expected output:
```
Files prompts/standards.md and prompts.new-design/standards.md differ
Files prompts/common-header.md and prompts.new-design/common-header.md differ
Files prompts/critic.md and prompts.new-design/critic.md differ
```

- [ ] **Step 3.6: Smoke the new prompts (no LLM call) — verify they parse**

```bash
# Same prompt-build smoke that production uses, with PROMPTS_DIR override
PROMPTS_DIR="$(pwd)/prompts.new-design" bash -c '
    . lib/prompt-build.sh
    OUT=$(build_specialist_prompt simplification "$PROMPTS_DIR/simplification.md" "test/repo#1" "title" "https://x" "alice")
    echo "$OUT" | grep -qF "Q-field shape" && echo "OK: standards.md Q-field block reachable from common-header"
    echo "$OUT" | grep -qF "Broken-Glass is pro-simplification" && echo "OK: anti-inversion block reachable"
'
```

Expected: 2 `OK:` lines.

- [ ] **Step 3.7: Commit `prompts.new-design/`**

```bash
git add prompts.new-design
git commit -m "$(cat <<'EOF'
feat(prompts.new-design): patch Bug 1 (Q-field shape) + Bug 2 (BG anti-inversion)

Sibling directory to prompts/ — surgical fix targeting the two diagnosed
prompt-quality bugs:

Bug 1 (solution-shaped questions) — add § Q-field shape to standards.md
with WRONG/RIGHT examples. State-shaped Qs only; "Will [external fact]
hold?" not "Will we apply [solution]?". Reference from common-header.md
so every specialist sees the rule.

Bug 2 (Broken-Glass inversion) — add § "Broken-Glass is pro-simplification"
to standards.md with WRONG/RIGHT examples. The rule pushes for elegant
code; DRY/dead-code/removal findings stay declarative even at low severity.

REFRAME-AS-QUESTION in critic.md tightened: only fires when the critic
can articulate a plausible world-state where the finding wouldn't apply
(that articulation IS the Q). Removal findings excluded entirely.

Tested via prompt-build smoke; standards section reachable from
specialist common-header. Used by Task 4 to validate via replay.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Replay 3 PRs against NEW-design prompts on wakeup

**Files:**
- Create: `replays/comparison/cncorp-plow-569/new/`
- Create: `replays/comparison/cncorp-plow-563/new/`
- Create: `replays/comparison/cncorp-plow-565/new/`

Use wakeup's codex (separate quota from local Mac, so we can run today). Replay each of the 3 PRs at the same R1 SHA used in earlier replays, with `--prompts` pointing at the NEW-design prompts dir.

- [ ] **Step 4.1: Sync `prompts.new-design/` to wakeup**

```bash
cd ~/Hacking/knightwatch-reviewer
ssh odio@wakeup 'rm -rf /tmp/prompts-new-design'
scp -q -r prompts.new-design odio@wakeup:/tmp/prompts-new-design
ssh odio@wakeup 'ls /tmp/prompts-new-design/standards.md /tmp/prompts-new-design/common-header.md /tmp/prompts-new-design/critic.md'
```

Expected: 3 file paths printed (each existing).

- [ ] **Step 4.2: Verify wakeup checkout has lib/replay.sh from PR #48**

```bash
ssh odio@wakeup '
test -f /tmp/replay-harness-test/knightwatch-reviewer/lib/replay.sh && \
    head -1 /tmp/replay-harness-test/knightwatch-reviewer/lib/replay.sh
'
```

Expected: `#!/usr/bin/env bash` (env-bash shebang per PR #48). If the file is missing, run `git pull` in `/tmp/replay-harness-test/knightwatch-reviewer` first.

- [ ] **Step 4.3: Launch 3 parallel replays on wakeup**

```bash
ssh odio@wakeup '
cd /tmp/replay-harness-test/knightwatch-reviewer
git pull -q --ff-only origin feat/replay-harness 2>&1 | tail -1
export PATH=/home/odio/.npm-global/bin:$PATH
mkdir -p replays

# #569 R1
nohup bash lib/replay.sh \
    --repo cncorp/plow --pr 569 --sha dcb80a5a3dc1752799cd7498c06fdaf907adff0d \
    --prompts /tmp/prompts-new-design \
    --output-dir replays/cncorp-plow-569-new-design \
    > /tmp/replay-569-new-design.stdout 2>&1 &
echo $! > /tmp/replay-569-new-design.pid

# #563 R1
nohup bash lib/replay.sh \
    --repo cncorp/plow --pr 563 --sha 48419b4b1a2ce3a375b84570c38e8da9729b9611 \
    --prompts /tmp/prompts-new-design \
    --output-dir replays/cncorp-plow-563-new-design \
    > /tmp/replay-563-new-design.stdout 2>&1 &
echo $! > /tmp/replay-563-new-design.pid

# #565 R1
nohup bash lib/replay.sh \
    --repo cncorp/plow --pr 565 --sha 852beef00a4ca8ec6d95e131b4ff10720614c0ea \
    --prompts /tmp/prompts-new-design \
    --output-dir replays/cncorp-plow-565-new-design \
    > /tmp/replay-565-new-design.stdout 2>&1 &
echo $! > /tmp/replay-565-new-design.pid

echo "  pids: $(cat /tmp/replay-569-new-design.pid) $(cat /tmp/replay-563-new-design.pid) $(cat /tmp/replay-565-new-design.pid)"
echo "  started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
'
```

- [ ] **Step 4.4: Block until all 3 complete (run in background; ~10–15 min)**

```bash
ssh odio@wakeup '
P569=$(cat /tmp/replay-569-new-design.pid)
P563=$(cat /tmp/replay-563-new-design.pid)
P565=$(cat /tmp/replay-565-new-design.pid)
until ! kill -0 "$P569" 2>/dev/null && ! kill -0 "$P563" 2>/dev/null && ! kill -0 "$P565" 2>/dev/null; do
    sleep 30
done
echo "ALL DONE at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
for pr in 569 563 565; do
    echo "--- #$pr final run.log tail ---"
    tail -3 /tmp/replay-harness-test/knightwatch-reviewer/replays/cncorp-plow-$pr-new-design/run.log 2>/dev/null
done
' &
# Foreground status check after each minute won't work via the Bash tool block;
# use run_in_background: true on the SSH wait command and respond to the
# notification when the wait command completes.
```

(Operator note: the wait command is the natural fit for Bash's `run_in_background: true` so the agent can do other work while replays run. Notification on completion.)

- [ ] **Step 4.5: Pull replay artifacts back into the comparison structure**

```bash
cd ~/Hacking/knightwatch-reviewer
for pr in 569 563 565; do
    scp -q -r odio@wakeup:/tmp/replay-harness-test/knightwatch-reviewer/replays/cncorp-plow-$pr-new-design replays/comparison/cncorp-plow-$pr/new
done
ls replays/comparison/cncorp-plow-569/new/agents/aggregator/output.md 2>/dev/null && echo "OK: #569 aggregator output present"
ls replays/comparison/cncorp-plow-563/new/agents/aggregator/output.md 2>/dev/null && echo "OK: #563 aggregator output present"
ls replays/comparison/cncorp-plow-565/new/agents/aggregator/output.md 2>/dev/null && echo "OK: #565 aggregator output present"
```

Expected: 3 `OK:` lines.

- [ ] **Step 4.6: Commit the new-infra replay artifacts**

```bash
git add replays/comparison/
git commit -m "$(cat <<'EOF'
data(comparison): new-design replays — 3 PRs against patched prompts

Replayed cncorp/plow#563/#565/#569 R1 SHAs against prompts.new-design/
on wakeup (separate codex quota). PROMPTS_DIR override + replay.sh
from PR #48. ~$6 codex.

Each replay's full agents/ dir is preserved so per-specialist quality
analysis (Task 5) can reference what each angle saw.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build the comparison artifact (`docs/comparison-2026-05-02.md`)

**Files:**
- Create: `docs/comparison-2026-05-02.md`

The artifact is one markdown file per PR comparing all three infrastructures (OLD / CURRENT / NEW) plus a top-level summary across the 3 PRs. Per-PR comparison includes:

1. **Aggregator output side-by-side** (truncated where useful, but nothing material elided)
2. **Severity histogram** (count of blocking/medium/low/nit) per infrastructure
3. **Verdict** (APPROVE / APPROVE—pending / COMMENT) per infrastructure
4. **Bot's actual May-1 findings (OLD)** — list each, mark which were caught by CURRENT and NEW (✓/✗)
5. **New findings unique to CURRENT or NEW** that OLD missed (often signals legitimate new specialist behavior)
6. **Per-specialist signal**: did the simplification specialist self-downgrade via Broken-Glass Test (Bug 2 still present)? Did the questions in Open Questions / Findings follow Q-field shape (Bug 1 still present)? List instances.
7. **Quality notes**: 1–3 sentences of plain-English summary per infrastructure

The per-PR template (use as the structure for each of the 3 PR sections):

```markdown
## cncorp/plow#<N> R1 — three-way comparison

**Diff scope:** SHA `<sha>` (review window: <date>)

### Bot's actual May-1 findings (OLD-infra ground truth)

- [<sev>] <one-line summary> — <author response: fixed in commit <sha> | not addressed | etc.>
- ...

### Severity histograms

| Infra | blocking | medium | low | nit | verdict |
|---|---:|---:|---:|---:|---|
| OLD (May-1 prod) | … | … | … | … | … |
| CURRENT (post-#45 HEAD) | … | … | … | … | … |
| NEW (Bug 1+2 fix) | … | … | … | … | … |

### OLD findings caught/missed per infra

| OLD finding | CURRENT | NEW |
|---|:-:|:-:|
| … | ✓ / ✗ / ~ (downgraded) | ✓ / ✗ / ~ |

### Bug-1 instances (solution-shaped Qs detected)

| Infra | count | example |
|---|---:|---|
| CURRENT | … | "<verbatim Q from Open Questions>" |
| NEW | … | "<verbatim or 'none'>" |

### Bug-2 instances (Broken-Glass cited to decline simplification)

| Infra | count | example |
|---|---:|---|
| CURRENT | … | "<verbatim quote from specialist output>" |
| NEW | … | "<verbatim or 'none'>" |

### Quality notes

- **OLD:** … (one sentence on review quality)
- **CURRENT:** …
- **NEW:** …

### Aggregator outputs

<details><summary>OLD posted review</summary>

```
<paste from replays/comparison/cncorp-plow-<N>/old/posted-review.md>
```

</details>

<details><summary>CURRENT replay output</summary>

```
<paste from replays/comparison/cncorp-plow-<N>/current/aggregator-output.md>
```

</details>

<details><summary>NEW-design replay output</summary>

```
<paste from replays/comparison/cncorp-plow-<N>/new/agents/aggregator/output.md>
```

</details>
```

- [ ] **Step 5.1: For each PR, extract its specific data into the per-PR section**

For each PR, the data we need is in:
- `replays/comparison/cncorp-plow-<N>/old/run-dir/agents/<each>/output.md` + `.../old/posted-review.md`
- `replays/comparison/cncorp-plow-<N>/current/aggregator-output.md` + `.../current/agents/<each>/output.md`
- `replays/comparison/cncorp-plow-<N>/new/agents/aggregator/output.md` + `.../new/agents/<each>/output.md`

For each PR, do the following analysis steps inline (no automation; this is single-pass empirical comparison):

1. **Severity histogram**: count `[blocking]`, `[medium]`, `[low]`, `[nit]` instances in each aggregator output. Exclude header notes / scope lines.
2. **Bug 1 detection (solution-shaped Qs)**: search Open Questions sections for Qs starting with "Can…", "Should…", "Will we…" — those are solution-shaped. State-shaped Qs start with "Will [external fact]…", "Do users…", "Does the data…", etc.
3. **Bug 2 detection (BG inversion)**: grep specialist outputs for `Broken-Glass Test` cited as a reason to decline a simplification finding. Pattern: "Broken-Glass Test: this is …, not …" used in a way that downgrades or drops a DRY/dead-code/duplicate-removal finding.
4. **OLD-finding catch matrix**: for each finding the OLD posted review raised, manually scan CURRENT and NEW aggregator outputs for whether the same issue appears (✓), is missing (✗), or is present at different severity (~).

- [ ] **Step 5.2: Write the top-level summary section**

After the 3 per-PR sections, add a top-level summary section:

```markdown
## Cross-PR summary

### Finding-density (OLD findings caught)

| Infra | #569 (4 findings) | #563 (3 findings) | #565 (1 finding) | total caught | rate |
|---|---:|---:|---:|---:|---:|
| CURRENT | … | … | … | … / 8 | …% |
| NEW | … | … | … | … / 8 | …% |

### Bug-prevalence by infrastructure

| Bug | CURRENT (3 PRs) | NEW (3 PRs) | Δ |
|---|---:|---:|---:|
| Bug 1 (solution-shaped Q) | … | … | … |
| Bug 2 (BG inversion in specialist) | … | … | … |

### Headline finding

(One paragraph: did NEW improve over CURRENT? on which axis specifically?
Was the improvement bigger or smaller than expected? Are there
counter-examples — places where NEW regressed?)

### Recommendation

(One paragraph: based on the data, is the full probes-as-unit refactor
justified? Would a smaller patch — e.g. just merging the standards.md
edits from prompts.new-design — already get most of the value? Or did
the experiment NOT validate the diagnosis, and we need to look elsewhere?)
```

- [ ] **Step 5.3: Save and commit the artifact**

```bash
git add docs/comparison-2026-05-02.md
git commit -m "$(cat <<'EOF'
docs: three-way review-quality comparison (old / current / new-design)

Empirically tests whether patching the two diagnosed prompt-quality bugs
(Bug 1 solution-shaped Qs, Bug 2 Broken-Glass inversion) recovers
finding-density and severity calibration on cncorp/plow#563/#565/#569 R1.

Each PR section: severity histograms, OLD-findings catch matrix, Bug 1
+ Bug 2 prevalence per infra, full aggregator outputs collapsed under
<details>. Cross-PR summary names whether the experiment validates
proceeding with the full feat/probes-as-unit refactor or motivates a
smaller patch landing the standards.md edits alone.

Per `feedback_validation_style.md`: this is the empirical scaffold,
not a speculative prompt-fix list.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Push branch + open PR for review

**Files:**
- (no new files; PR description references the artifact)

- [ ] **Step 6.1: Push the branch**

```bash
cd ~/Hacking/knightwatch-reviewer
git push -u origin feat/probes-as-unit
```

- [ ] **Step 6.2: Open the PR**

```bash
gh pr create --title "docs: three-way review-quality comparison (old / current / new-design)" --body "$(cat <<'EOF'
## Summary

Empirical test of the prompt-regression diagnosis: replays cncorp/plow#563/#565/#569 R1 against three prompt-set states (May-1 production, post-#45 HEAD, NEW-design with Bug 1+2 fixes) and compares the resulting reviews specialist-by-specialist.

The artifact at \`docs/comparison-2026-05-02.md\` is the deliverable; it answers whether the prompt-quality bugs we diagnosed (solution-shaped Qs + Broken-Glass inversion) account for the regression, and whether the full feat/probes-as-unit refactor is justified.

\`prompts.new-design/\` contains the surgical patch (3 files: standards.md, common-header.md, critic.md) used in the test. Production prompts/ untouched.

## Test plan

- [x] OLD baseline: copied 3 production R1 run-dirs from wakeup
- [x] CURRENT baseline: 3 post-#45 HEAD-prompt replays (already on disk)
- [x] NEW-design replays: 3 fresh runs against patched prompts (~\$6 codex on wakeup)
- [x] Per-specialist signal analysis: Bug 1 + Bug 2 prevalence counted per infra
- [x] Cross-PR summary: finding-density catch rate per infra

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

The PR shouldn't auto-merge; the artifact is the deliverable. Per `feedback_pr_cadence.md`: open PR, continue.

---

## Self-review checklist (run before handoff)

- [ ] All file paths are absolute or unambiguous from `~/Hacking/knightwatch-reviewer`.
- [ ] No `git checkout`, `git restore`, `git stash`, `git reset`, `git clean` operations called without explicit user authorization (per `~/.claude/CLAUDE.md` global rule).
- [ ] All Tasks 1–4 are deterministic (no LLM calls until Task 4); only Task 4 spends codex.
- [ ] Task 4's wait step uses `run_in_background: true` per the operator-note inside Step 4.4.
- [ ] Task 5's per-PR section template specifies WHAT to count (severity, Bug 1 instances, Bug 2 instances) so the analysis is reproducible.
- [ ] No specialist file edits in this plan — keeps blast radius small for the experiment. Full probes-as-unit specialist migration is the user's separate plan.
- [ ] Token consistency: `prompts.new-design/`, `replays/comparison/`, `docs/comparison-2026-05-02.md` are spelled identically across all tasks.
