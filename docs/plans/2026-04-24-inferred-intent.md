# Inferred Intent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pre-fan-out step that infers the developer's end-user-facing intent from PR title + commits + diff, writes it to `.codex-scratch/inferred-intent.md`, and feeds it to all 5 specialists, the critic, and the aggregator. The aggregator surfaces the intent statement as the lead line of the posted review (italicized, prefix stripped).

**Architecture:** A new `prompts/intent.md` is invoked synchronously after scratch-file preparation and before the existing parallel fan-out, via one `codex exec` call at `model_reasoning_effort=high`. Hard-fail on empty/malformed output (no graceful degrade). A new `commits.md` scratch file (sourced from `gh pr view --json commits`) gives the intent prompt and downstream specialists access to commit subjects without re-running git. The existing `build_specialist_prompt` helper is extended to substitute a new `{{PR_AUTHOR}}` placeholder.

**Tech Stack:** Bash 5.2, `codex exec`, `gh`, `jq`, `flock(1)`. All existing — no new dependencies.

**Spec:** `docs/specs/2026-04-24-inferred-intent-design.md`

---

## Meta Context (read first — applies to every task)

**This plan modifies the live production tree's symlinked code paths.** `~/Hacking/knightwatch-reviewer/` is symlinked into `~/.pr-reviewer/` — the systemd unit runs the scripts directly from this checkout, so a half-applied edit could land in production mid-tick.

**The user's working pattern is to implement plans in a sibling checkout, not the live tree.** From `~/.claude/CLAUDE.md`:

> Workspace Isolation — NO git worktrees, ever. I keep parallel checkouts as sibling directories instead (e.g. `~/Hacking/plow`, `~/Hacking/plow2`, `~/Hacking/plow3`, ...).

**Sibling-tree status at plan-write time (2026-04-24):**

- `~/Hacking/knightwatch-reviewer/` — main branch, live production tree. **Do not implement here.**
- `~/Hacking/knightwatch-reviewer2/` — currently on `parallel-reviews` branch (stale; that work has been merged). Available if reset.

**Before starting Task 1, confirm with the user:** *"Implement in `knightwatch-reviewer2/` after resetting it to a fresh `inferred-intent` branch off main, or create a new `knightwatch-reviewer3/` sibling?"* Use whichever sibling the user chooses; do not pick on your own.

The remainder of this plan refers to the sibling as `$IMPL_TREE`. Substitute the actual path when running commands.

**Sandbox pattern for smoke tests** (mirrors `lib/tests/state-io-smoke.sh`):

```bash
SANDBOX=$(mktemp -d -t kw-intent-XXXXXX)
export STATE_DIR="$SANDBOX"
export STATE_FILE="$SANDBOX/state.json"
export LOG_FILE="$SANDBOX/review.log"
export REPOS_DIR="$SANDBOX/repos"
export WORKDIRS_DIR="$SANDBOX/workdirs"
mkdir -p "$REPOS_DIR" "$WORKDIRS_DIR"
echo '{}' > "$STATE_FILE"

# ... run test against $IMPL_TREE ...

rm -rf "$SANDBOX"
```

**Never** point smoke tests at `~/.pr-reviewer/state.json`, `~/.pr-reviewer/review.log`, or any path under `~/.pr-reviewer/`.

---

## File Structure

**New files:**

| Path | Purpose |
|---|---|
| `lib/prompt-build.sh` | Sourceable helpers — `safe_sed` and `build_specialist_prompt`, factored out of `review-one-pr.sh` so the substitution logic is testable. |
| `prompts/intent.md` | The intent-inference prompt. Reads diff + author-intent + commits + file-history; outputs `Inferred intent: …`. |
| `lib/tests/build-specialist-prompt-smoke.sh` | Smoke test for `build_specialist_prompt` placeholder substitution, including the new `{{PR_AUTHOR}}`. |

**Modified files:**

| Path | Change |
|---|---|
| `lib/review-one-pr.sh` | (a) source `lib/prompt-build.sh` instead of defining `safe_sed`/`build_specialist_prompt` inline; (b) extend `gh pr view --json` to include `author,commits`; (c) write `commits.md` scratch file; (d) hard-fail if `PR_AUTHOR` is empty; (e) update all `build_specialist_prompt` call sites to pass `PR_AUTHOR`; (f) insert intent-inference step before fan-out, with format-validation and hard-fail. |
| `prompts/common-header.md` | Add bullets for `inferred-intent.md` and `commits.md` to the "Inputs already prepared for you" list. |
| `prompts/architecture.md` | Add "Spirit-vs-implementation" bullet under Scope; tighten the "Over-engineering for this stage" line so it doesn't get cited to reject spirit-vs-implementation findings. |
| `prompts/aggregator.md` | Add inferred-intent + commits to inputs; rewrite the "Produce the final posted review in EXACTLY this structure" template so the italicized intent line leads, with explicit prefix-strip + italicization formatting rule. |
| `justfile` | Add `bash lib/tests/build-specialist-prompt-smoke.sh` to the `test` recipe. |

**External repo (separate commit, separate working tree):**

| Path | Change |
|---|---|
| `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` | Two surgical bullet adds: "Engineer time > compute time" in Team Context; "Every conditional is a maintenance burden" in Concise Code. |

---

## Task 1: Set up implementation tree

**Files:**
- N/A (workspace setup)

- [ ] **Step 1: Confirm sibling-tree choice with user**

Ask: *"Implement in `knightwatch-reviewer2/` after resetting it to a fresh `inferred-intent` branch off main, or create a new `knightwatch-reviewer3/` sibling?"*

- [ ] **Step 2: Set up the chosen tree**

If reusing `knightwatch-reviewer2/`:

```bash
cd ~/Hacking/knightwatch-reviewer2
git fetch origin
git checkout main
git reset --hard origin/main
git checkout -b inferred-intent
```

If creating `knightwatch-reviewer3/`:

```bash
cd ~/Hacking
git clone ~/Hacking/knightwatch-reviewer knightwatch-reviewer3
cd knightwatch-reviewer3
git remote set-url origin "$(git -C ~/Hacking/knightwatch-reviewer remote get-url origin)"
git fetch origin
git checkout -b inferred-intent
```

Note: `git reset --hard` is destructive — only run after the user confirms `parallel-reviews` is stale and safe to discard.

- [ ] **Step 3: Verify the spec is present**

Run: `ls $IMPL_TREE/docs/specs/2026-04-24-inferred-intent-design.md`
Expected: file listed (the spec was committed to main; the new branch inherits it).

---

## Task 2: Factor `build_specialist_prompt` into `lib/prompt-build.sh`

**Why first:** Subsequent tasks add a `{{PR_AUTHOR}}` placeholder and a smoke test for the substitution. Both require the function to be sourceable in isolation.

**Files:**
- Create: `lib/prompt-build.sh`
- Modify: `lib/review-one-pr.sh:64-87` (remove inline `safe_sed` + `build_specialist_prompt`; replace with a `source` line)

- [ ] **Step 1: Create `lib/prompt-build.sh` with the existing logic verbatim**

```bash
#!/bin/bash
# Sourceable helpers for assembling specialist prompts.
# `safe_sed`: escape a string for use as a sed replacement.
# `build_specialist_prompt`: concatenate prompts/common-header.md with an
# angle file, substituting {{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
# {{SPECIALIST_NAME}}, and {{PR_AUTHOR}}.

safe_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5" pr_author="$6"
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
    local esc_id esc_title esc_url esc_name esc_author
    esc_id=$(safe_sed "$pr_id")
    esc_title=$(safe_sed "$pr_title")
    esc_url=$(safe_sed "$pr_url")
    esc_name=$(safe_sed "$specialist_name")
    esc_author=$(safe_sed "$pr_author")
    {
        sed -e "s|{{PR_ID}}|$esc_id|g" \
            -e "s|{{PR_TITLE}}|$esc_title|g" \
            -e "s|{{PR_URL}}|$esc_url|g" \
            -e "s|{{SPECIALIST_NAME}}|$esc_name|g" \
            -e "s|{{PR_AUTHOR}}|$esc_author|g" \
            "$common"
        echo ""
        cat "$specialist_file"
    }
}
```

The `{{PR_AUTHOR}}` line is new. Everything else is moved from `review-one-pr.sh` unchanged.

- [ ] **Step 2: Replace the inline definitions in `lib/review-one-pr.sh`**

Locate lines 64–87 in `lib/review-one-pr.sh` (the `# --- sed escape ---` block through the closing `}` of `build_specialist_prompt`). Replace with:

```bash
# --- prompt-build helpers (sourced from lib/prompt-build.sh) ---
. "$_LIB_DIR/prompt-build.sh"
```

The `_LIB_DIR` variable is already defined just above (around line 61) for sourcing `state-io.sh`. Move the new `source` line to AFTER `_LIB_DIR=...` so the variable is in scope.

- [ ] **Step 3: Update `~/.pr-reviewer/` symlink awareness**

`~/.pr-reviewer/lib/` is a symlink (via the parent dir) into the production checkout. New files added in `lib/` are picked up automatically by the running service once merged. Confirm by:

```bash
ls -la ~/.pr-reviewer/lib/
```

Expected: directory listing shows it's a symlink and includes existing `state-io.sh`, `review-one-pr.sh`, `run-specialist.sh`. (No action needed in this task — just sanity-check that adding `prompt-build.sh` to the impl tree will be picked up at merge.)

- [ ] **Step 4: Run syntax check**

```bash
cd $IMPL_TREE
bash -n lib/prompt-build.sh
bash -n lib/review-one-pr.sh
```

Expected: no output, exit 0 for both.

- [ ] **Step 5: Run existing smoke test**

```bash
cd $IMPL_TREE && just test
```

Expected: all checks pass (this task should not break state-io smoke).

- [ ] **Step 6: Commit**

```bash
cd $IMPL_TREE
git add lib/prompt-build.sh lib/review-one-pr.sh
git commit -m "Factor prompt-build helpers into lib/prompt-build.sh

Pulls safe_sed and build_specialist_prompt out of review-one-pr.sh into
a sourceable helper file. No behavior change in this commit; subsequent
commits add a {{PR_AUTHOR}} placeholder and a smoke test that requires
the function be sourceable in isolation.
"
```

---

## Task 3: Smoke-test `build_specialist_prompt` (TDD baseline)

**Why now:** Lock in current behavior with a test before adding the new `{{PR_AUTHOR}}` placeholder. The test fails meaningfully if substitution breaks.

**Files:**
- Create: `lib/tests/build-specialist-prompt-smoke.sh`
- Modify: `justfile` (add the new smoke test to the `test` recipe)

- [ ] **Step 1: Write the smoke test**

```bash
#!/bin/bash
# Smoke test for lib/prompt-build.sh's build_specialist_prompt.
#
# Verifies all five placeholders ({{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
# {{SPECIALIST_NAME}}, {{PR_AUTHOR}}) are substituted correctly, and
# that no unsubstituted {{...}} markers remain in the output.

set -euo pipefail

TMPDIR=$(mktemp -d -t prompt-build-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock the common-header that build_specialist_prompt expects at
# $HOME/.pr-reviewer/prompts/common-header.md, by overriding $HOME.
export HOME="$TMPDIR"
mkdir -p "$HOME/.pr-reviewer/prompts"
cat > "$HOME/.pr-reviewer/prompts/common-header.md" <<'EOF'
PR: {{PR_ID}}
Title: {{PR_TITLE}}
URL: {{PR_URL}}
Specialist: {{SPECIALIST_NAME}}
Author: {{PR_AUTHOR}}
EOF

ANGLE_FILE="$TMPDIR/angle.md"
echo "Angle: focus on X" > "$ANGLE_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_DIR/prompt-build.sh"

OUTPUT=$(build_specialist_prompt \
    "security" \
    "$ANGLE_FILE" \
    "owner/repo#42" \
    "Add caching to /api/foo" \
    "https://github.com/owner/repo/pull/42" \
    "plucas")

echo "  asserting all five placeholders substituted..."
for pair in "PR: owner/repo#42" "Title: Add caching to /api/foo" \
            "URL: https://github.com/owner/repo/pull/42" \
            "Specialist: security" "Author: plucas" \
            "Angle: focus on X"; do
    if ! echo "$OUTPUT" | grep -qF "$pair"; then
        echo "FAIL: expected '$pair' in output"
        echo "--- output ---"
        echo "$OUTPUT"
        exit 1
    fi
done

echo "  asserting no unsubstituted {{...}} markers..."
if echo "$OUTPUT" | grep -q '{{[^}]*}}'; then
    echo "FAIL: unsubstituted placeholder in output"
    echo "$OUTPUT" | grep '{{[^}]*}}'
    exit 1
fi

echo "  asserting sed-special chars in inputs are escaped..."
TRICKY_OUTPUT=$(build_specialist_prompt \
    "tests" "$ANGLE_FILE" \
    "owner/repo#1" "Title with & ampersand and | pipe and \\backslash" \
    "https://example.com" "user|name")

if ! echo "$TRICKY_OUTPUT" | grep -qF "Title with & ampersand and | pipe and \\backslash"; then
    echo "FAIL: tricky title not preserved verbatim"
    echo "--- output ---"
    echo "$TRICKY_OUTPUT"
    exit 1
fi

echo "  PASS"
```

Save as `lib/tests/build-specialist-prompt-smoke.sh` and `chmod +x` it.

- [ ] **Step 2: Run the test**

```bash
cd $IMPL_TREE
bash lib/tests/build-specialist-prompt-smoke.sh
```

Expected: `PASS` printed; exit 0.

- [ ] **Step 3: Wire into `just test`**

Edit `justfile`. Find the `=== state-io smoke test ===` block and add a new section right after it:

```
    echo ""
    echo "=== prompt-build smoke test ==="
    bash lib/tests/build-specialist-prompt-smoke.sh

    echo ""
    echo "all checks passed"
```

The existing "all checks passed" line moves to the end. Result: the `test` recipe runs both smoke tests in sequence.

- [ ] **Step 4: Run `just test`**

```bash
cd $IMPL_TREE && just test
```

Expected: both smoke tests pass; "all checks passed" printed last.

- [ ] **Step 5: Commit**

```bash
git add lib/tests/build-specialist-prompt-smoke.sh justfile
git commit -m "Smoke test for build_specialist_prompt placeholder substitution

Locks in current substitution behavior (and the new {{PR_AUTHOR}} added
in the previous commit) before subsequent changes wire PR_AUTHOR
through review-one-pr.sh's call sites.
"
```

---

## Task 4: Wire `PR_AUTHOR` through `lib/review-one-pr.sh`

**Files:**
- Modify: `lib/review-one-pr.sh:316` (extend `gh pr view --json` field list)
- Modify: `lib/review-one-pr.sh:316-340` (parse author after `PR_DATA=`; hard-fail if empty)
- Modify: `lib/review-one-pr.sh:353-356` (5 specialist call sites add `$PR_AUTHOR`)
- Modify: `lib/review-one-pr.sh:403-406` (aggregator call site adds `$PR_AUTHOR`)

- [ ] **Step 1: Extend `gh pr view --json` field list**

Locate line 316:

```bash
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,closingIssuesReferences 2>/dev/null)
```

Change to:

```bash
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,author,commits,closingIssuesReferences 2>/dev/null)
```

- [ ] **Step 2: Parse `PR_AUTHOR` immediately after `PR_DATA=` (line 317)**

Add right after the `PR_DATA=` line (before the `AUTHOR_INTENT="..."` block):

```bash
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
if [ -z "$PR_AUTHOR" ]; then
    log "$PR_ID: gh pr view returned no author handle — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
```

- [ ] **Step 3: Update 5 specialist call sites to pass `$PR_AUTHOR`**

Locate the loop at lines 352–363:

```bash
for angle in security data-integrity architecture simplification tests; do
    PROMPT=$(build_specialist_prompt \
        "$angle" \
        "$HOME/.pr-reviewer/prompts/${angle}.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL")
    ~/.pr-reviewer/lib/run-specialist.sh \
        ...
```

Add `"$PR_AUTHOR"` as the 6th positional argument to `build_specialist_prompt`:

```bash
for angle in security data-integrity architecture simplification tests; do
    PROMPT=$(build_specialist_prompt \
        "$angle" \
        "$HOME/.pr-reviewer/prompts/${angle}.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
    ~/.pr-reviewer/lib/run-specialist.sh \
        ...
```

- [ ] **Step 4: Update aggregator call site to pass `$PR_AUTHOR`**

Locate lines 403–406:

```bash
AGG_PROMPT=$(build_specialist_prompt \
    "aggregator" \
    "$HOME/.pr-reviewer/prompts/aggregator.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL")
```

(Superseded by PR #12: the aggregator now bypasses `build_specialist_prompt` entirely and calls `substitute_placeholders` directly. Steps below are historical.)

Change to:

```bash
AGG_PROMPT=$(build_specialist_prompt \
    "aggregator" \
    "$HOME/.pr-reviewer/prompts/aggregator.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
```

- [ ] **Step 5: Run syntax check**

```bash
bash -n lib/review-one-pr.sh
```

Expected: no output, exit 0.

- [ ] **Step 6: Run `just test`**

```bash
cd $IMPL_TREE && just test
```

Expected: pass. (No call site exercises `{{PR_AUTHOR}}` yet — common-header.md doesn't use it. The placeholder is wired but unused. That's the intermediate state we want.)

- [ ] **Step 7: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "Wire PR_AUTHOR through review-one-pr.sh

Extends gh pr view's --json field list to include author and commits,
parses the author handle, hard-fails if missing, and passes it as the
new 6th positional arg to build_specialist_prompt at every call site
(5 specialists + aggregator). The {{PR_AUTHOR}} placeholder now
substitutes wherever it appears in any prompt; no current prompt uses
it yet — the intent prompt added in the next commit is the first
consumer.
"
```

---

## Task 5: Add `commits.md` scratch file

**Files:**
- Modify: `lib/review-one-pr.sh` — add a `write_scratch ... commits.md` call after the existing scratch-file writes (between the `author-intent.md` write at line 340 and the `mkdir -p "$SPECIALISTS_DIR"` at line 343)

- [ ] **Step 1: Generate and write `commits.md`**

Right after the `write_scratch "$REPO_DIR" "author-intent.md" "$AUTHOR_INTENT"` line (line 340), insert:

```bash
COMMITS=$(printf '%s' "$PR_DATA" | jq -r '.commits[]? | "\(.oid[0:7]) \(.messageHeadline)"')
if [ -z "$COMMITS" ]; then
    log "$PR_ID: gh pr view returned no commits — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
write_scratch "$REPO_DIR" "commits.md" "$COMMITS"
```

This is sourced from the same `gh pr view` call extended in Task 4. The format is `<7-char-sha> <subject>`, one per line.

- [ ] **Step 2: Run syntax check**

```bash
bash -n lib/review-one-pr.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Run `just test`**

```bash
cd $IMPL_TREE && just test
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "Write commits.md scratch file from gh pr view

Sources the canonical PR commit list from GitHub (already fetched in
the previous commit's --json author,commits extension), formats as
'<7-char-sha> <messageHeadline>' one per line, and writes it as a new
scratch file alongside the others. Used by the intent-inference step
in the next commit and available to all specialists.

Hard-fails if the PR has zero commits (degenerate state) — we don't
want to silently produce an empty commits.md.
"
```

---

## Task 6: Create `prompts/intent.md`

**Files:**
- Create: `prompts/intent.md`

- [ ] **Step 1: Write the prompt**

```markdown
**Your job: infer the developer's end-user-facing intent for this PR.**

You are running BEFORE a fan-out of 5 review specialists. Your job is to write a short, tentative statement of *the end-user experience the developer is trying to deliver* — so the architecture and simplification specialists can grade the implementation against the spirit of the goal, not just the literal code.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**Author:** @{{PR_AUTHOR}}
**URL:** {{PR_URL}}

**Inputs:**
- `.codex-scratch/diff.patch` — the diff under review
- `.codex-scratch/author-intent.md` — PR title + body + linked issues. The body may be AI-written and misleading; trust the diff and commit subjects when they conflict.
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line
- `.codex-scratch/file-history.md` — recent commits per touched file

**Rules:**
1. Read the diff, the commits, and the linked issues. Triangulate.
2. Output exactly ONE block, no preamble, no commentary, no headers:

   ```
   Inferred intent: It appears @{{PR_AUTHOR}} is working towards <X> by <Y>.
   ```

   Where:
   - `<X>` names the **end-user-facing outcome** the developer is chasing. Not "what the code does." Examples of good `<X>`: "letting users retry a failed payment without re-entering card details", "reducing first-paint latency on the dashboard for users on mobile networks", "preventing duplicate Slack notifications when an alert fires twice in quick succession". Examples of bad `<X>` (forbidden): "improving the auth system", "refactoring the payment module", "adding a function".
   - `<Y>` cites concrete specifics from the diff or commits — file paths, function names, the user-facing surface that's changing. Examples of good `<Y>`: "adding a `/api/payments/retry` endpoint and wiring it to the existing failure UI in `app/payments/Failed.tsx`", "switching the dashboard fetch from N+1 per-widget calls to a single batched `/api/dashboard/v2` route". Examples of bad `<Y>` (forbidden): "via various changes", "by updating the relevant files".

3. Length: 1–3 sentences total. Be tentative ("It appears…") — you are inferring, not asserting.

4. **Don't restate what the code does mechanically.** The Overview section in the posted review already does that. Your job is to name the *user-facing outcome*.

5. **If intent genuinely cannot be inferred** (e.g. dependency bump, mechanical refactor with no user-facing implication, automated formatting pass), output exactly:

   ```
   Inferred intent: This PR has no inferable end-user-facing intent — it appears to be <category, e.g. "a dependency bump from foo@1.2 to foo@1.3", "a mechanical formatter pass over lib/foo.py">.
   ```

   That is a valid output, not a failure. Use this only when the diff truly has no user-facing implication — not as an escape hatch for hard-to-summarize PRs.

6. **The line MUST start with the literal prefix `Inferred intent: `**. The pipeline validates this prefix and aborts if missing — so do NOT add any preamble, commentary, blank lines, or markdown headers above it.

7. The aggregator strips the `Inferred intent: ` prefix and italicizes the rest before posting. Write the sentence so it reads naturally without the prefix:

   - Good (reads naturally with prefix stripped): `Inferred intent: It appears @plucas is working towards letting users retry failed payments without re-entering card details by adding a `/api/payments/retry` endpoint.`
   - Bad (the prefix is load-bearing for the sentence): `Inferred intent: payment retry feature.`
```

Save as `prompts/intent.md`.

- [ ] **Step 2: Spot-check the prompt against `prompts/architecture.md`'s style**

```bash
diff <(head -5 prompts/intent.md) <(head -5 prompts/architecture.md)
```

Expected: different content (intent prompt has its own structure), but both files use the same `**bold heading.**` opening pattern.

- [ ] **Step 3: Commit**

```bash
git add prompts/intent.md
git commit -m "Add prompts/intent.md: pre-fan-out intent inference prompt

Defines the prompt for the new intent-inference step. Output format is
a strict 'Inferred intent: ...' line (validated by the pipeline) that
the aggregator strips and italicizes for the lead line of the posted
review.

The next commit wires this prompt into review-one-pr.sh.
"
```

---

## Task 7: Add intent-inference step to `lib/review-one-pr.sh`

**Files:**
- Modify: `lib/review-one-pr.sh` — insert intent step between scratch-file prep (around line 350, after the `gh pr comment "👀 reviewing"` call) and the existing fan-out loop (line 351, `log "$PR_ID: launching 5 specialists in parallel..."`)

- [ ] **Step 1: Insert the intent-inference block**

Find the block:

```bash
gh pr comment "$PR_NUM" --repo "$REPO" \
    --body "👀 reviewing — [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)" \
    >/dev/null 2>&1 || log "$PR_ID: failed to post reviewing-status comment (continuing)"

log "$PR_ID: launching 5 specialists in parallel..."
```

Insert between the two log lines:

```bash
log "$PR_ID: inferring developer intent..."
INTENT_PROMPT=$(build_specialist_prompt \
    "intent" \
    "$HOME/.pr-reviewer/prompts/intent.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
INTENT_OUT="$REPO_DIR/.codex-scratch/inferred-intent.md"
codex exec \
    -C "$REPO_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    -c model_reasoning_effort=high \
    -o "$INTENT_OUT" \
    "$INTENT_PROMPT" \
    >> "$LOG_FILE" 2>&1
INTENT_EXIT=$?

if [ "$INTENT_EXIT" -ne 0 ] || [ ! -s "$INTENT_OUT" ]; then
    log "$PR_ID: intent inference failed (codex exit=$INTENT_EXIT, output empty=$([ ! -s "$INTENT_OUT" ] && echo true || echo false)) — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi

if ! head -1 "$INTENT_OUT" | grep -q '^Inferred intent: '; then
    log "$PR_ID: intent output does not start with 'Inferred intent: ' prefix — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi

log "$PR_ID: intent inference complete: $(head -1 "$INTENT_OUT")"
```

- [ ] **Step 2: Run syntax check**

```bash
bash -n lib/review-one-pr.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Run `just test`**

```bash
cd $IMPL_TREE && just test
```

Expected: pass. (Smoke tests don't exercise this code path; the verification is the dogfood pass in Task 11.)

- [ ] **Step 4: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "Run intent-inference step before fan-out

Inserts a new codex exec call between scratch-file prep and the
parallel specialist fan-out. Writes .codex-scratch/inferred-intent.md.

Hard-fail invariants:
  - codex exit 0
  - output file non-empty
  - first line starts with 'Inferred intent: '

Reasoning effort matches the existing specialists, critic, and
aggregator (model_reasoning_effort=high).
"
```

---

## Task 8: Wire `inferred-intent.md` and `commits.md` into `prompts/common-header.md`

**Files:**
- Modify: `prompts/common-header.md`

- [ ] **Step 1: Add bullets to the inputs list**

Find the existing list of input files (lines 9–17, the `**Inputs already prepared for you:**` block). Add two bullets — order them logically: `inferred-intent.md` near the top (it's the lead context), `commits.md` near `file-history.md` (both are commit-derived).

Locate this line in `prompts/common-header.md`:

```
- `.codex-scratch/diff.patch` — the diff you are reviewing. ...
```

Add directly above it:

```
- `.codex-scratch/inferred-intent.md` — a tentative one-line statement of the end-user-facing outcome this PR is working toward, derived pre-fan-out from PR title + commits + diff. Use this as the *spirit* you are evaluating against. The architecture and simplification specialists in particular should ask: does the chosen implementation deliver on that intent in a way that scales, or is it brittle?
```

Locate this line:

```
- `.codex-scratch/file-history.md` — for each touched file, the 5 most recent commit subjects. ...
```

Add directly below it:

```
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line. Use this to read the developer's own narrative of their work, beyond the (possibly AI-written) PR description.
```

- [ ] **Step 2: Run syntax check on the markdown**

```bash
# A markdown file isn't bash-parseable, so just verify it's non-empty and reads fine.
wc -l prompts/common-header.md
head -25 prompts/common-header.md
```

Expected: line count up by 2; the new bullets visible in the head output.

- [ ] **Step 3: Commit**

```bash
git add prompts/common-header.md
git commit -m "Tell specialists about inferred-intent.md and commits.md

Adds the two new scratch files to the 'Inputs already prepared for you'
list. The inferred-intent bullet explicitly frames it as 'the spirit
you are evaluating against' so architecture and simplification can
grade implementation-vs-spirit, not just the literal code.
"
```

---

## Task 9: Tighten `prompts/architecture.md`

**Files:**
- Modify: `prompts/architecture.md`

- [ ] **Step 1: Tighten the existing "Over-engineering for this stage" line**

Find line 12:

```
- Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do.
```

Replace with:

```
- Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do. **Note:** "more compute / more latency to delete a class of special cases" is *not* over-engineering — it is the trade we want at this stage. The thing being optimized is engineer-hours, not CPU.
```

- [ ] **Step 2: Add the new "Spirit-vs-implementation" bullet under Scope**

Find the Scope list (lines 8–14). Add as a new bullet at the *top* of the list, above "Design tradeoffs":

```
- **Spirit-vs-implementation.** Read `.codex-scratch/inferred-intent.md`. Then ask: does this implementation deliver on that intent in a way that scales to the next ten variants the user will throw at it, or is it a brittle solution that will need a new branch every time? Look for seams that eliminate special cases and conditional sprawl. Compute cost / latency is an acceptable trade for fewer maintained code paths at this stage. Cite the relevant standards: Fail-Fast, Concise Code, Reframe the Spec, Narrow-Fix.
```

- [ ] **Step 3: Verify the file**

```bash
head -20 prompts/architecture.md
```

Expected: the new "Spirit-vs-implementation" bullet appears as the first item under Scope; the "Over-engineering" line includes the new "Note:" clause.

- [ ] **Step 4: Commit**

```bash
git add prompts/architecture.md
git commit -m "Architecture prompt: spirit-vs-implementation + tighten over-eng line

Adds a top-of-Scope bullet directing the architecture specialist to
read inferred-intent.md and grade implementation against the spirit
of the goal — looking for seams that eliminate special-cases and
conditional sprawl, not just abstract design seams.

Tightens the existing 'Over-engineering for this stage' line so it
isn't cited to reject exactly the kind of finding this feature is
designed to surface (i.e., 'more compute to delete a class of
special cases' is the trade we want at our stage).
"
```

---

## Task 10: Update `prompts/aggregator.md`

**Files:**
- Modify: `prompts/aggregator.md`

- [ ] **Step 1: Add `inferred-intent.md` and `commits.md` to the Inputs list**

Find the Inputs list (lines 3–17). Add two bullets — `inferred-intent.md` at the top (it's the most important input for this prompt), `commits.md` near `file-history.md`.

Add as the first bullet under `**Inputs:**`:

```
- `.codex-scratch/inferred-intent.md` — pre-fan-out inferred end-user-facing intent. Lead the posted review with this line (see formatting rule in step 6).
```

After the existing `file-history.md` bullet, add:

```
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line.
```

- [ ] **Step 2: Update the output template**

Find the output template (the fenced code block starting `**Overview** — 2-3 sentences on what the PR does.`). Change it to lead with the italicized intent line:

```
_<intent line, italicized — see formatting rule below>_

**Overview** — 2-3 sentences on what the PR does.

**Strengths** — non-obvious things done right so the author repeats them. Omit this section if none.

**Findings**
1. [blocking|medium|low|nit] <one paragraph, cite Files: path:line, cite the standard violated where applicable (Fail-Fast, Tests, Concise Code, DRY, Narrow-Fix, Spec-Reframe, Migrations)>
2. ...

**Security** — one sentence summary of the security specialist's take, or "None" if clean.

**Test coverage** — summary of the tests specialist's take plus the `just test` outcome. If tests failed, call it out. If the failure is caused by our reviewer sandbox (e.g. read-only filesystem error creating `/home/odio/.docker/*`), note it as a reviewer-side issue, not a PR-related test failure.
```

- [ ] **Step 3: Add the explicit formatting rule for the intent line**

Add a new numbered rule between the current rule 6 (output template) and rule 7 (VERDICT). Renumber accordingly. The new rule:

```
7. **Intent-line formatting** (rule for the leading italicized line):
   a. Read the contents of `.codex-scratch/inferred-intent.md`.
   b. Strip the literal prefix `Inferred intent: ` from the start.
   c. If the result does not already end with a clause like "— reviewing against that goal" or similar, append ` — reviewing against that goal.`
   d. Wrap the whole result in single underscores (italics).
   e. Place it as the first line of the posted review, followed by a blank line, then the existing `**Overview**` section.

   Example. If `.codex-scratch/inferred-intent.md` contains:

   ```
   Inferred intent: It appears @plucas is working towards letting users retry failed payments without re-entering card details by adding a `/api/payments/retry` endpoint.
   ```

   the leading line of the posted review is:

   ```
   _It appears @plucas is working towards letting users retry failed payments without re-entering card details by adding a `/api/payments/retry` endpoint — reviewing against that goal._
   ```

   You do NOT re-infer or paraphrase the intent. Copy, strip, italicize.
```

The current rule 7 (VERDICT) becomes rule 8.

- [ ] **Step 4: Verify the file**

```bash
cat prompts/aggregator.md
```

Expected: Inputs list has the two new bullets; output template leads with `_<intent line, italicized — see formatting rule below>_`; formatting rule 7 is present with the example; rule 8 is the VERDICT rule.

- [ ] **Step 5: Commit**

```bash
git add prompts/aggregator.md
git commit -m "Aggregator: lead posted review with italicized inferred-intent line

Surfaces the pre-fan-out inferred intent at the very top of the posted
review. The aggregator strips the 'Inferred intent: ' prefix, appends
'— reviewing against that goal.', and italicizes — it does not
re-infer or paraphrase.

Adds an explicit formatting rule with a worked example so the
aggregator gets the leading line right every time.
"
```

---

## Task 11: Update `CODING_STANDARDS.md` (separate repo)

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md`

This is a separate working tree. Run these commands from `~/Hacking/vibe-engineering/`.

- [ ] **Step 1: Confirm we're on a clean branch in the right repo**

```bash
cd ~/Hacking/vibe-engineering
git status
git branch --show-current
```

Expected: clean working tree on whatever branch the user normally uses (likely `main` — confirm with user before committing).

- [ ] **Step 2: Add "Engineer time > compute time" bullet to Team Context**

In `claude-config/CODING_STANDARDS.md`, find the Team Context list. Locate this line:

```
- **Concise code that fails loudly > verbose, defensive code with brittle special cases.** ...
```

Add directly *after* it, as a new bullet:

```
- **Engineer time > compute time.** When picking between approaches, prefer the one that scales in *engineers' time* — fewer special cases, fewer conditional branches, fewer files to touch when the next variant lands. A solution that costs more compute or runs slower is fine if it eliminates a class of code we'd otherwise have to maintain. Lookup tables, hand-coded heuristics, and per-case branches are brittle in a way the bill-of-materials never reflects.
```

- [ ] **Step 3: Add "Every conditional is a maintenance burden" bullet to Concise Code**

In the same file, find the `## Concise Code (LOC is a cost)` section and its bullet list. Locate this line:

```
- Prefer direct access over fallback chains and nested conditionals
```

Add directly *after* it, as a new bullet:

```
- Every conditional is a maintenance burden — all things equal, avoid it. Each `if`/`else` branch is a state the next reader has to hold and the next change has to update. When you find yourself adding a special case, ask whether a different seam would let you delete it instead.
```

- [ ] **Step 4: Verify the edits**

```bash
grep -A1 "Concise code that fails loudly" claude-config/CODING_STANDARDS.md
grep -A1 "Prefer direct access" claude-config/CODING_STANDARDS.md
```

Expected: the new bullets follow the located lines exactly as written.

- [ ] **Step 5: Commit**

```bash
git add claude-config/CODING_STANDARDS.md
git commit -m "Add engineer-time-over-compute and avoid-conditionals principles

Two surgical adds to the canonical CODING_STANDARDS.md:

  - Team Context: 'Engineer time > compute time.' Make explicit that
    a solution costing more compute is the right trade if it deletes
    a class of special cases. Without this, naive readers cite the
    'over-engineering for this stage' guardrail to reject exactly the
    spirit-vs-implementation findings we want.

  - Concise Code: 'Every conditional is a maintenance burden.'
    Sharpens the existing 'don't add if x: guards' line by naming the
    real cost — every branch is state the next reader must hold and
    the next change must update.

These reinforce each other and are referenced from the new
spirit-vs-implementation bullet in knightwatch-reviewer's
prompts/architecture.md.
"
```

- [ ] **Step 6: Don't push without user confirmation**

```bash
git log --oneline -2
```

Show the user the commit; let them decide when to push.

---

## Task 12: End-to-end dogfood

**Files:**
- N/A (verification, not modification)

**Important context:** the live `pr-reviewer.service` running every 2 minutes invokes scripts from `~/Hacking/knightwatch-reviewer/` (the `main` tree, symlinked into `~/.pr-reviewer/`). It does NOT run the `inferred-intent` branch's code. So "dogfooding" has two phases:

1. **Pre-merge** — verify the new code is structurally sound (`just test`, syntax checks, prompt content review). No live execution against a real PR is possible without merging first or doing a complex sandbox swap (skipped here as fragile).
2. **Post-merge** — once the PR merges, the live system picks up the new code on the next tick. Verify by triggering a `/review` on an existing PR or letting the next eligible PR get reviewed naturally.

- [ ] **Step 1: Final pre-merge sanity check**

```bash
cd $IMPL_TREE
just test                    # state-io + build_specialist_prompt smokes
bash -n lib/review-one-pr.sh # syntax
bash -n lib/prompt-build.sh
git log --oneline origin/main..HEAD   # review the commit list
```

Expected: all green; one commit per task (Tasks 2–10), totaling ~9 commits on the branch (Task 11's standards commit is in the other repo).

- [ ] **Step 2: Push the branch and open a PR**

```bash
cd $IMPL_TREE
git push -u origin inferred-intent
gh pr create --title "Add pre-fan-out inferred-intent step" --body "$(cat <<'EOF'
## Summary
- Adds a pre-fan-out codex exec step that infers the developer's end-user-facing intent
- Writes `.codex-scratch/inferred-intent.md`, consumed by all 5 specialists, the critic, and the aggregator
- Aggregator leads the posted review with the italicized intent line

Spec: `docs/specs/2026-04-24-inferred-intent-design.md`
Plan: `docs/plans/2026-04-24-inferred-intent.md`

## Test plan
- [x] `just test` green (state-io smoke + new build_specialist_prompt smoke)
- [ ] Post-merge: bot reviews the next eligible PR, posts a review whose lead line is an italicized `_It appears @<author> is working towards…_`
- [ ] Post-merge: `~/.pr-reviewer/last-run-scratch/<slug>__<N>/inferred-intent.md` exists and starts with `Inferred intent: `
EOF
)"
```

Note: creating a PR is visible to others. Confirm with the user before running.

- [ ] **Step 3: Wait for the user to review and merge the PR**

The bot reviewing this PR runs the OLD code (main), so its review will look unchanged — that's expected. The user reviews the diff manually, then merges.

After merge, `~/Hacking/knightwatch-reviewer/` is updated by whatever post-merge sync the user normally does (typically `cd ~/Hacking/knightwatch-reviewer && git pull`). Confirm the live tree is on the new commit:

```bash
git -C ~/Hacking/knightwatch-reviewer log --oneline -1
```

Expected: shows the merge commit / latest main commit including the new code.

- [ ] **Step 4: Trigger a review on an existing open PR (or wait for next tick)**

To trigger immediately, post `/review` on an open PR in any repo the bot watches:

```bash
gh pr comment <PR_NUM> --repo <owner/repo> --body "/review"
```

Or just wait for the next eligible PR change.

- [ ] **Step 5: Inspect the inferred-intent file from the most recent run**

```bash
ls -t ~/.pr-reviewer/last-run-scratch/ | head -3
LATEST=$(ls -t ~/.pr-reviewer/last-run-scratch/ | head -1)
cat ~/.pr-reviewer/last-run-scratch/$LATEST/inferred-intent.md
```

Expected: a 1–3 sentence statement starting with `Inferred intent: It appears @<author> is working towards …`.

- [ ] **Step 6: Inspect the posted review on the triggered PR**

```bash
gh pr view <PR_NUM> --repo <owner/repo> --json comments --jq '.comments[-1].body' | head -5
```

Expected: the first line is an italicized inferred-intent statement (with `Inferred intent: ` prefix stripped), followed by a blank line, followed by `**Overview** — …`.

- [ ] **Step 7: Sanity-check the architecture specialist's output**

```bash
cat ~/.pr-reviewer/last-run-scratch/$LATEST/specialists/architecture.md
```

Expected: the Surveyed section or one of the findings explicitly references the inferred intent — e.g., "given the inferred intent of X, this implementation does/does-not scale because…". This is qualitative — read for evidence the new context is being used.

- [ ] **Step 8: If something is off, iterate on prompts in a follow-up branch**

Common failure modes:
- Intent line is generic ("improving the reviewer") — sharpen the bad-examples list in `prompts/intent.md`.
- Aggregator forgets to strip the prefix — sharpen the formatting rule's example in `prompts/aggregator.md`.
- Architecture specialist still grades implementation in isolation — strengthen the spirit-vs-implementation bullet in `prompts/architecture.md`.

Open a follow-up PR with the prompt fixes; the bot now-running on main will exercise them on the next tick after merge.

---

## Self-Review

After all tasks are complete, before merge, run through this checklist:

1. **Spec coverage**
   - [ ] Component 1 (`prompts/intent.md`) → Task 6
   - [ ] Component 2 (pipeline step) → Task 7
   - [ ] Component 3 (`build_specialist_prompt` + `{{PR_AUTHOR}}`) → Tasks 2, 3, 4
   - [ ] Component 4 (`commits.md`) → Task 5
   - [ ] Component 5 wiring (common-header, architecture, aggregator) → Tasks 8, 9, 10
   - [ ] Component 6 (`CODING_STANDARDS.md`) → Task 11
   - [ ] Component 7 (testing) → Task 3 (unit smoke) + Task 12 (dogfood)

2. **Test coverage**
   - [ ] `just test` green at every commit (run after each task)
   - [ ] Dogfood pass shows: a valid `inferred-intent.md`, a posted review whose lead line is italicized, and architecture specialist output that references the intent

3. **No silent fallbacks**
   - [ ] Every new failure path is `log "..."; exit 1` with `preserve_scratch` + `rm -rf "$REPO_DIR"` cleanup
   - [ ] No `|| true`, no swallowed errors, no `(unavailable)` placeholders

4. **No unrelated changes**
   - [ ] Each commit's diff is scoped to the task; no opportunistic refactoring snuck in
