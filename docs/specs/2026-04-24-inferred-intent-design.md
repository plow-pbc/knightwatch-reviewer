# Inferred Intent — Design

**Status:** validated, ready for implementation plan
**Author:** Sam (with Claude)
**Date:** 2026-04-24

## Problem

The existing review pipeline evaluates *what the code does* but not *what end-user experience the developer is trying to deliver*. The architecture specialist already has the inputs to do spirit-vs-implementation critique — `author-intent.md` (PR title + body + linked issues), the diff, file history — but the PR description is often AI-written and misleading, and no upstream step does the work of triangulating intent across PR title, commit subjects, and the diff itself.

This means the architecture specialist evaluates the chosen implementation in isolation and misses the most valuable kind of feedback: *"the developer is trying to robustly classify any user's name; a lookup table will need a new branch every week — embeddings would scale in engineer-time at the cost of latency, and that's the right trade for our stage."*

## Goal

Add a pre-fan-out step that infers the developer's end-user-facing intent from PR title + commit subjects + diff, writes a tentative 1–3 line statement to `.codex-scratch/inferred-intent.md`, and feeds it to every downstream prompt (5 specialists + critic + aggregator) so they can grade implementation against intent. The aggregator surfaces the intent statement at the top of the posted review.

## Non-goals

- A new specialist that produces its own findings. Intent is *input*, not a finding-producer.
- Persistence in `state.json`. Re-infer every tick.
- Graceful degradation. Hard-fail on empty/error output, matching the codebase's existing pattern.
- Deep changes to the critic or aggregator beyond consuming the new file and surfacing the lead line.
- Modifying KID prior-art behavior.

## Design

### High-level flow

```
write scratch files (existing)
  ↓
[NEW] infer intent → write .codex-scratch/inferred-intent.md
  ↓
fan out 5 specialists in parallel (existing)
  ↓
critic pass (existing)
  ↓
aggregator (existing) — leads with intent line
```

The intent step runs **synchronously** between scratch-file preparation and fan-out. It blocks fan-out (specialists need the file present), but the wall-clock cost is one `codex exec` call at `model_reasoning_effort=high`.

### Component 1 — `prompts/intent.md` (new file)

A focused prompt with a tight scope. Inputs:

- `.codex-scratch/diff.patch` — the diff
- `.codex-scratch/author-intent.md` — PR title + body + linked issues
- `.codex-scratch/commits.md` (new — see Component 4) — the PR's commit subjects, one per line
- `.codex-scratch/file-history.md` — recent commits per touched file

Output: a single section, exactly:

```
Inferred intent: It appears @<author> is working towards <X> by <Y>.
```

Length: 1–3 sentences. Tone: tentative ("It appears…"). The prompt explicitly tells the model:

- The PR description may be AI-written and misleading. Trust the diff and commit subjects when they conflict with the PR body.
- State the **end-user-facing outcome** the developer is chasing, not what the code does mechanically. ("Letting users retry a failed payment without re-entering card details," not "Adds a `retry_payment` function.")
- Cite specifics from the diff or commits (file paths, function names, the user-facing surface that's changing) — generalities like "improving the auth system" are forbidden.
- If intent genuinely cannot be inferred (e.g. dependency bump, mechanical refactor with no user-facing implication), say so plainly: `Inferred intent: This PR has no inferable end-user-facing intent — it appears to be <category, e.g. dependency bump>.` That is a valid output, not a failure.

### Component 2 — pipeline step in `lib/review-one-pr.sh`

Insert between scratch-file writing (currently ends ~line 340 with `write_scratch ... author-intent.md`) and the fan-out loop (currently starts ~line 351). Pseudocode:

```bash
log "$PR_ID: inferring developer intent..."
INTENT_PROMPT=$(build_specialist_prompt "intent" \
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
    log "$PR_ID: intent inference failed (exit=$INTENT_EXIT, empty=$([ -s "$INTENT_OUT" ] || echo true)) — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
log "$PR_ID: intent inference complete"
```

Validation: the file must be non-empty AND must start with the literal prefix `Inferred intent:`. If the prefix is missing, hard-fail — that's how we keep the format contract. (If the model emits a preamble, it's a bug in the prompt, not something to paper over.)

### Component 3 — `build_specialist_prompt` extended for `{{PR_AUTHOR}}`

Add a 6th positional arg. Update the function:

```bash
build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5" pr_author="$6"
    # ... existing escaping ...
    local esc_author=$(safe_sed "$pr_author")
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

`PR_AUTHOR` is fetched from the existing `gh pr view` call by extending the `--json` field list to include `author`:

```bash
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,author,closingIssuesReferences ...)
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
[ -z "$PR_AUTHOR" ] && { log "$PR_ID: could not resolve PR author — aborting"; exit 1; }
```

Hard-fail if the author handle can't be resolved. Every existing call site of `build_specialist_prompt` (intent, 5 specialists, aggregator) gets the new `PR_AUTHOR` argument.

### Component 4 — new scratch file `commits.md`

Source the commit list from GitHub directly so we get the canonical PR-included commits regardless of base branch (`git log DEFAULT_BRANCH..HEAD` would over-include for stacked / non-main-targeting PRs). Extend the existing `gh pr view` call's `--json` fields to include `commits`, then format:

```bash
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,author,commits,closingIssuesReferences ...)
COMMITS=$(printf '%s' "$PR_DATA" | jq -r '.commits[] | "\(.oid[0:7]) \(.messageHeadline)"')
[ -z "$COMMITS" ] && { log "$PR_ID: gh pr view returned no commits — aborting"; exit 1; }
write_scratch "$REPO_DIR" "commits.md" "$COMMITS"
```

Plain text, one commit per line: `<7-char-sha> <subject>`. Hard-fail if empty (a PR with zero commits is degenerate). Used primarily by the intent step but available to all specialists.

### Component 5 — wiring into existing prompts

Three small additions:

#### `prompts/common-header.md`

Add a bullet to the "Inputs already prepared for you" list:

```
- `.codex-scratch/inferred-intent.md` — a tentative statement of the end-user experience this PR is working toward, derived from title + commits + diff. Use this to evaluate whether the chosen approach actually delivers on that intent, especially in architecture/simplification reviews.
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line.
```

#### `prompts/architecture.md` — new bullet under Scope

```markdown
- **Spirit-vs-implementation.** Read `.codex-scratch/inferred-intent.md`. Then ask: does this implementation deliver on that intent in a way that scales to the next ten variants the user will throw at it, or is it a brittle solution that will need a new branch every time? Look for seams that eliminate special cases and conditional sprawl. Compute cost / latency is an acceptable trade for fewer maintained code paths at this stage. Cite the standards: Fail-Fast, Concise Code, Reframe the Spec, Narrow-Fix.
```

Also tighten the existing "Over-engineering for this stage" line so it does not get cited to reject exactly the spirit-vs-implementation suggestions this feature is designed to surface. Replace:

> Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do.

with:

> Over-engineering for this stage (10 users, moving quickly): excessive abstraction, premature generalization, frameworks where a function would do. **Note:** "more compute / more latency to delete a class of special cases" is *not* over-engineering — it is the trade we want at this stage. The thing being optimized is engineer-hours, not CPU.

#### `prompts/aggregator.md` — two changes

1. Add to "Inputs":
   ```
   - `.codex-scratch/inferred-intent.md` — pre-fan-out inferred end-user intent. Lead the posted review with this line.
   - `.codex-scratch/commits.md` — commit subjects on this branch.
   ```

2. Update the "Produce the final posted review in EXACTLY this structure" template — the new first line is the inferred intent in italics, then a blank line, then the existing structure:

   ```
   _<intent line, italicized — see formatting rule below>_

   **Overview** — 2-3 sentences on what the PR does.

   **Strengths** — ...
   ...
   ```

   **Formatting rule** (in the aggregator prompt, explicit): take the contents of `.codex-scratch/inferred-intent.md`, strip the literal `Inferred intent: ` prefix, then append ` — reviewing against that goal.` if the result does not already end with a similar clause. Wrap in single underscores for italics. Result:

   ```
   _It appears @plucas is working towards letting users retry failed payments without re-entering card details by adding a `retry_payment` endpoint and surfacing it in the failure UI — reviewing against that goal._
   ```

   The `Inferred intent: ` prefix is internal scaffolding for validation in `lib/review-one-pr.sh`; it should never appear in the posted review. The aggregator does NOT re-infer or paraphrase the intent — it copies, strips the prefix, and italicizes.

### Component 6 — `CODING_STANDARDS.md` additions

Two surgical adds, signed off by user. These live in `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` (the canonical source for `~/.claude/CODING_STANDARDS.md`).

**Add to `Team Context`, after the "Concise code that fails loudly" bullet:**

```markdown
- **Engineer time > compute time.** When picking between approaches, prefer the one that scales in *engineers' time* — fewer special cases, fewer conditional branches, fewer files to touch when the next variant lands. A solution that costs more compute or runs slower is fine if it eliminates a class of code we'd otherwise have to maintain. Lookup tables, hand-coded heuristics, and per-case branches are brittle in a way the bill-of-materials never reflects.
```

**Add to `Concise Code (LOC is a cost)`, as a new bullet:**

```markdown
- Every conditional is a maintenance burden — all things equal, avoid it. Each `if`/`else` branch is a state the next reader has to hold and the next change has to update. When you find yourself adding a special case, ask whether a different seam would let you delete it instead.
```

These reinforce each other: the first names the optimization target (engineer time), the second names the proxy metric (conditional count).

### Component 7 — testing

The repo already has `lib/tests/` and a `state-io.sh` smoke test invoked by `just test`. The intent step changes the wire format between `lib/review-one-pr.sh` and the prompt files, plus adds a new scratch file.

**Tests to add** (concrete list owned by the implementation plan, not the spec):

1. `lib/tests/intent-prompt-build.sh` — verify `build_specialist_prompt` correctly substitutes `{{PR_AUTHOR}}` for the new placeholder and leaves no unsubstituted `{{...}}` markers.
2. `lib/tests/intent-output-validation.sh` — given a mock `inferred-intent.md` that does NOT start with `Inferred intent:`, verify the validation step in `lib/review-one-pr.sh` aborts with the expected log line. Given a valid file, verify it passes.
3. `lib/tests/commits-md.sh` — verify `commits.md` is written with `git log --format='%h %s' DEFAULT_BRANCH..HEAD` content for a synthetic repo.

Each test follows the existing smoke-test pattern: spin up an isolated `STATE_DIR` via `mktemp`, invoke the relevant script, assert on output, clean up. No mocking of `codex exec` — the validation tests use a pre-written intent file as fixture rather than calling codex.

End-to-end test: dogfood on a real PR by running `~/.pr-reviewer/review.sh` against this repo's own next PR (the one that lands this design). Inspect `~/.pr-reviewer/last-run-scratch/srosro_knightwatch-reviewer__N/inferred-intent.md` for the actual model output.

## What this design deliberately does *not* do

- **No persistence in `state.json`.** Re-infer every tick. New commits can shift intent.
- **No new specialist.** Intent is input, not a finding-producer.
- **No fallback file / placeholder.** Hard-fail on empty/malformed output, per the codebase's existing pattern and the user's general "always fail hard" rule.
- **No changes to KID, critic flow, or systemd unit.** This is purely a `lib/review-one-pr.sh` + prompts change.
- **No backwards-compatibility shim** for the new `{{PR_AUTHOR}}` placeholder. All existing prompts that go through `build_specialist_prompt` are updated in the same change.

## Open questions

None. All operational calibration (reasoning effort, failure mode, re-review behavior, output structure) was settled during brainstorming.
