# Go-Deep Tech Leads Implementation Plan

> **POST-IMPLEMENTATION ARCHIVE — read source for current behavior.** This plan was the implementation guide; the merged code in `lib/{decline-history,critic-splitter,go-deep-rank,orchestrate}.sh`, `prompts/go-deep.md`, `prompts/critic.md`, and `prompts/aggregator.md` is now the source of truth. Code blocks below match the original plan and have drifted in spots (e.g. `OPERATOR_NAME` → `BOT_USER`, `build_specialist_prompt` → `substitute_placeholders` for go-deep, fail-loud abort on go-deep failure, decline-history sentinel on /srosro-review and first reviews). Do not consume code blocks here as authoritative; consult source files. The high-level task structure remains useful as historical context for why the architecture is shaped the way it is.
>
> Architectural source of truth: `docs/specs/2026-05-02-go-deep-tech-leads-design.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Phase 1 (decline-history awareness + critic generates calibration questions for ≥20 LOC findings + critic-splitter co-locates critic output in specialist files) and Phase 2 (go-deep tech-leads fan-out, ≤3 parallel) per `docs/specs/2026-05-02-go-deep-tech-leads-design.md`.

**Architecture:** Orchestrator (`lib/review-one-pr.sh`) gains a `fetch_decline_history` step before specialist fan-out, a `split_critic_to_specialists` step after the critic, and a `rank_top_findings` + `fan_out_go_deep` step after the splitter (Phase 2). The critic prompt gains decline-history awareness + per-finding remedy-LOC estimate + calibration-question generation. A new `prompts/go-deep.md` is instantiated up to 3× via the existing `build_specialist_prompt` + `run-specialist.sh` seam (no interface changes needed — `build_specialist_prompt` accepts an arbitrary prompt-file path).

**Tech Stack:** bash 5, codex CLI, gh CLI, jq, awk, gnu sed.

---

## File Structure

**Created:**
- `lib/decline-history.sh` (~80 LOC) — `fetch_decline_history` helper
- `lib/critic-splitter.sh` (~50 LOC) — `split_critic_to_specialists` helper
- `prompts/go-deep.md` (~80 LOC) — go-deep tech-lead specialist template
- `lib/tests/decline-history-smoke.sh` (~80 LOC)
- `lib/tests/critic-splitter-smoke.sh` (~70 LOC)
- `lib/tests/go-deep-fanout-smoke.sh` (~50 LOC)

**Modified:**
- `prompts/critic.md` — read decline-history; drop/footnote re-decline findings; estimate remedy LOC; generate calibration questions for ≥20 LOC findings
- `prompts/aggregator.md` — note layered specialist files; integrate KEEP/SIMPLIFY-WITH-PATTERN/DROP/REFRAME
- `lib/review-one-pr.sh` — wire decline-history fetch, critic-splitter, ranker, go-deep fan-out
- `lib/tests/anti-bloat-contract-smoke.sh` — token-level fences for new content
- `justfile` — wire 3 new smokes
- `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` — § 20-LOC remedy threshold sub-rule under § Broken-Glass Test
- `prompts/simplification.md` — drop kid-prior-art role (Phase 2 simplification, ~-15 LOC)

---

## Phase 1 — foundation

### Task 1: § 20-LOC remedy threshold rule in vibe-engineering CODING_STANDARDS.md

**Files:**
- Modify: `~/Hacking/vibe-engineering/claude-config/CODING_STANDARDS.md` (under § Broken-Glass Test)

This task lives in a sibling repo. Branch + commit + push + open PR there.

- [ ] **Step 1.1: Branch in vibe-engineering**

```bash
cd ~/Hacking/vibe-engineering
git checkout main && git pull --ff-only
git checkout -b feat/20-loc-remedy-threshold
```

- [ ] **Step 1.2: Add § 20-LOC remedy threshold sub-rule**

Find the existing `## Broken-Glass Test` heading; append a new subsection at the end of that section (before the next H2):

```markdown
### 20-LOC remedy threshold

When a proposed remedy adds more than ~20 LOC, the reviewer must explicitly answer three questions before raising the finding as `medium` or higher:

1. **Will this affect our core product and help us find PMF?** Or is this covering an edge case?
2. **If covering an edge case:** is there a simpler contract or infrastructure (a single-shape, fail-loud seam) that catches this AND other future edge cases for free? If yes, propose the contract instead of the local handler.
3. **If neither (1) nor (2):** is the complexity worth it, given (a) the repo's `.knightwatch/review-priority.md` operating point (e.g. ~10 users won't experience the edge case at our current scale), and (b) the LOC cost slows down PMF iteration?

Default when (1)+(2)+(3) all fail: **ship simple-and-fail-loud**, not elegant-defensive-coverage. We want simple, elegant code with some broken glass that fails loudly — the cost of a calcified branch outweighs the cost of a loud crash the operator can investigate.
```

- [ ] **Step 1.3: Commit + push + open PR**

```bash
cd ~/Hacking/vibe-engineering
git add claude-config/CODING_STANDARDS.md
git commit -m "$(cat <<'EOF'
standards: 20-LOC remedy threshold under § Broken-Glass Test

Operationalizes the calibration discipline: any finding whose remedy
adds >~20 LOC must answer (1) PMF impact, (2) simpler-contract
alternative, (3) operating-point worth. Default when all three fail:
ship simple-and-fail-loud.

Loadbearing for kw-reviewer's go-deep tech-leads work — critic
generates calibration questions for ≥20 LOC findings; go-deep
investigates them deeply.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
git push -u origin feat/20-loc-remedy-threshold
gh pr create --title "standards: 20-LOC remedy threshold under § Broken-Glass Test" --body "Operationalizes the calibration discipline for kw-reviewer's go-deep tech-leads work. See ~/Hacking/knightwatch-reviewer/docs/specs/2026-05-02-go-deep-tech-leads-design.md."
```

Cite the resulting PR URL in the kw-reviewer PR.

---

### Task 2: lib/decline-history.sh + smoke

**Files:**
- Create: `lib/decline-history.sh`
- Create: `lib/tests/decline-history-smoke.sh`

- [ ] **Step 2.1: Write the failing smoke**

Create `lib/tests/decline-history-smoke.sh`:

```bash
#!/bin/bash
# Smoke for fetch_decline_history (lib/decline-history.sh).
#
# Contracts:
#   1. With no operator replies: emits "(no decline history)" sentinel.
#   2. With a single decline match: emits the class header + last decline reason.
#   3. With N>=2 declines on the same class: emits "declined N rounds" with
#      first-flagged + last-flagged anchors.
#   4. Free-form pushback (operator's own words, no template) is captured
#      as class="(unclassified)" with the verbatim reason.

set -uo pipefail

TMPDIR=$(mktemp -d -t decline-history-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/decline-history.sh"

# --- fixture 1: empty comments ---
EMPTY_OUT=$(_decline_history_from_json '[]')
echo "$EMPTY_OUT" | grep -qF "(no decline history)" || { echo "FAIL: empty case"; exit 1; }

# --- fixture 2: one Bug-Class-Recurrence + one Counter-propose ---
SAMPLE=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-04-30T12:00:00Z","body":"Declined — conflicts with Fail-Fast in standards.md. The session-scoping finding is documented design intent (testFinishKeepsLaunchPhaseLaunching)."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T08:00:00Z","body":"Declined again — same session-scoping. Documented in tests; not changing without spec."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T10:00:00Z","body":"Counter-proposed — applied LOC-negative version. Removed the redundant validation."}
]
JSON
)

OUT=$(_decline_history_from_json "$SAMPLE")
echo "$OUT" | grep -qF "session-scoping" || { echo "FAIL: missing session-scoping class"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "declined 2 rounds" || { echo "FAIL: missing 2-round count"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "Counter-proposed" || { echo "FAIL: missing Counter-proposed entry"; echo "$OUT"; exit 1; }

echo "  PASS"
```

Run: `bash lib/tests/decline-history-smoke.sh`
Expected: FAIL with "lib/decline-history.sh: No such file"

- [ ] **Step 2.2: Implement lib/decline-history.sh**

```bash
#!/bin/bash
# Sourceable helper for fetching and classifying operator decline replies
# from a PR's comment thread. Output is fed to the critic prompt as
# .codex-scratch/decline-history.md so re-flagged findings the operator
# has already declined ≥3 times can be dropped or footnoted.
#
# fetch_decline_history REPO PR_NUM STATE_DIR
#   stdout: markdown decline-history.md content
#
# Class identification heuristics (conservative — under-classify is fine,
# over-classify drops findings the operator might still want flagged):
#   1. Babysit-pr templates: "Declined — conflicts with <rule>",
#      "Counter-proposed", "Applied in <SHA>". The class token is
#      extracted from the operator's reply prose — first noun-phrase
#      after "the <X> finding" / "<X>:" header, fall back to "(unclassified)".
#   2. [Bug-Class-Recurrence] tags from prior bot reviews (ours): the
#      class label inside the brackets is the canonical class name.
#
# Empty / absent output is fail-soft (the critic just sees "(no decline
# history)" — no decline information available, fall back to existing
# behavior).

_DECLINE_HISTORY_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_DECLINE_HISTORY_LIB_DIR/gh-comments.sh"

# Internal: take a JSON array of comments on stdin (or arg), emit
# decline-history.md content. Pure transform — no gh calls — so the
# smoke can drive it directly with synthetic fixtures.
_decline_history_from_json() {
    local raw="$1"
    if [ -z "$raw" ] || [ "$raw" = "null" ] || [ "$raw" = "[]" ]; then
        echo "(no decline history)"
        return 0
    fi

    # Filter for operator (srosro) comments matching decline templates.
    # OPERATOR env var override mirrors the OPERATOR_NAME pattern in
    # prompt-build.sh, so a fork can re-skin without editing this file.
    local operator="${OPERATOR_NAME:-srosro}"
    local declines counters
    declines=$(printf '%s' "$raw" | jq --arg op "$operator" -r '
        map(select(.user.login == $op))
        | map(select(.body | test("Declined —|Declined -|^Declined |\\[Bug-Class-Recurrence\\]")))
        | map({ts: .created_at, body: .body})
        | sort_by(.ts)
        | .[]
        | "\(.ts)\t\(.body | gsub("\n"; " ") | .[:400])"
    ' 2>/dev/null)
    counters=$(printf '%s' "$raw" | jq --arg op "$operator" -r '
        map(select(.user.login == $op))
        | map(select(.body | test("Counter-proposed")))
        | map({ts: .created_at, body: .body})
        | sort_by(.ts)
        | .[]
        | "\(.ts)\t\(.body | gsub("\n"; " ") | .[:400])"
    ' 2>/dev/null)

    if [ -z "$declines" ] && [ -z "$counters" ]; then
        echo "(no decline history)"
        return 0
    fi

    echo "# Decline history"
    echo
    echo "Operator ($operator) replies on prior reviews of this PR:"
    echo

    # Group declines by class. Class extraction: first match in this order:
    #   1. [Bug-Class-Recurrence] <class>
    #   2. "the <noun>-<noun>" / "<noun>-<noun> finding"
    #   3. fall back to "(unclassified)"
    declare -A class_count class_first class_last class_reason
    while IFS=$'\t' read -r ts body; do
        [ -z "$body" ] && continue
        local class=""
        if [[ "$body" =~ \[Bug-Class-Recurrence\][[:space:]]*([A-Za-z][A-Za-z0-9_-]+) ]]; then
            class="${BASH_REMATCH[1]}"
        elif [[ "$body" =~ ([a-z][a-z]+-[a-z][a-z]+)[[:space:]]+finding ]]; then
            class="${BASH_REMATCH[1]}"
        elif [[ "$body" =~ (session-scoping|stale-auth|atomicity|parsing|dispatch|retry|validation|error-envelope|race) ]]; then
            class="${BASH_REMATCH[1]}"
        else
            class="(unclassified)"
        fi
        class_count[$class]=$(( ${class_count[$class]:-0} + 1 ))
        [ -z "${class_first[$class]:-}" ] && class_first[$class]="$ts"
        class_last[$class]="$ts"
        class_reason[$class]="$body"
    done <<< "$declines"

    local class
    for class in "${!class_count[@]}"; do
        echo "## Class: $class (declined ${class_count[$class]} round$([ "${class_count[$class]}" -gt 1 ] && echo s))"
        echo "- First declined: ${class_first[$class]}"
        echo "- Last declined: ${class_last[$class]}"
        echo "- Last decline reason: \"${class_reason[$class]}\""
        echo
    done

    if [ -n "$counters" ]; then
        echo "## Counter-proposed (applied LOC-negative or branch-negative version)"
        while IFS=$'\t' read -r ts body; do
            [ -z "$body" ] && continue
            echo "- $ts: $body"
        done <<< "$counters"
        echo
    fi
}

# Public entry point. Calls gh, then delegates to the pure-transform helper.
fetch_decline_history() {
    local repo="$1" pr_num="$2"
    local issue_comments inline_comments combined
    if ! issue_comments=$(fetch_issue_comments "$repo" "$pr_num"); then
        echo "(decline history unavailable — gh fetch failed)"
        return 0
    fi
    # Inline review-thread comments live at a different endpoint.
    inline_comments=$(gh api --paginate "repos/${repo}/pulls/${pr_num}/comments" 2>/dev/null | jq -s 'add // []' || echo '[]')
    combined=$(jq -n --argjson a "$issue_comments" --argjson b "$inline_comments" '$a + $b')
    _decline_history_from_json "$combined"
}
```

- [ ] **Step 2.3: Run smoke; expect PASS**

```bash
bash lib/tests/decline-history-smoke.sh
```
Expected: `PASS`

- [ ] **Step 2.4: Commit**

```bash
git add lib/decline-history.sh lib/tests/decline-history-smoke.sh
git commit -m "feat: lib/decline-history.sh — fetch + classify operator declines"
```

---

### Task 3: Wire decline-history fetch in lib/review-one-pr.sh

**Files:**
- Modify: `lib/review-one-pr.sh` (add fetch + write_scratch call before specialist fan-out)

- [ ] **Step 3.1: Source helper near other lib sources**

Find the other `. "$_LIB_DIR/<helper>.sh"` lines in `lib/review-one-pr.sh` (search around line 80-130). Add:

```bash
. "$_LIB_DIR/decline-history.sh"
```

- [ ] **Step 3.2: Wire fetch + write_scratch**

After the `loc-trend.md` write_scratch call (around line 1016, just before `FILE_HISTORY=""`), insert:

```bash
# decline-history.md — operator declines from prior review comments,
# so the critic can drop or footnote findings the operator has already
# pushed back on ≥3 times. Empty/absent on first reviews and on PRs
# with no operator pushback. Fail-soft on gh-failure (helper emits a
# sentinel; critic falls back to existing behavior).
DECLINE_HISTORY=$(fetch_decline_history "$REPO" "$PR_NUM")
write_scratch "$REPO_DIR" "decline-history.md" "$DECLINE_HISTORY"
```

- [ ] **Step 3.3: Syntax check**

```bash
bash -n lib/review-one-pr.sh
```
Expected: clean exit.

- [ ] **Step 3.4: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "feat: wire decline-history fetch before critic"
```

---

### Task 4: prompts/critic.md — read decline-history; estimate remedy LOC; generate calibration questions

**Files:**
- Modify: `prompts/critic.md`

- [ ] **Step 4.1: Add decline-history input to the inputs list**

After the `.codex-scratch/prior-reviews.md` line in the inputs section, append:

```
- `.codex-scratch/decline-history.md` — operator's prior decline replies on this PR. If a finding-class appears here ≥3 times, drop it (footnote only); if 1-2 times, keep but cite the operator's prior reasoning + ask whether the new commit affects the prior decline.
```

- [ ] **Step 4.2: Add decline-history handling section**

After the existing **Pre-PMF lens (conditional)** paragraph, insert:

```markdown
**Decline-history awareness.** For each surviving finding, check whether its class matches any in `.codex-scratch/decline-history.md`:
- **Declined ≥3 rounds:** drop from the published findings; emit one-line footnote *"Class 'X' has been declined N rounds; see decline-history.md. Not re-raising."*
- **Declined 1-2 rounds:** keep but cite the operator's prior reasoning AND ask whether this commit's diff materially changes the prior decline (if yes — keep at original severity; if no — REFRAME-AS-QUESTION with the prior decline reason as the cost-naming).
- **No prior declines:** existing handling.
```

- [ ] **Step 4.3: Add remedy-LOC estimate + calibration question generation**

After the `**Output format — exactly this:**` block's existing per-specialist `### [...] Finding N — <status>` description, add this subsection BEFORE the `## Missed findings (if any)` section:

```markdown
**For each surviving finding, append after your 1-3 line counterargument:**

```
**Estimated remedy LOC:** ~N LOC across M files.
```

Estimate by counting `+` lines in any code blocks the specialist proposed; fall back to "if the finding cites K files, estimate K×20 LOC."

**For findings ≥20 LOC remedy:** generate 1-2 calibration questions targeting the cultural lens from `standards.md` § Broken-Glass Test → 20-LOC remedy threshold. Pattern (LLM generates per-finding, NOT templated):

```
**Calibration questions for go-deep investigation:**
- Q1: <will users at <operating-point> hit this state? cite firing-rate evidence if available, or "no observed instances">
- Q2: <is there a similar pattern in <path/to/lib.sh> or another existing seam we could reuse to avoid adding N LOC?>
```

The calibration questions ladder up to: *"Is the additional complexity of addressing this issue worth the cost of slowing down PMF iteration?"* (from § Broken-Glass Test). For findings <20 LOC remedy, omit the calibration block entirely.
```

- [ ] **Step 4.4: Lint check (token sanity)**

```bash
grep -F "decline-history.md" prompts/critic.md
grep -F "Estimated remedy LOC" prompts/critic.md
grep -F "Calibration questions for go-deep" prompts/critic.md
```
Expected: each grep emits a line.

- [ ] **Step 4.5: Commit**

```bash
git add prompts/critic.md
git commit -m "feat(critic): decline-history awareness + remedy-LOC estimate + calibration questions"
```

---

### Task 5: lib/critic-splitter.sh + smoke

**Files:**
- Create: `lib/critic-splitter.sh`
- Create: `lib/tests/critic-splitter-smoke.sh`

- [ ] **Step 5.1: Write the failing smoke**

Create `lib/tests/critic-splitter-smoke.sh`:

```bash
#!/bin/bash
# Smoke for split_critic_to_specialists (lib/critic-splitter.sh).
#
# Contracts:
#   1. Per-angle [<angle>] sections in critic.md are appended to the
#      corresponding specialists/<angle>.md file under a "## Critic
#      counter-arguments" H2 (so the layered file flows specialist-then-critic).
#   2. The "## Missed findings" section from critic.md is preserved
#      and appended to a designated "missed" sink (specialists/missed.md).
#   3. Missing specialist file for a section that the critic produced is
#      a fail-soft warn (log line; don't abort) — handles a future angle
#      removed without prompt sync.
#   4. Each specialists/<angle>.md keeps its original "## [<angle>] findings"
#      section UNCHANGED ahead of the critic block (specialist's own write).

set -uo pipefail

TMPDIR=$(mktemp -d -t critic-splitter-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/critic-splitter.sh"

SPECIALISTS_DIR="$TMPDIR/specialists"
mkdir -p "$SPECIALISTS_DIR"

# --- fixture: synthesize specialist files ---
cat > "$SPECIALISTS_DIR/security.md" <<'EOF'
## [security] findings

### Surveyed
- looked at auth code
### Finding 1 — medium
sql injection in `app/api.py:42`.
EOF
cat > "$SPECIALISTS_DIR/architecture.md" <<'EOF'
## [architecture] findings

### Surveyed
- nothing notable
EOF

# --- fixture: synthesize critic.md ---
CRITIC="$TMPDIR/critic.md"
cat > "$CRITIC" <<'EOF'
## Critic counterarguments

### [security] Finding 1 — AGREE
Real injection, fix is bind-param.
**Estimated remedy LOC:** ~5 LOC across 1 file.

### [architecture] Finding 1 — REFRAME-AS-QUESTION
Specialist found nothing structural.

## Missed findings (if any)
- [low] missing CSP header.
EOF

split_critic_to_specialists "$CRITIC" "$SPECIALISTS_DIR"

grep -qF "## Critic counter-arguments" "$SPECIALISTS_DIR/security.md" || { echo "FAIL: missing critic block in security.md"; cat "$SPECIALISTS_DIR/security.md"; exit 1; }
grep -qF "Real injection" "$SPECIALISTS_DIR/security.md" || { echo "FAIL: critic content not in security.md"; exit 1; }
grep -qF "## [security] findings" "$SPECIALISTS_DIR/security.md" || { echo "FAIL: original specialist content lost in security.md"; exit 1; }
grep -qF "missing CSP" "$SPECIALISTS_DIR/missed.md" || { echo "FAIL: missed findings not captured"; exit 1; }

echo "  PASS"
```

Run: `bash lib/tests/critic-splitter-smoke.sh`
Expected: FAIL with "lib/critic-splitter.sh: No such file or directory"

- [ ] **Step 5.2: Implement lib/critic-splitter.sh**

```bash
#!/bin/bash
# Sourceable helper for splitting critic.md by [<angle>] sections and
# appending each section to the corresponding specialists/<angle>.md
# file. Output is the layered specialist file (specialist findings +
# critic counter-arguments) — single writer per phase per file, no
# race (orchestrator runs this synchronously after the critic completes
# and before the aggregator).
#
# split_critic_to_specialists CRITIC_MD SPECIALISTS_DIR
#   reads:  $CRITIC_MD
#   writes: $SPECIALISTS_DIR/<angle>.md (appends a "## Critic counter-arguments"
#           block per angle), $SPECIALISTS_DIR/missed.md (the "## Missed
#           findings" section if present)

split_critic_to_specialists() {
    local critic_md="$1" specialists_dir="$2"
    if [ ! -s "$critic_md" ]; then
        echo "split_critic_to_specialists: $critic_md missing or empty — nothing to split" >&2
        return 0
    fi
    if [ ! -d "$specialists_dir" ]; then
        echo "split_critic_to_specialists: $specialists_dir does not exist" >&2
        return 1
    fi

    # Pass 1: walk the critic file, accumulate per-angle blocks via awk.
    # Sections start with `### [<angle>] Finding N` and continue until
    # the next `###`, `##`, or EOF. Special section "Missed findings"
    # routes to specialists/missed.md.
    awk -v out_dir="$specialists_dir" '
        function flush() {
            if (current_angle != "" && buf != "") {
                f = out_dir "/" current_angle ".angle-buf"
                printf("%s", buf) >> f
                close(f)
                buf = ""
            }
            if (in_missed && missed_buf != "") {
                f = out_dir "/missed.md"
                printf("%s", missed_buf) >> f
                close(f)
                missed_buf = ""
            }
        }
        # Entry into per-angle finding section
        /^### \[[a-z][a-z-]*\] Finding/ {
            flush()
            in_missed = 0
            match($0, /^### \[([a-z][a-z-]*)\]/, m)
            current_angle = m[1]
            buf = $0 "\n"
            next
        }
        # Entry into Missed findings section
        /^## Missed findings/ {
            flush()
            current_angle = ""
            in_missed = 1
            missed_buf = $0 "\n"
            next
        }
        # Other H2s end any in-progress section
        /^## / {
            flush()
            current_angle = ""
            in_missed = 0
            next
        }
        # Body lines accumulate to whichever section is active
        {
            if (current_angle != "") buf = buf $0 "\n"
            else if (in_missed)      missed_buf = missed_buf $0 "\n"
        }
        END { flush() }
    ' "$critic_md"

    # Pass 2: for each .angle-buf produced, append to the corresponding
    # specialist file under a "## Critic counter-arguments" H2. Skip
    # angles whose specialist file is missing (warn, don't abort —
    # downstream aggregator already tolerates absent angles).
    local f angle target
    for f in "$specialists_dir"/*.angle-buf; do
        [ -e "$f" ] || continue
        angle=$(basename "$f" .angle-buf)
        target="$specialists_dir/${angle}.md"
        if [ ! -f "$target" ]; then
            echo "split_critic_to_specialists: no specialist file for [$angle] — skipping" >&2
            rm -f "$f"
            continue
        fi
        # The specialists/<angle>.md is currently a symlink to the agent's
        # output.md. We replace it with a real file (concat original +
        # critic block) so layered reads downstream see the combined view.
        local original
        original=$(cat "$target")
        rm -f "$target"
        {
            printf '%s\n\n---\n\n## Critic counter-arguments\n\n' "$original"
            cat "$f"
        } > "$target"
        rm -f "$f"
    done
}
```

- [ ] **Step 5.3: Run smoke; expect PASS**

```bash
bash lib/tests/critic-splitter-smoke.sh
```
Expected: `PASS`

- [ ] **Step 5.4: Commit**

```bash
git add lib/critic-splitter.sh lib/tests/critic-splitter-smoke.sh
git commit -m "feat: lib/critic-splitter.sh — co-locate critic output in specialist files"
```

---

### Task 6: Wire critic-splitter in lib/review-one-pr.sh

**Files:**
- Modify: `lib/review-one-pr.sh`

- [ ] **Step 6.1: Source the helper**

Near the other `. "$_LIB_DIR/<helper>.sh"` lines, add:

```bash
. "$_LIB_DIR/critic-splitter.sh"
```

- [ ] **Step 6.2: Call splitter after critic completes**

Find the existing block (around line 1227-1228):

```bash
critic_fallback "$CRITIC_EXIT" "$CRITIC_OUT"
ln -sfn "$CRITIC_OUT" "$REPO_DIR/.codex-scratch/critic.md"
```

After `ln -sfn ...`, append:

```bash
# Split the critic's per-finding output by [<angle>] section and append
# each section to the corresponding specialists/<angle>.md, so the
# aggregator + go-deep tech-leads see a single layered file per
# specialist (specialist findings → critic counter-arguments). Single
# writer per phase per file — no race. Fail-soft (logs per-angle
# warnings; never aborts the review).
log "$PR_ID: splitting critic output into specialist files..."
split_critic_to_specialists "$CRITIC_OUT" "$SPECIALISTS_DIR" 2>>"$LOG_FILE" || true
```

- [ ] **Step 6.3: Syntax check + commit**

```bash
bash -n lib/review-one-pr.sh
git add lib/review-one-pr.sh
git commit -m "feat: wire critic-splitter after critic completes"
```

---

### Task 7: anti-bloat-contract-smoke + justfile wire (Phase 1)

**Files:**
- Modify: `lib/tests/anti-bloat-contract-smoke.sh`
- Modify: `justfile`

- [ ] **Step 7.1: Add token assertions for new critic content**

In `lib/tests/anti-bloat-contract-smoke.sh`, add near the existing critic.md assertions:

```bash
echo "  asserting decline-history input in critic.md..."
assert_grep "critic.md should reference decline-history.md" \
    "decline-history.md" prompts/critic.md

echo "  asserting remedy-LOC estimate contract in critic.md..."
assert_grep "critic.md should fence Estimated remedy LOC token" \
    "Estimated remedy LOC" prompts/critic.md

echo "  asserting calibration-question contract in critic.md..."
assert_grep "critic.md should fence Calibration questions for go-deep token" \
    "Calibration questions for go-deep" prompts/critic.md
```

- [ ] **Step 7.2: Wire 2 new smokes in justfile**

After the existing momentum-wire smoke block, add:

```
    echo ""
    echo "=== decline-history smoke ==="
    bash lib/tests/decline-history-smoke.sh

    echo ""
    echo "=== critic-splitter smoke ==="
    bash lib/tests/critic-splitter-smoke.sh
```

- [ ] **Step 7.3: Run anti-bloat smoke + commit**

```bash
bash lib/tests/anti-bloat-contract-smoke.sh
git add lib/tests/anti-bloat-contract-smoke.sh justfile
git commit -m "test: token-level fences for Phase 1 critic extensions + wire smokes"
```

---

## Phase 2 — go-deep tech-leads

### Task 8: prompts/go-deep.md

**Files:**
- Create: `prompts/go-deep.md`

- [ ] **Step 8.1: Write the prompt template**

Create `prompts/go-deep.md`:

```markdown
You are a go-deep tech-lead investigating ONE specialist's high-LOC findings on a PR. Up to 3 instances of you run in parallel, each assigned to a different specialist file. Your output is appended to the assigned specialist file under a `## Go-deep tech-lead investigation` section; the aggregator integrates your recommendations into the published review.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**URL:** {{PR_URL}}
**Specialist:** {{SPECIALIST_NAME}}

**Voice posture (load-bearing):** Apply `standards.md` § Broken-Glass Test → 20-LOC remedy threshold. Your recommendations must answer:
1. Will users at the operating-point hit this state? (cite firing-rate evidence)
2. Is there a simpler contract / existing pattern we can reuse?
3. Is the complexity worth slowing down PMF iteration?

Default when all three fail: recommend `REFRAME` (move to Open Questions with cost-naming) or `DROP`. We want simple, elegant code with some broken glass that fails loudly.

**Operating point (READ FIRST):** Read `.codex-scratch/review-priority.md` for the per-repo stage, cultural emphasis, and operating point. The repo's stage drives your calibration math.

**Inputs:**
- `.codex-scratch/specialists/{{SPECIALIST_NAME}}.md` — your assigned specialist's findings + the critic's counter-arguments + calibration questions (already layered by the orchestrator's critic-splitter step).
- `.codex-scratch/review-priority.md` — operating point.
- `.codex-scratch/decline-history.md` — operator's prior decline replies on this PR.
- `.codex-scratch/inferred-intent.md` — pre-fan-out inferred end-user-facing intent.
- `.codex-scratch/diff.patch` — the change under review.
- `.codex-scratch/standards.md` — universal Broken-Glass policy + 20-LOC remedy threshold.
- Full repo access (`grep -rn`, `git log`, `cat`) — investigate freely; this is your distinguishing capability.

**Your job:** for EACH finding in your assigned specialist file that has a critic-supplied calibration question block, produce a deep investigation:

1. **Answer each calibration question** with concrete evidence (path:line, git-log output, test assertion, decline-history reference). Confidence: high / medium / low.
2. **Search for existing patterns** that could simplify the proposed remedy:
   - `grep -rn` for similar shapes already in the codebase (helpers, factories, single-owner seams).
   - `git log -p --since='90 days ago' -- <relevant files>` for history of related changes.
   - `tests/` directory for assertions documenting the design choice the finding wants to alter.
3. **Cross-reference decline-history.md.** If the operator has declined this class before, cite the prior decline reason and ask whether the new commit changes the calculus.
4. **Per finding: emit a recommendation.** Choose ONE:
   - **`KEEP`** — the finding stands as the specialist + critic produced it. Justify briefly.
   - **`SIMPLIFY-WITH-PATTERN`** — there's an existing pattern at `<path:line>` that solves the same intent in fewer LOC. Cite the pattern + the LOC delta vs. the original remedy. The aggregator will rewrite the finding to point at the simpler shape.
   - **`DROP`** — investigation showed the finding does not hold (false positive on closer reading, already addressed in tests/, declined ≥3 rounds with same context, etc.). The aggregator will omit it from the published findings.
   - **`REFRAME`** — the underlying concern is real but firing rate is observably zero AND remedy is additive at our operating point. Move to Open Questions with cost-naming. Provide the reframed question text.

**Output format — exactly this shape (no preamble, no extra headers):**

```markdown
## Go-deep tech-lead investigation

### Investigation of Finding N

**Calibration answers:**

**Q1: <copy the critic's question verbatim>**
A: <answer with path:line evidence + confidence>

**Q2: <copy the second question if present>**
A: <answer>

**Pattern search:**
- <grep / git-log / file-read evidence for existing patterns>
- <LOC delta if SIMPLIFY-WITH-PATTERN>

**Decline-history check:**
- <reference to prior decline reason if class matches; "no prior decline" otherwise>

**Recommendation:** <KEEP | SIMPLIFY-WITH-PATTERN | DROP | REFRAME>
- <one-paragraph justification tied to the operating point>
- <If SIMPLIFY-WITH-PATTERN: cite the pattern path:line + the rewritten remedy>
- <If REFRAME: the reframed question text following the broken-glass template>
```

**Discipline:**
- One investigation block per finding-with-calibration-questions in your assigned specialist file. Findings without calibration questions are <20 LOC remedy and don't need go-deep — skip them silently (the aggregator publishes them as the critic produced them).
- Cite path:line for every claim of evidence. Hand-waving without cites is a failure mode — the aggregator will discard recommendations without grounding.
- Stay within the assigned specialist's findings. Don't drift into other specialists' territory; another go-deep instance is investigating those (or no one is, because no calibration questions surfaced there).
- If your assigned specialist file has zero findings with calibration questions: emit exactly `(no findings ≥20 LOC remedy in this specialist — go-deep not needed)` and exit. The orchestrator only invokes you when at least one such finding exists, but be defensive.
```

- [ ] **Step 8.2: Lint check**

```bash
grep -F "20-LOC remedy threshold" prompts/go-deep.md
grep -F "SIMPLIFY-WITH-PATTERN" prompts/go-deep.md
grep -F "{{SPECIALIST_NAME}}" prompts/go-deep.md
```
Expected: each grep emits a line.

- [ ] **Step 8.3: Commit**

```bash
git add prompts/go-deep.md
git commit -m "feat: prompts/go-deep.md — go-deep tech-lead specialist template"
```

---

### Task 9: Ranker + go-deep fan-out in lib/review-one-pr.sh

**Files:**
- Modify: `lib/review-one-pr.sh`

- [ ] **Step 9.1: Add ranker + fan-out block after critic-splitter**

After the `split_critic_to_specialists` call (Task 6), insert:

```bash
# ---- go-deep tech-leads (Phase 2) ----
# Rank top ≤3 findings by severity (blocking > medium > low > nit) +
# critic-survival (skip findings the critic dropped via REMEDY-BLOAT or
# FALSE POSITIVE) + remedy LOC desc tiebreak. Group by specialist file →
# set of "hot" specialists. Fan out one go-deep per hot specialist, max 3
# parallel. Each writes to RUN_DIR/agents/go-deep-<angle>/output.md and
# the orchestrator appends to specialists/<angle>.md.
#
# Auto-scales to 0 on simple PRs: if no findings have a "Calibration
# questions for go-deep" block (the critic only emits one for ≥20 LOC
# remedies), the hot-list is empty and no go-deep runs.

declare -a HOT_ANGLES=()
for angle in "${ANGLES[@]}"; do
    if grep -qF "Calibration questions for go-deep" "$SPECIALISTS_DIR/${angle}.md" 2>/dev/null; then
        HOT_ANGLES+=("$angle")
    fi
done

# Cap at 3 — pick by severity-band order (any [blocking] in the file
# beats any [medium], etc.). Tiebreak: file name order (deterministic).
if [ "${#HOT_ANGLES[@]}" -gt 3 ]; then
    declare -a RANKED=()
    for sev in "blocking" "medium" "low" "nit"; do
        for angle in "${HOT_ANGLES[@]}"; do
            if [ "${#RANKED[@]}" -lt 3 ] && \
               grep -qF "[$sev]" "$SPECIALISTS_DIR/${angle}.md" 2>/dev/null && \
               ! printf '%s\n' "${RANKED[@]}" | grep -qxF "$angle"; then
                RANKED+=("$angle")
            fi
        done
    done
    HOT_ANGLES=("${RANKED[@]}")
fi

if [ "${#HOT_ANGLES[@]}" -eq 0 ]; then
    log "$PR_ID: no findings ≥20 LOC remedy — skipping go-deep tech-leads"
else
    log "$PR_ID: launching ${#HOT_ANGLES[@]} go-deep tech-lead(s): ${HOT_ANGLES[*]}"
    declare -A GD_PIDS=()
    for angle in "${HOT_ANGLES[@]}"; do
        # Pass the bare $angle as specialist_name so {{SPECIALIST_NAME}}
        # in prompts/go-deep.md resolves to the angle (the prompt cites
        # `.codex-scratch/specialists/{{SPECIALIST_NAME}}.md` and needs
        # the bare name to resolve). The agent_name passed to
        # run-specialist.sh carries the "go-deep-" prefix so the output
        # dir doesn't collide with the original specialist's dir.
        GD_PROMPT=$(build_specialist_prompt \
            "$angle" \
            "$HOME/.pr-reviewer/prompts/go-deep.md" \
            "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
        "$_LIB_DIR/run-specialist.sh" \
            "go-deep-$angle" \
            "$REPO_DIR" \
            "$GD_PROMPT" \
            "$RUN_DIR/agents/go-deep-$angle" &
        GD_PIDS["$angle"]=$!
    done
    GD_FAILURE=0
    for angle in "${HOT_ANGLES[@]}"; do
        if ! wait "${GD_PIDS[$angle]}"; then
            log "$PR_ID: go-deep-$angle exited non-zero (see $RUN_DIR/agents/go-deep-$angle/log.txt) — falling back to no-go-deep"
            GD_FAILURE=1
        fi
    done
    # Append each successful go-deep output to its specialist file. A
    # failed go-deep (non-zero exit OR empty output) is fail-soft: the
    # specialist file stays at its specialist+critic state, the
    # aggregator publishes from that, and the run.log narrative
    # documents the failure. Aborting the review here would block on
    # an enrichment step that's purely additive value.
    for angle in "${HOT_ANGLES[@]}"; do
        GD_OUT="$RUN_DIR/agents/go-deep-$angle/output.md"
        if [ -s "$GD_OUT" ]; then
            printf '\n---\n\n' >> "$SPECIALISTS_DIR/${angle}.md"
            cat "$GD_OUT" >> "$SPECIALISTS_DIR/${angle}.md"
        fi
    done
    log "$PR_ID: go-deep tech-leads complete (failure=$GD_FAILURE)"
fi
```

- [ ] **Step 9.2: Syntax check + commit**

```bash
bash -n lib/review-one-pr.sh
git add lib/review-one-pr.sh
git commit -m "feat: go-deep tech-lead ranker + parallel fan-out (max 3)"
```

---

### Task 10: go-deep-fanout-smoke.sh

**Files:**
- Create: `lib/tests/go-deep-fanout-smoke.sh`

- [ ] **Step 10.1: Token-level fence on orchestrator wiring**

Create `lib/tests/go-deep-fanout-smoke.sh`:

```bash
#!/bin/bash
# Smoke for go-deep tech-lead orchestrator wiring.
#
# Token-level fence — review-one-pr.sh must reference go-deep.md, gate
# on "Calibration questions for go-deep" (the critic emits this for
# ≥20 LOC findings only — auto-scale to 0), cap at 3 parallel, and
# append outputs to specialists/<angle>.md.

set -uo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

echo "  asserting go-deep.md prompt referenced in review-one-pr.sh..."
assert_grep "review-one-pr.sh missing go-deep.md reference" \
    "go-deep.md" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting hot-list gate on Calibration questions token..."
assert_grep "review-one-pr.sh missing 'Calibration questions for go-deep' gate" \
    "Calibration questions for go-deep" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting parallel cap at 3..."
# Fence the comparison `gt 3` ensuring the cap exists somewhere in the block.
assert_grep "review-one-pr.sh missing parallel cap (gt 3)" \
    "-gt 3" "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep dispatch via run-specialist.sh..."
assert_grep "review-one-pr.sh missing run-specialist.sh dispatch for go-deep-" \
    'run-specialist.sh" \\' "$PROJECT_ROOT/lib/review-one-pr.sh"
assert_grep "review-one-pr.sh missing 'go-deep-' agent name prefix" \
    '"go-deep-$angle"' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  asserting go-deep output append to specialists/<angle>.md..."
assert_grep "review-one-pr.sh missing append step (cat go-deep output >> specialists/<angle>.md)" \
    'cat "$GD_OUT" >>' "$PROJECT_ROOT/lib/review-one-pr.sh"

echo "  PASS"
```

- [ ] **Step 10.2: Run + commit**

```bash
bash lib/tests/go-deep-fanout-smoke.sh
git add lib/tests/go-deep-fanout-smoke.sh
git commit -m "test: token-level fence on go-deep fan-out wiring"
```

---

### Task 11: prompts/aggregator.md — integrate go-deep recommendations

**Files:**
- Modify: `prompts/aggregator.md`

- [ ] **Step 11.1: Update specialist file inputs note**

Find the `.codex-scratch/specialists/security.md` line in the aggregator's inputs list. Replace the surrounding context (just the brief description, not the file list itself) with:

After the `.codex-scratch/specialists/consumers.md` line, add a paragraph below the entire list:

```markdown
**Note on layered specialist files.** Each `.codex-scratch/specialists/<angle>.md` is now a layered file: original specialist findings → critic counter-arguments (split from `critic.md` by the orchestrator's critic-splitter) → optionally a go-deep tech-lead investigation (when the finding's remedy was ≥20 LOC, ≤3 instances per review). When integrating findings, prefer the deepest available recommendation:
- **Go-deep `KEEP`** → publish the finding as the specialist + critic produced it (severity from specialist + critic verdict).
- **Go-deep `SIMPLIFY-WITH-PATTERN`** → rewrite the finding's remedy to use the cited pattern; severity stays.
- **Go-deep `DROP`** → omit from published findings (footnote: "X was investigated by go-deep tech-lead; decline reason: <one-line>" — only if the finding was originally `blocking`/`medium`).
- **Go-deep `REFRAME`** → move to Open Questions with the go-deep's reframed text verbatim. The reframe carries cost-naming already.
```

- [ ] **Step 11.2: Lint + commit**

```bash
grep -F "Go-deep" prompts/aggregator.md
grep -F "SIMPLIFY-WITH-PATTERN" prompts/aggregator.md
git add prompts/aggregator.md
git commit -m "feat(aggregator): integrate go-deep recommendations from layered specialist files"
```

---

### Task 12: anti-bloat smoke (Phase 2) + justfile + simplification cleanup

**Files:**
- Modify: `lib/tests/anti-bloat-contract-smoke.sh`
- Modify: `justfile`
- Modify: `prompts/simplification.md`

- [ ] **Step 12.1: Add Phase 2 token assertions**

In `lib/tests/anti-bloat-contract-smoke.sh`, after the Phase 1 assertions:

```bash
echo "  asserting go-deep recommendations integrated in aggregator.md..."
assert_grep "aggregator.md should reference SIMPLIFY-WITH-PATTERN go-deep recommendation" \
    "SIMPLIFY-WITH-PATTERN" prompts/aggregator.md
assert_grep "aggregator.md should reference go-deep tech-lead layered file" \
    "Go-deep" prompts/aggregator.md

echo "  asserting go-deep specialist prompt exists..."
assert_grep "go-deep.md should fence the 20-LOC remedy threshold reference" \
    "20-LOC remedy threshold" prompts/go-deep.md
```

- [ ] **Step 12.2: Wire go-deep-fanout smoke in justfile**

After the `critic-splitter smoke` block:

```
    echo ""
    echo "=== go-deep-fanout smoke ==="
    bash lib/tests/go-deep-fanout-smoke.sh
```

- [ ] **Step 12.3: Drop kid-prior-art role from prompts/simplification.md (-15 LOC)**

This is a Phase 2 simplification opportunity. The simplification specialist's kid-prior-art lookup overlaps with the go-deep tech-lead's pattern-search step. Read `prompts/simplification.md`, find the section that talks about kid-prior-art / cross-repo similarity, and either delete it or replace with a short pointer to go-deep.

If the section is hard to identify, skip this step and note in the PR description that the simplification cleanup is deferred. Don't force a marginal cleanup that risks regressing the simplification specialist.

- [ ] **Step 12.4: Run + commit**

```bash
bash lib/tests/anti-bloat-contract-smoke.sh
git add lib/tests/anti-bloat-contract-smoke.sh justfile prompts/simplification.md 2>/dev/null || true
git add lib/tests/anti-bloat-contract-smoke.sh justfile
git commit -m "test(phase 2): token-level fences for go-deep + simplification cleanup"
```

---

### Task 13: Run `just test`

- [ ] **Step 13.1: Full smoke suite**

```bash
just test
```

Expected: `all checks passed`. Fix any failures; never commit a green state with a regression.

---

### Task 14: Push + open PR

- [ ] **Step 14.1: Push branch**

```bash
git push -u origin feat/go-deep-tech-leads-spec
```

- [ ] **Step 14.2: Open PR**

```bash
gh pr create --title "feat: go-deep tech-leads (Phase 1 + Phase 2)" --body "$(cat <<'EOF'
## Summary
- Phase 1: decline-history awareness + critic generates remedy-LOC estimate + 1-2 calibration questions for ≥20 LOC findings + critic-splitter co-locates critic output in specialists/<angle>.md
- Phase 2: prompts/go-deep.md (≤3 parallel tech-leads, one per hot specialist file); ranker step + fan-out in lib/review-one-pr.sh; aggregator integrates KEEP/SIMPLIFY-WITH-PATTERN/DROP/REFRAME
- Adds § 20-LOC remedy threshold sub-rule to vibe-engineering CODING_STANDARDS.md (linked PR)

Spec: docs/specs/2026-05-02-go-deep-tech-leads-design.md
Plan: docs/plans/2026-05-02-go-deep-tech-leads.md

## Test plan
- [ ] `just test` — green
- [ ] Live observation on next 5-10 reviews: do declined findings drop on round 2+? do calibration questions appear for ≥20 LOC findings? do go-deep tech-leads fire (≤3 instances)?

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Cite the resulting PR URL.

---

## Self-Review Notes

- **Spec coverage:** Phase 1 changes A-E ↔ Tasks 1-7. Phase 2 changes F-H ↔ Tasks 8-12. ✓
- **Placeholders:** none — every step has the actual content.
- **Type consistency:** `split_critic_to_specialists` (Task 5) consumed in Task 6. `fetch_decline_history` (Task 2) consumed in Task 3. `HOT_ANGLES` (Task 9) is local to the new block.
- **Worktree note:** global rule forbids worktrees. Plan uses the existing `feat/go-deep-tech-leads-spec` branch (already created when committing the spec) — execute on this branch.
- **Vibe-engineering PR is parallel:** Task 1 opens its own PR in `~/Hacking/vibe-engineering`. The kw-reviewer PR (Task 14) cites it but doesn't depend on it merging first; the bot reads `standards.md` from the operator's home, so the standards update can land independently.
