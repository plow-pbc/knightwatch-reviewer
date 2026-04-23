# Multi-Specialist PR Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the `~/.pr-reviewer` cron-driven PR reviewer from a single codex pass over the diff-on-stdin to a fan-out / fan-in architecture: four specialist passes (security, data-integrity, architecture-&-strategy, tests) each with repo-read access and per-repo product context, followed by an aggregator pass that merges findings into a single posted review.

**Architecture:** `review.sh` stays the orchestrator. Per run, it writes the diff + previous-review context to a per-PR scratch directory inside the repo workdir, then launches four specialist `codex exec` calls in parallel (each with `-C $REPO_DIR --sandbox read-only -o <output_file>`). When all four complete, a fifth aggregator `codex exec` reads the specialist outputs and produces the final review body + VERDICT line that gets posted via `gh pr comment`. Per-repo `PRODUCT_CONTEXT.md` files supply roadmap/distribution context the diff can't convey.

**Tech Stack:** Bash 5, `codex exec` CLI (OpenAI Codex), `gh` CLI, `jq`, existing knightwatch-kid `kid_dry_check.py`.

---

## File Structure

**Create:**
- `~/.pr-reviewer/prompts/common-header.md` — shared preamble injected into every specialist prompt (PR metadata, standards, test results, prior art, file paths the specialist should read).
- `~/.pr-reviewer/prompts/security.md` — security specialist angle.
- `~/.pr-reviewer/prompts/data-integrity.md` — concurrency, data integrity, correctness specialist.
- `~/.pr-reviewer/prompts/architecture.md` — architecture & strategy specialist (reads `PRODUCT_CONTEXT.md`).
- `~/.pr-reviewer/prompts/tests.md` — test-coverage specialist.
- `~/.pr-reviewer/prompts/aggregator.md` — merges specialist outputs into final review + VERDICT.
- `~/.pr-reviewer/contexts/cncorp_plow.md` — plow product context (stage, distribution, roadmap).
- `~/.pr-reviewer/contexts/srosro_tkmx-client.md` — tkmx-client context.
- `~/.pr-reviewer/contexts/srosro_tkmx-server.md` — tkmx-server context.
- `~/.pr-reviewer/lib/run-specialist.sh` — helper that runs a single specialist and extracts its output.

**Modify:**
- `~/.pr-reviewer/review.sh` — swap stdin-pipe for file-based diff, add fan-out + aggregator, drop legacy single-pass path.

**No tests created.** This is a bash orchestrator that shells out to `codex exec` and `gh`. Unit-testing it in isolation is not valuable. Each task below includes a concrete smoke test against a real PR that exercises the change end-to-end.

---

## Task 0: Pre-flight — verify codex exec reads repo files

**Purpose:** The entire plan assumes `codex exec -C <repo> --sandbox read-only` can grep/read the repo around the diff. Verify before investing.

**Files:** none created; scratch commands only.

- [ ] **Step 1: Pick a known small repo for the probe**

Use the existing clone at `~/.pr-reviewer/repos/cncorp_plow`. If absent, clone it:

```bash
ls ~/.pr-reviewer/repos/cncorp_plow/.git >/dev/null 2>&1 || \
  gh repo clone cncorp/plow ~/.pr-reviewer/repos/cncorp_plow -- --depth=5
```

Expected: no output (already cloned) or clone progress.

- [ ] **Step 2: Run a probe that requires reading a file**

```bash
codex exec \
  -C ~/.pr-reviewer/repos/cncorp_plow \
  --sandbox read-only \
  -o /tmp/codex-probe.out \
  "List the top 3 directories under the repo root and name one Python file under the largest one. Cite exact paths."
cat /tmp/codex-probe.out
```

Expected: non-empty output naming real paths that exist in the repo (e.g. `backend/`, `frontend/`, a specific `.py` path).

- [ ] **Step 3: Verify the probe actually read files**

```bash
ls ~/.pr-reviewer/repos/cncorp_plow | head -5
```

Then compare the codex output against this directory listing. Expected: codex's named directories appear in `ls` output.

- [ ] **Step 4: Decision gate**

If the probe succeeds → proceed to Task 1.
If the probe fails (empty output, hallucinated paths, or sandbox denial) → **stop the plan**. The architecture depends on this capability. Adjust: investigate `--sandbox workspace-write`, `-c sandbox_permissions=["disk-full-read-access"]`, or fall back to baking more context into the prompt itself.

---

## Task 1: Per-repo PRODUCT_CONTEXT files

**Purpose:** Give the architecture specialist the product-stage and roadmap awareness that turns "this works" into "this forecloses X."

**Files:**
- Create: `~/.pr-reviewer/contexts/cncorp_plow.md`
- Create: `~/.pr-reviewer/contexts/srosro_tkmx-client.md`
- Create: `~/.pr-reviewer/contexts/srosro_tkmx-server.md`

- [ ] **Step 1: Create the contexts directory**

```bash
mkdir -p ~/.pr-reviewer/contexts
```

Expected: no output.

- [ ] **Step 2: Write the plow product context**

Write `~/.pr-reviewer/contexts/cncorp_plow.md` with:

```markdown
# Plow — Product Context

**Stage:** ~10 active users. Moving quickly. Design bias: simple, will-scale, not-overly-complex.

**Distribution model:** Currently single-tenant (cncorp only). Near-term goal: Slack Marketplace distribution with customers connecting their own Slack workspaces (per-tenant xoxp- tokens).

**Architectural commitments worth flagging when a PR breaks them:**
- Prefer multi-tenant-friendly designs over single-tenant shortcuts.
- Avoid changes that foreclose Slack Marketplace (e.g. app-level tokens with global concurrency caps, Socket Mode that requires a single long-lived connection per app).
- Per-tenant credentials, signing verification, per-workspace rate limiting are coming — leave seams.

**Known near-term migrations / roadmap items:**
- Slack Socket Mode → HTTP Events API (public endpoint + request signing, per-tenant xoxp- tokens).
- Billing / usage metering per tenant.
- Admin surface for tenant provisioning.

**Review posture:** The architecture specialist is *allowed and encouraged* to file non-blocking "open an issue before X" findings when a design decision is fine today but will bite at a known upcoming transition.

**Update cadence:** Review and edit this file quarterly, or when a major roadmap item ships or shifts.
```

- [ ] **Step 3: Write the tkmx-client product context**

Write `~/.pr-reviewer/contexts/srosro_tkmx-client.md` with:

```markdown
# tkmx-client — Product Context

**Stage:** Internal tool. Small user base. Bias: simplicity over completeness.

**Distribution model:** Internal only; no external customer deployments.

**Architectural commitments:**
- Keep the reporter cron (`reporter/report.js`) self-contained and restartable; it runs unattended every 2 hours.
- Fail-fast on config or credential errors — do not silently skip reporting cycles.

**Known near-term migrations / roadmap items:**
- None tracked here yet. Update when roadmap items emerge.

**Review posture:** Architecture specialist should flag anything that adds external-facing surface area (this is an internal tool — treat new public endpoints, new auth surfaces, or new third-party integrations as notable).

**Update cadence:** Quarterly or on major direction change.
```

- [ ] **Step 4: Write the tkmx-server product context**

Write `~/.pr-reviewer/contexts/srosro_tkmx-server.md` with:

```markdown
# tkmx-server — Product Context

**Stage:** Small-scale internal server. Fewer than a dozen active users.

**Distribution model:** Internal only.

**Architectural commitments:**
- Stateless request handlers where possible; persistent state lives in the database.
- Alembic migrations are always autogenerated (`alembic revision --autogenerate`), never hand-written.

**Known near-term migrations / roadmap items:**
- None tracked here yet. Update when roadmap items emerge.

**Review posture:** Architecture specialist should flag schema changes that require a backfill or a multi-step deploy, and any change that introduces a new external dependency.

**Update cadence:** Quarterly or on major direction change.
```

- [ ] **Step 5: Verify all three files exist and are non-empty**

```bash
ls -la ~/.pr-reviewer/contexts/
wc -l ~/.pr-reviewer/contexts/*.md
```

Expected: three files listed, each with ≥15 lines.

- [ ] **Step 6: Commit**

```bash
cd ~/.pr-reviewer && git init -q 2>/dev/null
cd ~/.pr-reviewer && git add contexts/ && git commit -q -m "Add per-repo PRODUCT_CONTEXT files" || echo "not a git repo — skipping commit"
```

(If `~/.pr-reviewer` is not under version control, that's fine; skip the commit step silently. Report that to the user at the end of the task.)

---

## Task 2: Specialist and aggregator prompts

**Purpose:** Four narrow-angle specialist prompts + one aggregator prompt. Each specialist outputs findings in a canonical shape so the aggregator can parse loosely.

**Files:**
- Create: `~/.pr-reviewer/prompts/common-header.md`
- Create: `~/.pr-reviewer/prompts/security.md`
- Create: `~/.pr-reviewer/prompts/data-integrity.md`
- Create: `~/.pr-reviewer/prompts/architecture.md`
- Create: `~/.pr-reviewer/prompts/tests.md`
- Create: `~/.pr-reviewer/prompts/aggregator.md`

- [ ] **Step 1: Create the prompts directory**

```bash
mkdir -p ~/.pr-reviewer/prompts
```

- [ ] **Step 2: Write common-header.md (shared preamble)**

Write `~/.pr-reviewer/prompts/common-header.md`:

```markdown
You are one specialist in a multi-specialist code review of a GitHub PR.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**URL:** {{PR_URL}}

**Working directory:** You are running inside a fresh checkout of the PR branch. You may read any file in the repository. You may run read-only commands (grep, cat, find, git log, git show) to investigate beyond the diff.

**Inputs already prepared for you:**
- `.codex-scratch/diff.patch` — the diff you are reviewing. For first-time reviews this is the full PR diff. For re-reviews this is the *incremental* diff since your prior review.
- `.codex-scratch/previous-review.md` — your prior review, if this is a re-review. Empty file on first review.
- `.codex-scratch/test-results.md` — output summary from `just test` on this PR branch. Always present.
- `.codex-scratch/prior-art.md` — knightwatch-kid dry-check prior-art surface, if applicable. May be empty.
- `.codex-scratch/standards.md` — coding/testing standards and known review mistakes to avoid.
- `.codex-scratch/product-context.md` — product stage, distribution model, roadmap. READ THIS before judging architectural tradeoffs.

**Rules for your output:**
1. Read `.codex-scratch/diff.patch` first. Then read surrounding code in the repo to understand context — call sites, definitions, invariants.
2. Focus ONLY on your specialist angle (specified below). Do not duplicate other angles.
3. Output findings in this exact format:

```
## [{{SPECIALIST_NAME}}] findings

### Finding 1 — <severity>
<one paragraph — what is wrong, why it matters, where>
Files: path/to/file.ext:LINE (and additional citations as needed)

### Finding 2 — <severity>
...
```

4. Severity is exactly one of: `blocking`, `medium`, `low`, `nit`. Use `blocking` ONLY for issues that must be fixed before merge.
5. If you find nothing in your angle, output exactly this and nothing else:

```
## [{{SPECIALIST_NAME}}] findings

No findings.
```

6. Be specific. Cite file paths and line numbers. Quote the problematic code in ≤2 lines when it clarifies.
7. Keep each finding under 120 words. No preamble, no summary, no verdict. The aggregator will assemble the final review.
```

- [ ] **Step 3: Write security.md**

Write `~/.pr-reviewer/prompts/security.md`:

```markdown
**Your angle: Security.**

Scope:
- Secret handling (API keys, tokens, credentials) — logged, serialized, stored, returned in responses, committed.
- PII exposure and data minimization.
- AuthN / AuthZ — missing auth checks, broken access control, IDOR, privilege escalation paths.
- Input validation at trust boundaries — SQL injection, command injection, XSS, SSRF, path traversal, prototype pollution.
- Session / token lifecycle — expiry, revocation, rotation.
- Dependency risk — new deps, pinned versions, known-vulnerable versions.
- Cryptographic misuse — weak algorithms, custom crypto, hardcoded IVs/keys.
- CSRF, CORS, origin checks on new HTTP routes.

Out of scope (leave to other specialists): correctness bugs unrelated to security, performance, test coverage, architecture fit.

If the diff touches auth, sessions, credential handling, or any HTTP surface area, investigate the call-site context beyond the diff — grep for how the touched function is invoked across the repo.
```

- [ ] **Step 4: Write data-integrity.md**

Write `~/.pr-reviewer/prompts/data-integrity.md`:

```markdown
**Your angle: Data integrity, concurrency, and correctness.**

Scope:
- Race conditions: shared state, missing locks, TOCTOU, non-atomic read-modify-write.
- Database: transaction boundaries, isolation anomalies, missing `SELECT FOR UPDATE`, N+1 queries that become correctness issues (not just perf).
- Error handling at boundaries — swallowed exceptions, half-applied writes, missing rollback on failure.
- Idempotency of retried operations (webhooks, cron tasks, message consumers).
- Migration safety — backfill order, NOT NULL on existing tables, index creation on large tables.
- State machines — unreachable states, illegal transitions, missing guards.
- Off-by-one, pagination boundaries, timezone handling, floating-point comparisons on money.

Out of scope: security-only issues, style, test coverage, product-fit concerns.

Look beyond the diff: grep for other call sites of touched functions to see if the new behavior is consistent with existing invariants.
```

- [ ] **Step 5: Write architecture.md**

Write `~/.pr-reviewer/prompts/architecture.md`:

```markdown
**Your angle: Architecture and product strategy.**

FIRST, read `.codex-scratch/product-context.md` in full. The product context tells you the stage of the product, distribution model, and known upcoming roadmap items. Ground your findings in that context.

Scope:
- Design tradeoffs: did the PR pick an approach that closes off a known roadmap item? (e.g. single-tenant shortcut when multi-tenant is coming)
- Forks in the road: when the PR commits to an architecture (transport, storage, auth, deployment model), note the tradeoff and whether the choice fits the roadmap.
- Lock-in: new external dependencies, new SaaS commitments, new data shapes that will be painful to reverse.
- Layering: violations of existing boundaries (e.g. a handler reaching into a repo layer that was previously isolated).
- Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do.
- Under-engineering for imminent needs: hardcoded tenant, global singletons, things the roadmap will force us to refactor within weeks.

**You are explicitly allowed to file non-blocking findings of the form: "this is fine to ship today, but file an issue to migrate before X happens."** That is often the most valuable finding this specialist produces — mark those as `low` or `medium`, not `blocking`.

Out of scope: specific security bugs, concurrency bugs, test coverage.

Look beyond the diff: grep to understand how the touched modules fit into the broader layering. Read the top-level module structure before making layering claims.
```

- [ ] **Step 6: Write tests.md**

Write `~/.pr-reviewer/prompts/tests.md`:

```markdown
**Your angle: Test coverage and test quality.**

FIRST, read `.codex-scratch/test-results.md` in full. It contains the outcome and tail of `just test` run against this PR branch.

Scope:
- Test coverage of new behavior: is every new branch / error path / state transition exercised?
- Missing tests for regressions or bug fixes: a bug fix without a regression test is a `blocking` finding.
- Test quality: mocks where integration would catch more, tests that assert implementation details instead of behavior, tests that cannot fail.
- If `just test` failed: classify each failure as *PR-related* or *pre-existing-on-main*. PR-related failures are `blocking`.
- Test data: fragile hardcoded IDs, inline payloads that should be fixtures, duplicated setup.
- Flakiness risks: time.sleep, real network calls, unseeded randomness.

Out of scope: the underlying code correctness (data-integrity specialist handles that), security, architecture. Stay on tests.

Look beyond the diff: grep `tests/` for existing patterns the PR should have followed.
```

- [ ] **Step 7: Write aggregator.md**

Write `~/.pr-reviewer/prompts/aggregator.md`:

```markdown
You are the aggregator in a multi-specialist PR review. Four specialists have each produced findings on a narrow angle. Your job: merge, dedupe, rank, and produce ONE posted review.

**Inputs:**
- `.codex-scratch/specialists/security.md`
- `.codex-scratch/specialists/data-integrity.md`
- `.codex-scratch/specialists/architecture.md`
- `.codex-scratch/specialists/tests.md`
- `.codex-scratch/diff.patch` — the diff under review (for sanity-checking)
- `.codex-scratch/previous-review.md` — your team's prior review, if re-review
- `.codex-scratch/test-results.md` — `just test` outcome
- `.codex-scratch/standards.md` — the standards the review is measured against
- `.codex-scratch/product-context.md` — product stage and roadmap

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**URL:** {{PR_URL}}

**Your job:**
1. Read all four specialist files.
2. Dedupe overlapping findings. If two specialists raised effectively the same issue, keep the more specific framing.
3. Rank by severity (blocking → medium → low → nit). Within a severity band, most-important first.
4. Drop findings that are weak, duplicative, or that a reader would score as "not worth mentioning." Quality over volume. It is correct to drop nits if there are ≥3 stronger findings — a short review is better than a padded one.
5. If a specialist wrote "No findings." then that section contributes nothing.
6. Produce the final posted review in EXACTLY this structure, under 500 words total:

```
**Overview** — 2-3 sentences on what the PR does.

**Strengths** — non-obvious things done right so the author repeats them. Omit this section if none.

**Findings**
1. [blocking|medium|low|nit] <one paragraph, cite Files: path:line, cite the standard violated where applicable (Fail-Fast, Tests, Concise Code, DRY, Narrow-Fix, Spec-Reframe, Migrations)>
2. ...

**Security** — one sentence summary of the security specialist's take, or "None" if clean.

**Test coverage** — summary of the tests specialist's take plus the `just test` outcome. If tests failed, call it out.
```

7. On the VERY LAST LINE of your output, put exactly one of:
   - `VERDICT: APPROVE` — no findings, or findings are low/nit only.
   - `VERDICT: APPROVE — pending: <short comma-separated nit/low items>` — approvable but worth noting.
   - `VERDICT: COMMENT` — one or more `blocking` findings must be addressed before merge.

No other content after the VERDICT line.
```

- [ ] **Step 8: Verify all prompt files exist and are non-empty**

```bash
ls -la ~/.pr-reviewer/prompts/
wc -l ~/.pr-reviewer/prompts/*.md
```

Expected: six files, each ≥20 lines.

- [ ] **Step 9: Commit (if repo)**

```bash
cd ~/.pr-reviewer && git add prompts/ && git commit -q -m "Add specialist and aggregator prompts" || echo "not a git repo — skipping"
```

---

## Task 3: Helper — run-specialist.sh

**Purpose:** A small helper that wraps `codex exec` with the right flags, captures output to a file, logs, and returns the exit code. `review.sh` calls it for each specialist plus the aggregator.

**Files:**
- Create: `~/.pr-reviewer/lib/run-specialist.sh`

- [ ] **Step 1: Create the lib directory**

```bash
mkdir -p ~/.pr-reviewer/lib
```

- [ ] **Step 2: Write run-specialist.sh**

Write `~/.pr-reviewer/lib/run-specialist.sh`:

```bash
#!/bin/bash
# Run one codex exec pass with read-only repo access.
#
# Args:
#   $1 NAME       — specialist name (for logs and output filename)
#   $2 REPO_DIR   — absolute path to the checked-out repo (cwd for codex)
#   $3 PROMPT     — the full prompt text
#   $4 OUT_FILE   — path where codex's last-message should be written
#   $5 LOG_FILE   — append-mode log file for progress + raw codex stderr
#
# Exits 0 on success, non-zero on codex failure. Fails loud.
set -e

NAME="$1"
REPO_DIR="$2"
PROMPT="$3"
OUT_FILE="$4"
LOG_FILE="$5"

if [ -z "$NAME" ] || [ -z "$REPO_DIR" ] || [ -z "$PROMPT" ] || [ -z "$OUT_FILE" ] || [ -z "$LOG_FILE" ]; then
    echo "run-specialist.sh: missing args (got NAME='$NAME' REPO_DIR='$REPO_DIR' OUT_FILE='$OUT_FILE' LOG_FILE='$LOG_FILE')" >&2
    exit 2
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "run-specialist.sh: $REPO_DIR is not a git repo" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT_FILE")"

echo "[$(date '+%H:%M:%S')] specialist=$NAME starting" >> "$LOG_FILE"

# --sandbox read-only: no writes from the model.
# -C: set working directory for the agent (can still read anywhere in the repo).
# -o: write final message to file; avoids fragile stdout parsing.
codex exec \
    -C "$REPO_DIR" \
    --sandbox read-only \
    -o "$OUT_FILE" \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1
CODEX_EXIT=$?

echo "[$(date '+%H:%M:%S')] specialist=$NAME exit=$CODEX_EXIT" >> "$LOG_FILE"

if [ "$CODEX_EXIT" -ne 0 ]; then
    exit "$CODEX_EXIT"
fi

if [ ! -s "$OUT_FILE" ]; then
    echo "[$(date '+%H:%M:%S')] specialist=$NAME produced empty output" >> "$LOG_FILE"
    exit 3
fi

exit 0
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x ~/.pr-reviewer/lib/run-specialist.sh
```

- [ ] **Step 4: Smoke test the helper on a trivial prompt**

```bash
~/.pr-reviewer/lib/run-specialist.sh \
    probe \
    ~/.pr-reviewer/repos/cncorp_plow \
    "In one sentence: name the top-level directory layout of this repo." \
    /tmp/specialist-probe.out \
    /tmp/specialist-probe.log
cat /tmp/specialist-probe.out
tail -5 /tmp/specialist-probe.log
```

Expected: `specialist-probe.out` is a single sentence naming real directories. The log ends with `exit=0`.

- [ ] **Step 5: Commit**

```bash
cd ~/.pr-reviewer && git add lib/ && git commit -q -m "Add run-specialist helper" || echo "not a git repo — skipping"
```

---

## Task 4: Refactor review.sh — file-based diff delivery (single pass still)

**Purpose:** Swap the stdin-pipe of the diff for a scratch file inside the repo, so the single codex pass gains the repo-read capability. Keep it single-pass for this task — fan-out comes in Task 5. This is a safe intermediate: we prove file-based delivery works before touching the parallel architecture.

**Files:**
- Modify: `~/.pr-reviewer/review.sh` lines 178–225 (the DIFF assembly + INSTRUCTIONS + codex invocation).

- [ ] **Step 1: Add a scratch-dir helper near the top of review.sh**

In `~/.pr-reviewer/review.sh`, after the existing `state_set` function (around line 34), add:

```bash
# Per-PR scratch directory inside the repo workdir. Codex runs with
# --sandbox read-only -C $REPO_DIR, so scratch must live under $REPO_DIR
# to be readable by the model. We clean it up on exit.
write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$scratch_dir/specialists"
    printf '%s' "$content" > "$scratch_dir/$filename"
}

cleanup_scratch() {
    local repo_dir="$1"
    rm -rf "$repo_dir/.codex-scratch"
}
```

- [ ] **Step 2: Replace the INSTRUCTIONS assembly and codex call**

In `review.sh`, find the block starting at `INSTRUCTIONS="You are an expert code reviewer..."` (around line 187) through `RAW=$(cd "$REPO_DIR" && printf '%s' "$DIFF" | codex exec "$INSTRUCTIONS" 2>&1)` (around line 225). Replace that entire block with:

```bash
        # Write all specialist inputs to the repo's scratch dir
        write_scratch "$REPO_DIR" "diff.patch"             "$KID_INPUT_DIFF"
        write_scratch "$REPO_DIR" "previous-review.md"     "${PREV_BODY:-}"
        write_scratch "$REPO_DIR" "test-results.md"        "$TEST_RESULTS"
        write_scratch "$REPO_DIR" "prior-art.md"           "${PRIOR_ART:-}"
        write_scratch "$REPO_DIR" "standards.md"           "$STANDARDS"

        CONTEXT_FILE="$HOME/.pr-reviewer/contexts/$(echo "$REPO" | tr '/' '_').md"
        if [ -f "$CONTEXT_FILE" ]; then
            write_scratch "$REPO_DIR" "product-context.md" "$(cat "$CONTEXT_FILE")"
        else
            write_scratch "$REPO_DIR" "product-context.md" "(no product context configured for $REPO)"
        fi

        # For this task we still run a single review pass — fan-out comes next.
        # The prompt below is temporary; Task 5 replaces it with specialist invocations.
        SINGLE_PASS_PROMPT="You are an expert code reviewer. Keep your review under 500 words.

PR: $PR_ID
Title: $PR_TITLE
URL: https://github.com/$REPO/pull/$PR_NUM

$REVIEW_TASK

Inputs prepared for you in the repo at \`.codex-scratch/\`:
- diff.patch — the diff to review
- previous-review.md — your prior review (empty if first review)
- test-results.md — \`just test\` outcome
- prior-art.md — knightwatch-kid prior-art dry-check (may be empty)
- standards.md — coding/testing standards
- product-context.md — product stage and roadmap

Read diff.patch first. Then read surrounding code in the repo to understand context — call sites, definitions, invariants.

Produce a structured review:

**Overview** — what the PR does, 2-3 sentences.

**Strengths** — non-obvious things done right. Omit if none.

**Findings** — numbered, each tagged: blocking / medium / low / nit. Cite violated standard by name where applicable. Cover correctness, conventions, performance, test coverage.

**Security** — PII, secrets, auth, input validation. \"None\" if clean.

**Test coverage** — see test-results.md. PR-related test failures are blocking.

Under 500 words total. On the VERY LAST LINE output exactly one of:
VERDICT: APPROVE
VERDICT: APPROVE — pending: <comma-separated nit/low items>
VERDICT: COMMENT"

        SINGLE_OUT="$REPO_DIR/.codex-scratch/single-pass-output.md"
        log "Running codex review for $PR_ID..."
        codex exec \
            -C "$REPO_DIR" \
            --sandbox read-only \
            -o "$SINGLE_OUT" \
            "$SINGLE_PASS_PROMPT" \
            >> "$LOG_FILE" 2>&1
        CODEX_EXIT=$?

        if [ "$CODEX_EXIT" -ne 0 ] || [ ! -s "$SINGLE_OUT" ]; then
            log "codex exec failed (exit $CODEX_EXIT) or empty output"
            cleanup_scratch "$REPO_DIR"
            rm -f "$LOCK_FILE"
            continue
        fi

        REVIEW=$(cat "$SINGLE_OUT")
```

- [ ] **Step 3: Remove the old awk extraction block**

In the same region, the old awk block extracts `REVIEW` from `RAW`:

```
        REVIEW=$(echo "$RAW" | awk '
            /^codex$/ { capturing=1; buf=""; next }
            capturing && /^tokens used/ { capturing=0; exit }
            capturing { buf = buf $0 "\n" }
            END { printf "%s", buf }
        ')
```

Delete it. `REVIEW` is now populated directly from `$SINGLE_OUT` in Step 2.

- [ ] **Step 4: Add scratch cleanup before the final `exit 0`**

In `review.sh`, find the final lines of the per-PR loop, where after `state_set` the script does `rm -f "$LOCK_FILE"` and `exit 0`. Right before `rm -f "$LOCK_FILE"`, add:

```bash
        cleanup_scratch "$REPO_DIR"
```

Do the same at the other `rm -f "$LOCK_FILE"` sites inside the loop (the error-path continues and the test-not-available exit). Add `cleanup_scratch "$REPO_DIR"` immediately before each of those.

- [ ] **Step 5: Smoke test — dry-run on a real PR**

Pick the most recently-reviewed PR in `state.json` and force a re-review by temporarily editing its SHA:

```bash
# Inspect state
jq 'keys | .[0:3]' ~/.pr-reviewer/state.json

# Pick a PR id (replace with one from above), then force a re-review by
# clearing just that entry:
PR_ID="cncorp/plow#<number>"
jq --arg id "$PR_ID" 'del(.[$id])' ~/.pr-reviewer/state.json > /tmp/state.json.new
# Inspect the diff but do NOT overwrite yet:
diff <(jq . ~/.pr-reviewer/state.json) <(jq . /tmp/state.json.new) | head -10
```

Expected: one entry removed.

To actually run the smoke test without posting to GitHub, wrap review.sh with a guard:

```bash
# Temporarily replace `gh pr comment` and `gh pr review` with echo stubs:
cp ~/.pr-reviewer/review.sh /tmp/review.sh.bak
sed -i 's|^        gh pr comment|        echo DRYRUN gh pr comment|; s|^            gh pr review|            echo DRYRUN gh pr review|' ~/.pr-reviewer/review.sh

# Apply the state reset and run:
cp /tmp/state.json.new ~/.pr-reviewer/state.json
~/.pr-reviewer/review.sh

# Restore review.sh afterward:
cp /tmp/review.sh.bak ~/.pr-reviewer/review.sh
```

Expected: log prints `Running codex review for <PR_ID>...`, no errors, `DRYRUN gh pr comment` lines show the review body, review body is non-empty, and ends with a `VERDICT:` line.

- [ ] **Step 6: Commit**

```bash
cd ~/.pr-reviewer && git add review.sh && git commit -q -m "Switch codex input from stdin to .codex-scratch/ files" || echo "not a git repo — skipping"
```

---

## Task 5: Fan-out — parallel specialist passes

**Purpose:** Replace the single-pass call with four parallel specialist calls, each with its own prompt. Aggregator comes in Task 6.

**Files:**
- Modify: `~/.pr-reviewer/review.sh` — replace the single-pass block from Task 4 with the fan-out block.

- [ ] **Step 1: Build the per-specialist prompt with placeholder substitution**

In `review.sh`, near the top (after `log()` definition is a good spot), add a helper to render a specialist prompt:

```bash
build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5"
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
    {
        sed -e "s|{{PR_ID}}|$pr_id|g" \
            -e "s|{{PR_TITLE}}|$pr_title|g" \
            -e "s|{{PR_URL}}|$pr_url|g" \
            -e "s|{{SPECIALIST_NAME}}|$specialist_name|g" \
            "$common"
        echo ""
        cat "$specialist_file"
    }
}
```

Note: `sed` substitution of PR_TITLE is fragile if the title contains `|`. Escape it before substitution:

```bash
safe_sed() {
    # Escape | and & and \ for safe use in sed replacement
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}
```

Use it when building the prompt:

```bash
build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5"
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
    local esc_id esc_title esc_url esc_name
    esc_id=$(safe_sed "$pr_id")
    esc_title=$(safe_sed "$pr_title")
    esc_url=$(safe_sed "$pr_url")
    esc_name=$(safe_sed "$specialist_name")
    {
        sed -e "s|{{PR_ID}}|$esc_id|g" \
            -e "s|{{PR_TITLE}}|$esc_title|g" \
            -e "s|{{PR_URL}}|$esc_url|g" \
            -e "s|{{SPECIALIST_NAME}}|$esc_name|g" \
            "$common"
        echo ""
        cat "$specialist_file"
    }
}
```

- [ ] **Step 2: Replace the single-pass codex call with parallel specialist calls**

In `review.sh`, find the block from Task 4 that starts with `SINGLE_PASS_PROMPT="..."` and ends with `REVIEW=$(cat "$SINGLE_OUT")`. Replace the entire block with:

```bash
        PR_URL="https://github.com/$REPO/pull/$PR_NUM"
        SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
        mkdir -p "$SPECIALISTS_DIR"

        log "$PR_ID: launching 4 specialists in parallel..."

        for angle in security data-integrity architecture tests; do
            PROMPT=$(build_specialist_prompt \
                "$angle" \
                "$HOME/.pr-reviewer/prompts/${angle}.md" \
                "$PR_ID" "$PR_TITLE" "$PR_URL")
            ~/.pr-reviewer/lib/run-specialist.sh \
                "$angle" \
                "$REPO_DIR" \
                "$PROMPT" \
                "$SPECIALISTS_DIR/${angle}.md" \
                "$LOG_FILE" &
        done

        wait
        SPECIALIST_FAILURE=0
        for angle in security data-integrity architecture tests; do
            if [ ! -s "$SPECIALISTS_DIR/${angle}.md" ]; then
                log "$PR_ID: specialist $angle produced empty output — aborting review"
                SPECIALIST_FAILURE=1
            fi
        done

        if [ "$SPECIALIST_FAILURE" -ne 0 ]; then
            cleanup_scratch "$REPO_DIR"
            rm -f "$LOCK_FILE"
            continue
        fi

        log "$PR_ID: all 4 specialists completed"

        # Task 6 will add aggregator here. For now, concatenate specialist
        # outputs into REVIEW so the smoke test can inspect them end-to-end.
        REVIEW=""
        for angle in security data-integrity architecture tests; do
            REVIEW+="$(cat "$SPECIALISTS_DIR/${angle}.md")"$'\n\n'
        done
        REVIEW+="VERDICT: COMMENT"
```

(The final `VERDICT: COMMENT` is a placeholder until the aggregator in Task 6 decides the real verdict.)

- [ ] **Step 3: Smoke test — run against a real PR, verify 4 specialist outputs**

Force a re-review the same way as Task 4 Step 5:

```bash
PR_ID="cncorp/plow#<number>"
jq --arg id "$PR_ID" 'del(.[$id])' ~/.pr-reviewer/state.json > /tmp/state.json.new
cp /tmp/state.json.new ~/.pr-reviewer/state.json

# Stub the GitHub writes:
cp ~/.pr-reviewer/review.sh /tmp/review.sh.bak
sed -i 's|^        gh pr comment|        echo DRYRUN gh pr comment|; s|^            gh pr review|            echo DRYRUN gh pr review|' ~/.pr-reviewer/review.sh

# Run:
~/.pr-reviewer/review.sh

# Inspect specialist outputs — they should still be on disk since we removed the cleanup_scratch call at the `continue` sites but not at the success path. Look at the repo's scratch dir.
REPO_DIR=$(ls -d ~/.pr-reviewer/repos/cncorp_plow)
ls "$REPO_DIR/.codex-scratch/specialists/"
wc -l "$REPO_DIR/.codex-scratch/specialists/"*.md

# Restore:
cp /tmp/review.sh.bak ~/.pr-reviewer/review.sh
```

Expected: four files in the specialists dir, each non-empty and containing `## [<angle>] findings` as its first heading. The `DRYRUN gh pr comment` body should contain all four concatenated sections plus a trailing `VERDICT: COMMENT`.

Note: the scratch dir is cleaned up on the SUCCESS path after `state_set`. If you want to inspect it after a successful run, temporarily comment out the `cleanup_scratch` call at the success-path site before running.

- [ ] **Step 4: Commit**

```bash
cd ~/.pr-reviewer && git add review.sh && git commit -q -m "Fan out to 4 parallel specialist passes" || echo "not a git repo — skipping"
```

---

## Task 6: Aggregator pass

**Purpose:** A final `codex exec` reads the four specialist outputs and produces the single posted review body + VERDICT line.

**Files:**
- Modify: `~/.pr-reviewer/review.sh` — replace the placeholder concatenation from Task 5 with a real aggregator invocation.

- [ ] **Step 1: Replace the placeholder REVIEW assembly with an aggregator call**

In `review.sh`, find the block from Task 5:

```
        # Task 6 will add aggregator here. For now, concatenate specialist
        # outputs into REVIEW so the smoke test can inspect them end-to-end.
        REVIEW=""
        for angle in security data-integrity architecture tests; do
            REVIEW+="$(cat "$SPECIALISTS_DIR/${angle}.md")"$'\n\n'
        done
        REVIEW+="VERDICT: COMMENT"
```

Replace with:

```bash
        log "$PR_ID: running aggregator..."

        AGG_PROMPT=$(build_specialist_prompt \
            "aggregator" \
            "$HOME/.pr-reviewer/prompts/aggregator.md" \
            "$PR_ID" "$PR_TITLE" "$PR_URL")

        AGG_OUT="$REPO_DIR/.codex-scratch/aggregator-output.md"
        codex exec \
            -C "$REPO_DIR" \
            --sandbox read-only \
            -o "$AGG_OUT" \
            "$AGG_PROMPT" \
            >> "$LOG_FILE" 2>&1
        AGG_EXIT=$?

        if [ "$AGG_EXIT" -ne 0 ] || [ ! -s "$AGG_OUT" ]; then
            log "$PR_ID: aggregator failed (exit $AGG_EXIT) or empty output — aborting"
            cleanup_scratch "$REPO_DIR"
            rm -f "$LOCK_FILE"
            continue
        fi

        REVIEW=$(cat "$AGG_OUT")

        if ! echo "$REVIEW" | grep -q '^VERDICT:'; then
            log "$PR_ID: aggregator output missing VERDICT line — aborting"
            cleanup_scratch "$REPO_DIR"
            rm -f "$LOCK_FILE"
            continue
        fi
```

Note: `build_specialist_prompt` treats aggregator.md as just another prompt file — the common-header substitution of `{{SPECIALIST_NAME}}` → `aggregator` is harmless since the aggregator prompt doesn't use that placeholder.

- [ ] **Step 2: Smoke test — end-to-end with aggregator, dry-run**

Same setup as Task 5 Step 3 — force a re-review, stub GH writes, run, inspect:

```bash
PR_ID="cncorp/plow#<number>"
jq --arg id "$PR_ID" 'del(.[$id])' ~/.pr-reviewer/state.json > /tmp/state.json.new
cp /tmp/state.json.new ~/.pr-reviewer/state.json

cp ~/.pr-reviewer/review.sh /tmp/review.sh.bak
sed -i 's|^        gh pr comment|        echo DRYRUN gh pr comment|; s|^            gh pr review|            echo DRYRUN gh pr review|' ~/.pr-reviewer/review.sh

~/.pr-reviewer/review.sh

# Restore:
cp /tmp/review.sh.bak ~/.pr-reviewer/review.sh
```

Expected behavior in output:
- Log shows `launching 4 specialists in parallel` then `all 4 specialists completed` then `running aggregator` within the same PR block.
- `DRYRUN gh pr comment` body has the `**Overview**` / `**Findings**` / `**Security**` / `**Test coverage**` structure and a final `VERDICT:` line.
- Total `DRYRUN gh pr comment` body is under ~500 words.

- [ ] **Step 3: End-to-end real run on a low-stakes PR**

Pick a small, low-stakes PR from one of the tracked repos. Force re-review by clearing its state entry (as above) but do NOT stub the gh writes. Run `review.sh`. Open the PR and confirm the posted review looks good.

Acceptance criteria for this live run:
- One comment posted, structured per the aggregator output spec.
- No duplicate of a previous review.
- If VERDICT was APPROVE, an approve review appears alongside the comment. If COMMENT, no approve.
- `state.json` updated with the new SHA.

- [ ] **Step 4: Commit**

```bash
cd ~/.pr-reviewer && git add review.sh && git commit -q -m "Add aggregator pass that merges specialist findings" || echo "not a git repo — skipping"
```

---

## Task 7: Observability and cleanup

**Purpose:** Make the new run cheap to diagnose. Log counts per specialist. Leave the last run's scratch dir around for inspection — but only the last one. Cap log file growth.

**Files:**
- Modify: `~/.pr-reviewer/review.sh`

- [ ] **Step 1: Log specialist output sizes**

In `review.sh`, after the "all 4 specialists completed" log line from Task 5, add:

```bash
        for angle in security data-integrity architecture tests; do
            LINES=$(wc -l < "$SPECIALISTS_DIR/${angle}.md")
            NO_FINDINGS=""
            grep -q '^No findings\.' "$SPECIALISTS_DIR/${angle}.md" && NO_FINDINGS=" (no findings)"
            log "$PR_ID: specialist=$angle lines=$LINES$NO_FINDINGS"
        done
```

- [ ] **Step 2: Preserve scratch dir for last-run inspection**

In `review.sh`, find the `cleanup_scratch` calls. Replace each with a function that MOVES the scratch dir to `$STATE_DIR/last-run-scratch/<pr-slug>/`, overwriting any previous run's copy. Add to the helper section near the top:

```bash
preserve_scratch() {
    local repo_dir="$1" pr_slug="$2"
    local archive="$STATE_DIR/last-run-scratch/$pr_slug"
    if [ -d "$repo_dir/.codex-scratch" ]; then
        rm -rf "$archive"
        mkdir -p "$(dirname "$archive")"
        mv "$repo_dir/.codex-scratch" "$archive"
    fi
}
```

Replace each `cleanup_scratch "$REPO_DIR"` call with:

```bash
preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr '/#' '__')"
```

Delete the `cleanup_scratch` function definition.

- [ ] **Step 3: Cap cron.log and review.log growth**

Given the cron runs every 2 minutes and review.log is already ~470KB, add a rotation step at the top of `review.sh` after the existing log() definition:

```bash
# Rotate logs when they exceed 5MB
for f in "$STATE_DIR/review.log" "$STATE_DIR/cron.log"; do
    if [ -f "$f" ] && [ "$(stat -c%s "$f")" -gt 5242880 ]; then
        mv "$f" "$f.1"
    fi
done
```

- [ ] **Step 4: Smoke test — verify preserved scratch and log rotation**

```bash
# Force a re-review on a small PR, run normally (no GH stub this time if you're confident after Task 6):
PR_ID="<pick one>"
jq --arg id "$PR_ID" 'del(.[$id])' ~/.pr-reviewer/state.json > /tmp/state.json.new
cp /tmp/state.json.new ~/.pr-reviewer/state.json
~/.pr-reviewer/review.sh

# Inspect preserved scratch:
ls ~/.pr-reviewer/last-run-scratch/
find ~/.pr-reviewer/last-run-scratch/ -type f | head -20
```

Expected: `last-run-scratch/<slug>/specialists/{security,data-integrity,architecture,tests}.md` all present, plus `diff.patch`, `aggregator-output.md`, and the other input files.

- [ ] **Step 5: Commit**

```bash
cd ~/.pr-reviewer && git add review.sh && git commit -q -m "Add observability: specialist line logging, preserved scratch, log rotation" || echo "not a git repo — skipping"
```

---

## Task 8: Live validation and rollout

**Purpose:** Confirm the new reviewer is working in production on the every-2-minutes cron.

**Files:** none modified.

- [ ] **Step 1: Watch a live cron tick**

```bash
tail -f ~/.pr-reviewer/review.log
```

Wait for a tick that actually reviews a PR (most will be "No new PRs to review"). When you see `launching 4 specialists in parallel`, let it run to completion. Expected sequence:

```
Reviewing cncorp/plow#NNN (force=...)
cncorp/plow#NNN: running `just test` (timeout 30m)...
cncorp/plow#NNN: just test PASSED|FAILED
cncorp/plow#NNN: launching 4 specialists in parallel...
cncorp/plow#NNN: specialist=security lines=...
cncorp/plow#NNN: specialist=data-integrity lines=...
cncorp/plow#NNN: specialist=architecture lines=...
cncorp/plow#NNN: specialist=tests lines=...
cncorp/plow#NNN: all 4 specialists completed
cncorp/plow#NNN: running aggregator...
Posted review comment on cncorp/plow#NNN
Done with cncorp/plow#NNN
```

- [ ] **Step 2: Review the posted comment**

Open the PR in the browser. Compare the comment against the specialist outputs in `~/.pr-reviewer/last-run-scratch/<slug>/specialists/`:

- Does the aggregator include every `blocking` finding from the specialists?
- Are any findings duplicated across sections?
- Is the VERDICT consistent with the findings (APPROVE when no blocking, COMMENT when blocking present)?
- Is the review under 500 words?

If any check fails, iterate on the aggregator prompt (`~/.pr-reviewer/prompts/aggregator.md`) and re-run by clearing state and waiting for the next cron tick. Aggregator iteration does not require re-running the specialists — the specialist outputs are cached in `last-run-scratch/`, so you can manually rerun just the aggregator for faster iteration:

```bash
# Rerun aggregator only, against the last preserved scratch
SLUG="cncorp_plow__NNN"
REPO_DIR=~/.pr-reviewer/repos/cncorp_plow
# Restore scratch from preserved copy for the aggregator to read:
cp -r ~/.pr-reviewer/last-run-scratch/$SLUG "$REPO_DIR/.codex-scratch"
# Rebuild and rerun aggregator prompt:
# (extract the build_specialist_prompt + codex invocation inline or write a one-off script)
```

- [ ] **Step 3: Watch a second tick to rule out transient pass**

Let the cron run another review naturally over the next few hours. Confirm the new architecture holds up — same observability sequence, no stuck specialists, no empty outputs.

- [ ] **Step 4: Done**

No commit for this task unless iteration on prompts was required. If it was, commit any prompt tweaks with a message like `Tune aggregator prompt: <what changed and why>`.

---

## Self-Review

**1. Spec coverage:**
- Repo-read access instead of diff-on-stdin → Task 4.
- Per-repo PRODUCT_CONTEXT.md injected into the review prompt → Task 1 (files) + Task 4 (plumbing into scratch) + Task 2/architecture.md (instruction to read it).
- Fan-out into specialist passes (security, data-integrity, architecture, tests) → Task 5.
- Aggregator pass that dedupes and ranks → Task 6.
- Covered.

**2. Placeholder scan:** No "TBD", "implement later", or "similar to Task N" references. All code blocks show the actual content. Smoke-test steps show exact commands and expected outputs.

**3. Type / name consistency checks:**
- Scratch dir path: `$REPO_DIR/.codex-scratch/` — consistent across Tasks 4, 5, 6, 7.
- Specialist angle names: `security`, `data-integrity`, `architecture`, `tests` — consistent in Tasks 2, 5, 6, 7.
- Scratch filenames: `diff.patch`, `previous-review.md`, `test-results.md`, `prior-art.md`, `standards.md`, `product-context.md` — consistent across `common-header.md`, `review.sh` `write_scratch` calls, and the specialist prompts' "Inputs already prepared for you" blocks.
- Helper function names: `write_scratch`, `preserve_scratch`, `build_specialist_prompt`, `safe_sed` — each defined once, referenced in later tasks.
- `run-specialist.sh` signature (5 positional args) — matches callers in Task 5.
- `cleanup_scratch` is introduced in Task 4 and explicitly replaced by `preserve_scratch` in Task 7 Step 2 (function deleted in the same step).

**4. Concerns / known tradeoffs worth flagging during execution:**
- `codex exec` cost is now ~5× per review (4 specialists + 1 aggregator). For this project (<10 PRs/day) this is acceptable per the user's explicit "how can we spend more tokens" framing, but worth monitoring via the existing `cron.log`.
- If a single specialist is consistently empty or low-value, consider dropping it rather than iterating the prompt forever — a 3-specialist + aggregator setup is not worse than 4 if the 4th adds noise.
- The `sed` placeholder substitution in `build_specialist_prompt` handles `|`, `&`, `\` but does not handle newlines. PR titles contain newlines extremely rarely; if it happens, the substitution will produce a malformed prompt and the specialist will likely fail loud. Acceptable.
