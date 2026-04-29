# Parallel Reviews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the `pr-reviewer.service` systemd tick process up to **3 eligible PRs in parallel** instead of serializing everything through a global lock.

**Architecture:** Split `review.sh` (~470 lines today) into two files — an orchestrator (`review.sh`) that enumerates eligible PRs and fans out reviews with a bounded concurrency cap, and a worker (`lib/review-one-pr.sh`) that runs the full pipeline for one PR in its own per-PR workdir (`/tmp/pr-review/<slug>#<pr>/`) and per-PR scratch dir (that worktree's `.codex-scratch/`). Each worker holds a per-PR `flock` so the same PR can't be reviewed twice concurrently. Shared state (`state.json`) writes are serialized by a dedicated flock helper in `lib/state-io.sh`. The per-PR workdir is a `git clone --shared` off the canonical per-repo clone at `$REPOS_DIR/<slug>/` — fast (local, hard-linked objects), cheap (disk), and safe under `PrivateTmp=yes`.

**Tech Stack:** Bash 5.2, `flock(1)`, `git clone --shared`, `wait -n` (bash ≥ 4.3). All existing: `codex exec`, `gh`, `jq`, `kid`, systemd oneshot services.

---

## Meta Context (read first — applies to every task)

**This plan is being executed in a sibling checkout, not the live production tree.**

- **Working tree:** `~/Hacking/knightwatch-reviewer2/` on branch `parallel-reviews`.
- **Do NOT touch** `~/Hacking/knightwatch-reviewer/` (live production, symlinked into `~/.pr-reviewer/`).
- **Do NOT run** commands that mutate `~/.pr-reviewer/state.json`, `~/.pr-reviewer/review.log`, or any file under `~/.pr-reviewer/`.
- The prep commit on this branch (`Make STATE_DIR and related paths overridable via env`) makes every reviewer script honor `STATE_DIR=... LOG_FILE=... REPOS_DIR=... LOCK_FILE=...` env overrides. Use those for isolated smoke testing.

**Sandbox pattern for any smoke test:**

```bash
SANDBOX=$(mktemp -d -t kw-smoke-XXXXXX)
export STATE_DIR="$SANDBOX"
export STATE_FILE="$SANDBOX/state.json"
export LOG_FILE="$SANDBOX/review.log"
export REPOS_DIR="$SANDBOX/repos"
export LOCK_FILE="$SANDBOX/pr-reviewer.lock"
mkdir -p "$REPOS_DIR"
echo '{}' > "$STATE_FILE"

# ... run your test against the sibling scripts ...
~/Hacking/knightwatch-reviewer2/review.sh

# Always clean up
rm -rf "$SANDBOX"
```

**Stub GitHub writes when needed** (prevents real comment posts during smoke tests):

```bash
# Before:
cp ~/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh /tmp/worker.bak
sed -i 's|^gh pr comment|echo DRYRUN gh pr comment|; s|^    gh pr review|    echo DRYRUN gh pr review|' \
    ~/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh
# ... run test ...
# After:
cp /tmp/worker.bak ~/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh
```

**Rollout after Tasks 0-6 commit locally:**

1. Push the branch: `git push -u origin parallel-reviews`
2. Open PR: `gh pr create --repo srosro/knightwatch-reviewer --base main --head parallel-reviews --title "Parallelize reviews (MAX_CONCURRENT=3)"`
3. The **live** reviewer picks up the PR on its next tick (we added `srosro/knightwatch-reviewer` to tracked repos earlier — dogfooding). Any blocking findings → address in new commits.
4. Human reviews + merges.
5. **Task 7 (live validation)** happens AFTER merge. The symlink `~/.pr-reviewer/review.sh → ~/Hacking/knightwatch-reviewer/review.sh` automatically points at the updated `main`. Clear 3 PR state entries in `~/.pr-reviewer/state.json`, watch the next timer tick fan out.

**All file paths below refer to `~/Hacking/knightwatch-reviewer2/`** unless explicitly stated. When a step says "edit `lib/state-io.sh`" it means `~/Hacking/knightwatch-reviewer2/lib/state-io.sh`, not the production path.

---

## File Structure

**Create:**
- `lib/state-io.sh` — single source of truth for `state_get` / `state_set` with a flock on `$STATE_FILE.lock`, plus shared `log()` helper.
- `lib/review-one-pr.sh` — executable script that reviews one PR end-to-end. Takes six positional args (REPO, PR_NUM, PR_SHA, PR_BRANCH, PR_TITLE, FORCE_WHOLE_PR). Does per-PR lock, per-PR workdir, test/kid/specialists/critic/aggregator/post/state. Safe to launch multiple copies concurrently on different PRs.
- `docs/plans/2026-04-24-parallel-reviews.md` — this file.

**Modify:**
- `review.sh` — rewritten as an orchestrator: enumerate eligible PRs across all repos, fan out `lib/review-one-pr.sh` invocations in background with `MAX_CONCURRENT=3` via `wait -n`, wait for all, exit.
- `systemd/pr-reviewer.service` — bump `TimeoutStartSec=60min` → `90min` to accommodate three concurrent ~20-min reviews running back-to-back within one tick.

**Unchanged:**
- `lib/run-specialist.sh` — works per-PR already; not in the critical path of this refactor.
- `prompts/*.md` — no changes.
- `contexts/*.md` — no changes.
- `learn-from-replies.sh`, `plow-kid-refresh.sh`, `re-request-poller.sh` — independent services, unaffected.

**No tests created.** This is a bash orchestrator; unit tests aren't valuable. Each task defines a concrete smoke test against real or synthetic PR state.

---

## Task 0: Pre-flight — verify bash / flock / wait-n / disk

**Purpose:** The plan assumes `wait -n` (bash ≥ 4.3), `flock(1)` available, `git clone --shared` works, and enough free space in `/tmp` for per-PR clones. Confirm before investing in the refactor.

**Files:** none created; verification commands only.

- [ ] **Step 1: verify bash version supports `wait -n`**

```bash
bash --version | head -1
```

Expected: `GNU bash, version 5.x` or at minimum `4.3+`. `wait -n` requires 4.3+.

- [ ] **Step 2: verify `flock(1)` is installed**

```bash
command -v flock && flock --version | head -1
```

Expected: path to `/usr/bin/flock` printed, version string printed. If not installed: `apt install util-linux` (should already be present on Ubuntu).

- [ ] **Step 3: verify `git clone --shared` works locally**

```bash
T=$(mktemp -d)
git clone --shared ~/Hacking/knightwatch-reviewer "$T/test-clone" --depth=5 --no-single-branch 2>&1 | tail -3
ls "$T/test-clone/.git" | head -3
du -sh ~/Hacking/knightwatch-reviewer/.git "$T/test-clone/.git"
rm -rf "$T"
```

Expected: clone completes in <1 s, `.git` exists in the new dir, clone's `.git` is much smaller than the source because object storage is shared (typically <1 MB vs. many MB).

- [ ] **Step 4: verify `PrivateTmp=yes` is set on the reviewer service (so `/tmp/pr-review/*` is private per-tick)**

```bash
systemctl cat pr-reviewer.service | grep -i PrivateTmp
```

Expected: `PrivateTmp=yes`. Since the current unit already has this, per-tick workdirs in `/tmp` are automatically cleaned when systemd tears the unit down.

- [ ] **Step 5: verify free space in /tmp**

```bash
df -h /tmp | tail -1
```

Expected: multi-GB free. We'll create up to 3 workdirs per tick, each a shared clone (small) plus the checked-out files. Budget ~100-500 MB per workdir for the biggest repo (plow).

- [ ] **Step 6: decision gate**

If any of 1-4 fails → stop the plan and fix the environment first. Step 5 is advisory.

---

## Task 1: Extract `state-io.sh` — serialized `state_set` via flock

**Purpose:** `state.json` is a shared file. Multiple concurrent workers would race on its `jq ... > state.json` pattern (no atomicity). Introduce a dedicated `state_set` that holds an exclusive flock while reading-modifying-writing.

**Files:**
- Create: `lib/state-io.sh`
- Modify: `review.sh` (later task will re-use from this file; no change now)

- [ ] **Step 1: create the file**

Write `~/Hacking/knightwatch-reviewer/lib/state-io.sh`:

```bash
#!/bin/bash
# Shared state-file helpers used by both the orchestrator (review.sh) and
# the per-PR worker (review-one-pr.sh). state_set holds an exclusive flock
# on ${STATE_FILE}.lock while reading-modifying-writing, so concurrent
# workers produce a consistent final state.json.

# Callers must have already set:
#   STATE_FILE=~/.pr-reviewer/state.json
#   LOG_FILE=~/.pr-reviewer/review.log

state_get() {
    # Read is safe without a lock; last-written wins but jq reads atomically enough.
    jq -r --arg id "$1" --arg k "$2" '.[$id][$k] // empty' "$STATE_FILE"
}

state_set() {
    local pr_id="$1" sha="$2" approved="$3" body="$4"
    local lockfile="${STATE_FILE}.lock"
    (
        # subshell holds the lock for its lifetime
        exec {fd}> "$lockfile"
        flock "$fd"
        local tmp
        tmp=$(jq --arg id "$pr_id" --arg sha "$sha" --arg body "$body" \
            --argjson ts "$(date +%s)" --argjson appr "$approved" \
            '.[$id] = {sha: $sha, reviewed_at: $ts, approved: $appr, body: $body}' \
            "$STATE_FILE")
        # Atomic rename pattern
        printf '%s' "$tmp" > "${STATE_FILE}.tmp"
        mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
    )
}

# Shared structured logger. Prepends timestamp; tee's to LOG_FILE and stdout so
# both systemd journal and legacy tail -f of review.log keep working.
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}
```

- [ ] **Step 2: make it executable-readable and syntax-check**

```bash
chmod 644 ~/Hacking/knightwatch-reviewer/lib/state-io.sh
bash -n ~/Hacking/knightwatch-reviewer/lib/state-io.sh
```

Expected: no syntax errors.

- [ ] **Step 3: sanity test in isolation**

```bash
(
    export STATE_FILE=/tmp/state-io-probe.json
    export LOG_FILE=/tmp/state-io-probe.log
    echo '{}' > "$STATE_FILE"
    . ~/Hacking/knightwatch-reviewer/lib/state-io.sh
    state_set "fake/repo#1" "abc123" false "test body"
    state_set "fake/repo#2" "def456" true  "other body"
    jq . "$STATE_FILE"
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$LOG_FILE"
)
```

Expected: both entries present in JSON with expected sha/approved fields.

- [ ] **Step 4: concurrency smoke test — 20 parallel state_set calls**

```bash
(
    export STATE_FILE=/tmp/state-io-race.json
    export LOG_FILE=/tmp/state-io-race.log
    echo '{}' > "$STATE_FILE"
    . ~/Hacking/knightwatch-reviewer/lib/state-io.sh
    for i in $(seq 1 20); do
        state_set "race/repo#$i" "sha$i" false "body $i" &
    done
    wait
    echo "entries after race:"
    jq 'keys | length' "$STATE_FILE"
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$LOG_FILE"
)
```

Expected: `20` (every state_set landed; no entries lost to lost-writes).

- [ ] **Step 5: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio add lib/state-io.sh && \
  git -c user.email=eng@plow.co -c user.name=odio commit -m "Add lib/state-io.sh: flock-serialized state_set + shared log()"
```

---

## Task 2: Extract per-PR worker to `lib/review-one-pr.sh` (serial mode, no workdir change)

**Purpose:** Take the inner per-PR body of `review.sh` (lines ~156 onward — the "Reviewing $PR_ID" block through the `state_set`/`exit 0`) and move it into a new script that takes the PR spec as arguments. In this task the worker still uses the existing per-repo workdir (`$REPOS_DIR/<slug>`) and does NOT take a per-PR lock — those come in Task 3 and 4. The orchestrator keeps the global lock and still calls exactly one worker per tick. **No behavior change expected** — same reviews land on the same PRs.

**Files:**
- Create: `lib/review-one-pr.sh`
- Modify: `review.sh` — the per-PR body is replaced with a single call to `lib/review-one-pr.sh`.

- [ ] **Step 1: create the worker file**

Write `~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh`:

```bash
#!/bin/bash
# Reviews one PR end-to-end. Invoked by review.sh as:
#   lib/review-one-pr.sh REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# where FORCE_WHOLE_PR is "true" or "false".

set -u
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

REPO="$1"
PR_NUM="$2"
PR_SHA="$3"
PR_BRANCH="$4"
PR_TITLE="$5"
FORCE_WHOLE_PR="${6:-false}"

PR_ID="${REPO}#${PR_NUM}"
PR_URL="https://github.com/$REPO/pull/$PR_NUM"

STATE_DIR="$HOME/.pr-reviewer"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/review.log"
REPOS_DIR="$STATE_DIR/repos"

[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"

. "$HOME/.pr-reviewer/lib/state-io.sh"

# --- sed escape for PR metadata placeholders ----------------------------------
safe_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# --- build a specialist prompt by concatenating common-header + angle file ----
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

write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$scratch_dir/specialists"
    printf '%s' "$content" > "$scratch_dir/$filename"
}

preserve_scratch() {
    local repo_dir="$1" pr_slug="$2"
    local archive="$STATE_DIR/last-run-scratch/$pr_slug"
    if [ -d "$repo_dir/.codex-scratch" ]; then
        rm -rf "$archive"
        mkdir -p "$(dirname "$archive")"
        mv "$repo_dir/.codex-scratch" "$archive"
    fi
}

log "Reviewing $PR_ID (force_whole_pr=$FORCE_WHOLE_PR)"

# Clone-or-update the per-repo canonical clone (same location as before).
REPO_SLUG=$(echo "$REPO" | tr '/' '_')
REPO_DIR="$REPOS_DIR/$REPO_SLUG"
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning $REPO..."
    gh repo clone "$REPO" "$REPO_DIR" -- --depth=50 --no-single-branch 2>&1 | tail -2
fi

DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet
git -C "$REPO_DIR" fetch origin "$PR_BRANCH"      --depth=50 --quiet
git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" FETCH_HEAD --quiet

# ---- just test ----
TEST_LOG="/tmp/review-tests-${REPO_SLUG}-${PR_NUM}.log"
TEST_TIMEOUT=30m
log "$PR_ID: running \`just test\` (timeout ${TEST_TIMEOUT})..."
(cd "$REPO_DIR" && timeout "$TEST_TIMEOUT" just test) > "$TEST_LOG" 2>&1
TEST_EXIT=$?
if [ "$TEST_EXIT" -eq 127 ]; then
    log "$PR_ID: 'just test' not available (exit 127) — aborting"
    exit 1
fi
case "$TEST_EXIT" in
    0)   TEST_SUMMARY="PASSED" ;;
    124) TEST_SUMMARY="TIMED OUT (>${TEST_TIMEOUT})" ;;
    *)   TEST_SUMMARY="FAILED (exit ${TEST_EXIT})" ;;
esac
log "$PR_ID: just test ${TEST_SUMMARY}"
TEST_TAIL=$(tail -n 500 "$TEST_LOG")
TEST_RESULTS="**Result:** ${TEST_SUMMARY}

Last 500 lines of \`just test\` output:
\`\`\`
${TEST_TAIL}
\`\`\`"

# ---- standards ----
STANDARDS=""
[ -f ~/.claude/CODING_STANDARDS.md ]     && STANDARDS+=$(cat ~/.claude/CODING_STANDARDS.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/REVIEW_PRACTICES.md ]     && STANDARDS+=$(cat ~/.claude/REVIEW_PRACTICES.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/TESTING.md ]              && STANDARDS+=$(cat ~/.claude/TESTING.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/COMMENT_REVIEW_MISTAKES.md ] && STANDARDS+="## Known Review Mistakes (avoid repeating these)\n"$(cat ~/.claude/COMMENT_REVIEW_MISTAKES.md)

# ---- build diff + REVIEW_TASK (three paths) ----
KNOWN_SHA=$(state_get "$PR_ID" "sha")
PREV_BODY=""
if [ -z "$KNOWN_SHA" ] || [ "$FORCE_WHOLE_PR" = "true" ]; then
    KID_INPUT_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
    if [ "$FORCE_WHOLE_PR" = "true" ]; then
        REVIEW_TASK="Whole-PR re-review (requested via /review comment). Review the full PR diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md. Any prior review is intentionally NOT provided — evaluate this PR from scratch."
    else
        REVIEW_TASK="Review the diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md."
    fi
else
    PREV_BODY=$(state_get "$PR_ID" "body")
    PREV_APPROVED=$(state_get "$PR_ID" "approved")
    if git -C "$REPO_DIR" cat-file -e "${KNOWN_SHA}^{commit}" 2>/dev/null; then
        KID_INPUT_DIFF=$(git -C "$REPO_DIR" diff "$KNOWN_SHA..HEAD")
    else
        log "$PR_ID: prior SHA $KNOWN_SHA not in local history; using full PR diff"
        KID_INPUT_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
    fi
    REVIEW_TASK="Re-review: the author has pushed new commits since your previous review (at ${KNOWN_SHA:0:7}, approved=$PREV_APPROVED). Your prior review is in .codex-scratch/previous-review.md. The incremental diff since that review is in .codex-scratch/diff.patch. Assess whether the new commits address your prior concerns, then produce an updated review."
fi

# ---- kid prior-art ----
PRIOR_ART=""
KID_FLAG="$STATE_DIR/kid-last-failure"
case "$REPO" in
    "cncorp/plow")                 KID_PROJECT_PATH="$HOME/Hacking/plow-kid" ;;
    "srosro/tkmx-client")          KID_PROJECT_PATH="$HOME/Hacking/tkmx-client" ;;
    "srosro/tkmx-server")          KID_PROJECT_PATH="$HOME/Hacking/tkmx-server" ;;
    "srosro/knightwatch-reviewer") KID_PROJECT_PATH="$HOME/Hacking/knightwatch-reviewer" ;;
    *)                             KID_PROJECT_PATH="" ;;
esac
if [ -n "$KID_PROJECT_PATH" ] && [ -d "$KID_PROJECT_PATH/.keepitdry" ] && [ -n "$KID_INPUT_DIFF" ]; then
    export KID_PROJECT="$KID_PROJECT_PATH"
    KID_STDERR=$(mktemp)
    PRIOR_ART=$(printf '%s' "$KID_INPUT_DIFF" | python3 "$HOME/Hacking/knightwatch-kid/scripts/kid_dry_check.py" 2>"$KID_STDERR")
    KID_EXIT=$?
    if [ $KID_EXIT -ne 0 ]; then
        KID_ERR_SUMMARY=$(tail -n 3 "$KID_STDERR" | tr '\n' ' ')
        log "$PR_ID: KID FAILURE (exit $KID_EXIT, project $KID_PROJECT) — degrading to kid-less review. stderr tail: $KID_ERR_SUMMARY"
        {
            echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "pr: $PR_ID"
            echo "project: $KID_PROJECT"
            echo "exit: $KID_EXIT"
            echo "--- stderr tail ---"
            tail -n 20 "$KID_STDERR"
        } > "$KID_FLAG"
        PRIOR_ART=""
    else
        rm -f "$KID_FLAG"
        if [ -n "$PRIOR_ART" ]; then
            BLOCK_COUNT=$(printf '%s\n' "$PRIOR_ART" | grep -c '^### New block')
            log "$PR_ID: kid surfaced prior-art for $BLOCK_COUNT block(s)"
        fi
    fi
    rm -f "$KID_STDERR"
elif [ -n "$KID_PROJECT_PATH" ] && [ -n "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: kid index not yet built at $KID_PROJECT_PATH — skipping prior-art lookup"
fi

log "$PR_ID: diff is ${#KID_INPUT_DIFF} bytes"

# ---- write scratch files ----
write_scratch "$REPO_DIR" "diff.patch"         "$KID_INPUT_DIFF"
write_scratch "$REPO_DIR" "previous-review.md" "$PREV_BODY"
write_scratch "$REPO_DIR" "test-results.md"    "$TEST_RESULTS"
write_scratch "$REPO_DIR" "prior-art.md"       "${PRIOR_ART:-}"
write_scratch "$REPO_DIR" "standards.md"       "$STANDARDS"

CONTEXT_FILE="$HOME/.pr-reviewer/contexts/$(echo "$REPO" | tr '/' '_').md"
if [ -f "$CONTEXT_FILE" ]; then
    write_scratch "$REPO_DIR" "product-context.md" "$(cat "$CONTEXT_FILE")"
else
    write_scratch "$REPO_DIR" "product-context.md" "(no product context configured for $REPO)"
fi

FILE_HISTORY=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    FILE_HISTORY+="### $f"$'\n'
    hist=$(git -C "$REPO_DIR" log --oneline -n 5 -- "$f" 2>/dev/null)
    FILE_HISTORY+="${hist:-(no history)}"$'\n\n'
done < <(git -C "$REPO_DIR" diff --name-only "$DEFAULT_BRANCH"...HEAD 2>/dev/null | head -30)
write_scratch "$REPO_DIR" "file-history.md" "${FILE_HISTORY:-(no touched files)}"

PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,closingIssuesReferences 2>/dev/null)
AUTHOR_INTENT="## PR Title
$(printf '%s' "$PR_DATA" | jq -r '.title // empty')

## PR Description (author's own explanation)

$(printf '%s' "$PR_DATA" | jq -r '.body // "(no description provided)"')
"
ISSUE_COUNT=0
while IFS=$'\t' read -r IS_OWNER IS_NAME IS_NUM; do
    [ -z "$IS_NUM" ] && continue
    [ "$ISSUE_COUNT" -ge 5 ] && break
    ISSUE_DATA=$(gh issue view "$IS_NUM" --repo "$IS_OWNER/$IS_NAME" --json title,body 2>/dev/null)
    IS_TITLE=$(printf '%s' "$ISSUE_DATA" | jq -r '.title // empty')
    IS_BODY=$(printf '%s' "$ISSUE_DATA" | jq -r '.body // empty')
    if [ -n "$IS_TITLE" ]; then
        [ "$ISSUE_COUNT" -eq 0 ] && AUTHOR_INTENT+=$'\n## Linked issues (this PR closes)\n\n'
        AUTHOR_INTENT+="### $IS_OWNER/$IS_NAME#$IS_NUM: $IS_TITLE
$IS_BODY

"
        ISSUE_COUNT=$((ISSUE_COUNT+1))
    fi
done < <(printf '%s' "$PR_DATA" | jq -r '.closingIssuesReferences[]? | [.owner.login, .repo.name, (.number|tostring)] | @tsv' 2>/dev/null)
write_scratch "$REPO_DIR" "author-intent.md" "$AUTHOR_INTENT"

SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
mkdir -p "$SPECIALISTS_DIR"

log "$PR_ID: launching 5 specialists in parallel..."
for angle in security data-integrity architecture simplification tests; do
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
for angle in security data-integrity architecture simplification tests; do
    if [ ! -s "$SPECIALISTS_DIR/${angle}.md" ]; then
        log "$PR_ID: specialist $angle produced empty output — aborting review"
        SPECIALIST_FAILURE=1
    fi
done
if [ "$SPECIALIST_FAILURE" -ne 0 ]; then
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    exit 1
fi
log "$PR_ID: all 5 specialists completed"
for angle in security data-integrity architecture simplification tests; do
    LINES=$(wc -l < "$SPECIALISTS_DIR/${angle}.md")
    NO_FINDINGS=""
    grep -q '^No findings\.' "$SPECIALISTS_DIR/${angle}.md" && NO_FINDINGS=" (no findings)"
    log "$PR_ID: specialist=$angle lines=$LINES$NO_FINDINGS"
done

log "$PR_ID: critic pass..."
CRITIC_PROMPT=$(cat "$HOME/.pr-reviewer/prompts/critic.md")
CRITIC_OUT="$REPO_DIR/.codex-scratch/critic.md"
codex exec \
    -C "$REPO_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    -c model_reasoning_effort=high \
    -o "$CRITIC_OUT" \
    "$CRITIC_PROMPT" \
    >> "$LOG_FILE" 2>&1

if [ ! -s "$CRITIC_OUT" ]; then
    log "$PR_ID: critic output empty — continuing without counterarguments"
    echo "(critic output empty — fall back)" > "$CRITIC_OUT"
fi

log "$PR_ID: aggregator (with critic input)..."
# (Superseded by PR #12: aggregator now uses substitute_placeholders
# directly to avoid the specialist common-header.)
AGG_PROMPT=$(build_specialist_prompt \
    "aggregator" \
    "$HOME/.pr-reviewer/prompts/aggregator.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL")
AGG_OUT="$REPO_DIR/.codex-scratch/aggregator-output.md"
codex exec \
    -C "$REPO_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    -c model_reasoning_effort=high \
    -o "$AGG_OUT" \
    "$AGG_PROMPT" \
    >> "$LOG_FILE" 2>&1

if [ ! -s "$AGG_OUT" ]; then
    log "$PR_ID: aggregator output empty — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    exit 1
fi
REVIEW=$(cat "$AGG_OUT")
if ! echo "$REVIEW" | grep -q '^VERDICT:'; then
    log "$PR_ID: aggregator output missing VERDICT line — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    exit 1
fi
VERDICT=$(echo "$REVIEW" | grep '^VERDICT:' | tail -1)
COMMENT_BODY=$(echo "$REVIEW" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/{ N; /^\n$/d }')
if [ -z "$COMMENT_BODY" ]; then
    log "Empty review body for $PR_ID, skipping"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    exit 1
fi
gh pr comment "$PR_NUM" --repo "$REPO" --body "$COMMENT_BODY"
log "Posted review comment on $PR_ID"

APPROVED=false
if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" 2>&1 \
        || log "Approve skipped (own PR or already approved)"
    APPROVED=true
    log "Approved $PR_ID ($APPROVE_BODY)"
else
    log "Commented on $PR_ID (no approval)"
fi

state_set "$PR_ID" "$PR_SHA" "$APPROVED" "$COMMENT_BODY"
preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
log "Done with $PR_ID"
exit 0
```

- [ ] **Step 2: make it executable**

```bash
chmod +x ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
bash -n ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 3: replace the per-PR body in `review.sh` with a call to the worker**

Open `~/Hacking/knightwatch-reviewer/review.sh`. Replace everything from the `log "Reviewing $PR_ID (force=$FORCE_REVIEW)"` line through the `exit 0` at the bottom of the per-PR block (roughly lines 156-462 in the current file) with:

```bash
        log "Eligible for review: $PR_ID (force=$FORCE_REVIEW, whole_pr=$FORCE_WHOLE_PR)"
        touch "$LOCK_FILE"

        # Delegate the entire per-PR pipeline to the worker.
        ~/.pr-reviewer/lib/review-one-pr.sh "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR"

        rm -f "$LOCK_FILE"
        exit 0
```

Also remove these now-unused helpers from `review.sh` (they live in `lib/state-io.sh` and `lib/review-one-pr.sh` now):
- `safe_sed`
- `build_specialist_prompt`
- `state_set` (keep `state_get` — the orchestrator still uses it to check KNOWN_SHA and REVIEWED_AT)
- `write_scratch`
- `preserve_scratch`

And add at the top of `review.sh` after the `log()` definition block (line ~30):

```bash
. "$HOME/.pr-reviewer/lib/state-io.sh"
```

This gives `review.sh` access to `state_get` (and `log` — which is already defined in the orchestrator, so the sourced version is shadowed; that's fine).

- [ ] **Step 4: verify syntax**

```bash
bash -n ~/Hacking/knightwatch-reviewer/review.sh && echo "review.sh OK"
bash -n ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh && echo "worker OK"
```

- [ ] **Step 5: smoke test — trigger one review on a known-good PR**

Pick a tiny PR (e.g., any PR already in state with a recent SHA). To avoid actually posting, temporarily stub `gh pr comment`:

```bash
# Pick a PR id from state.json; we'll re-review it by clearing state.
PR_ID=$(jq -r 'keys | .[0]' ~/.pr-reviewer/state.json)
jq --arg k "$PR_ID" 'del(.[$k])' ~/.pr-reviewer/state.json > /tmp/state.json.new && mv /tmp/state.json.new ~/.pr-reviewer/state.json

# Stub the GH writes in the WORKER so we don't post real comments for this test
cp ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh /tmp/review-one-pr.sh.bak
sed -i 's|^gh pr comment|echo DRYRUN gh pr comment|; s|^    gh pr review|    echo DRYRUN gh pr review|' ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh

# Run the orchestrator directly (not via systemd, so we see the output)
~/Hacking/knightwatch-reviewer/review.sh

# Restore the worker
cp /tmp/review-one-pr.sh.bak ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
```

Expected: orchestrator logs "Eligible for review: $PR_ID", worker logs its usual stages (just test, specialists, critic, aggregator), `DRYRUN gh pr comment` lines show a full review body, state is updated (check `jq '.[...]' state.json` — entry is present again).

- [ ] **Step 6: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio add -A && \
  git -c user.email=eng@plow.co -c user.name=odio commit -m "Extract per-PR pipeline to lib/review-one-pr.sh; still serial"
```

---

## Task 3: Per-PR workdir — `/tmp/pr-review/<slug>#<pr>/` via `git clone --shared`

**Purpose:** Two concurrent reviews on the same repo would collide on the single `$REPOS_DIR/<slug>/` workdir (both would try `git checkout` to different PR branches). Give each worker its own workdir via `git clone --shared` off the canonical clone. The shared clone is fast (uses hard-linked objects) and cheap (mostly just `.git/objects/info/alternates` pointing at the canonical clone). Keep the canonical clone at `$REPOS_DIR/<slug>/` as the source of truth for `fetch`.

**Files:**
- Modify: `lib/review-one-pr.sh` — replace `REPO_DIR=$REPOS_DIR/$REPO_SLUG` with a per-PR workdir derivation and shared-clone setup.

- [ ] **Step 1: in `lib/review-one-pr.sh`, replace the "Clone-or-update" block**

Find this block:

```bash
# Clone-or-update the per-repo canonical clone (same location as before).
REPO_SLUG=$(echo "$REPO" | tr '/' '_')
REPO_DIR="$REPOS_DIR/$REPO_SLUG"
if [ ! -d "$REPO_DIR/.git" ]; then
    log "Cloning $REPO..."
    gh repo clone "$REPO" "$REPO_DIR" -- --depth=50 --no-single-branch 2>&1 | tail -2
fi

DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet
git -C "$REPO_DIR" fetch origin "$PR_BRANCH"      --depth=50 --quiet
git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" FETCH_HEAD --quiet
```

Replace with:

```bash
# Canonical clone lives at $REPOS_DIR/<slug>/ and is the source of truth
# for `fetch`. Multiple PR reviews on the same repo coexist by each working
# in their own per-PR workdir that shares objects with the canonical clone.
REPO_SLUG=$(echo "$REPO" | tr '/' '_')
CANONICAL_DIR="$REPOS_DIR/$REPO_SLUG"
PR_SLUG="${REPO_SLUG}__${PR_NUM}"
REPO_DIR="/tmp/pr-review/${PR_SLUG}"

if [ ! -d "$CANONICAL_DIR/.git" ]; then
    log "Cloning canonical $REPO..."
    gh repo clone "$REPO" "$CANONICAL_DIR" -- --depth=50 --no-single-branch 2>&1 | tail -2
fi

# Fetch latest refs into the canonical clone (fast, uses existing objects).
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
git -C "$CANONICAL_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet
git -C "$CANONICAL_DIR" fetch origin "$PR_BRANCH"      --depth=50 --quiet

# Tear down any stale per-PR workdir and create a fresh shared clone.
rm -rf "$REPO_DIR"
mkdir -p "$(dirname "$REPO_DIR")"
git clone --shared "$CANONICAL_DIR" "$REPO_DIR" --no-single-branch --quiet

# Make the PR branch available in the new clone and check it out.
git -C "$REPO_DIR" fetch origin "$PR_BRANCH" --depth=50 --quiet 2>/dev/null || true
git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" FETCH_HEAD --quiet 2>/dev/null || \
    git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" "origin/$PR_BRANCH" --quiet
```

The FETCH_HEAD line may not resolve cleanly in the shared clone (FETCH_HEAD is per-clone), so the fallback uses `origin/$PR_BRANCH`.

- [ ] **Step 2: at the end of `lib/review-one-pr.sh`, add workdir cleanup**

Just before the final `exit 0`, after `preserve_scratch`, add:

```bash
# Clean up the per-PR workdir. Scratch is already preserved to
# $STATE_DIR/last-run-scratch by preserve_scratch().
rm -rf "$REPO_DIR"
```

- [ ] **Step 3: add the same cleanup in all error-exit paths**

Every `exit 1` in the worker after `REPO_DIR` has been created needs the same `rm -rf "$REPO_DIR"` before it. Search and update:

```bash
grep -n 'exit 1' ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
```

For each of the 4-5 `exit 1` sites after the workdir is created, add `rm -rf "$REPO_DIR"` on the line before. Example:

```bash
    log "$PR_ID: aggregator output empty — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
```

(If the exit is BEFORE the workdir is created — e.g., the `TEST_EXIT -eq 127` case — do NOT add `rm -rf "$REPO_DIR"`. Check each site.)

Note: the `TEST_EXIT -eq 127` exit IS after workdir creation; add the `rm -rf` there too.

- [ ] **Step 4: syntax check**

```bash
bash -n ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh && echo "OK"
```

- [ ] **Step 5: smoke test the shared clone**

```bash
# Simulate what the worker does
REPO=cncorp/plow
CANONICAL="$HOME/.pr-reviewer/repos/cncorp_plow"
PR_NUM=$(gh pr list --repo "$REPO" --state all --limit 5 --json number --jq '.[0].number')
PR_BRANCH=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq '.headRefName')
echo "testing with PR #$PR_NUM on branch $PR_BRANCH"

TMPDIR=/tmp/pr-review-smoke
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
git clone --shared "$CANONICAL" "$TMPDIR" --no-single-branch --quiet
du -sh "$TMPDIR/.git"         # should be small (<5 MB)
du -sh "$CANONICAL/.git"      # source is bigger
git -C "$TMPDIR" fetch origin "$PR_BRANCH" --depth=50 --quiet || echo "fetch failed"
git -C "$TMPDIR" checkout -B "pr-$PR_NUM" "origin/$PR_BRANCH" --quiet && echo "checkout OK"
ls "$TMPDIR" | head -5
rm -rf "$TMPDIR"
```

Expected: clone is small (`.git/objects/info/alternates` points at the canonical clone), checkout succeeds, files from the PR branch appear in the workdir.

- [ ] **Step 6: smoke test one review end-to-end with the new workdir**

Same stub-based test as Task 2 Step 5. Pick a PR, clear state, stub `gh pr comment`, run `review.sh`. After the run, verify:

```bash
ls /tmp/pr-review/ 2>&1  # should be empty (cleanup ran)
```

Expected: empty `/tmp/pr-review/` (workdir cleaned up), review logs look normal, state is updated.

- [ ] **Step 7: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio commit -am "Per-PR workdir at /tmp/pr-review/<slug>__<pr>/ via git clone --shared"
```

---

## Task 4: Per-PR lock via `flock`

**Purpose:** Even with per-PR workdirs, two ticks could in theory try to review the same PR concurrently (e.g., a SHA-change tick starts, then before it finishes, a `/review` mention triggers another). Hold an advisory flock per PR so the second attempt no-ops.

**Files:**
- Modify: `lib/review-one-pr.sh` — acquire per-PR flock at start, auto-release on exit.

- [ ] **Step 1: add the per-PR lock block at the top of the worker, right after the argument parsing**

In `lib/review-one-pr.sh`, after the `PR_URL="https://..."` line, insert:

```bash
# --- per-PR advisory lock ----------------------------------------------------
# Prevents two concurrent invocations from stepping on each other for the same
# PR. If we can't acquire, exit silently — the other invocation will finish.
PR_SLUG_FULL="${REPO//\//_}__${PR_NUM}"
PR_LOCK_DIR="/tmp/pr-review-locks"
mkdir -p "$PR_LOCK_DIR"
PR_LOCK_FILE="${PR_LOCK_DIR}/${PR_SLUG_FULL}"
exec {PR_LOCK_FD}> "$PR_LOCK_FILE"
if ! flock -n "$PR_LOCK_FD"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $PR_ID: another review in flight — skipping this invocation" \
        | tee -a "$LOG_FILE"
    exit 0
fi
# flock is held for the lifetime of the PR_LOCK_FD file descriptor; it
# releases automatically when the script exits (success or failure).
```

Note: this block runs BEFORE `state-io.sh` is sourced, so `log` isn't yet available — use raw echo for the contention-log line.

- [ ] **Step 2: syntax check**

```bash
bash -n ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh && echo "OK"
```

- [ ] **Step 3: smoke test the lock**

```bash
# Simulate two invocations of the worker for the same PR. The second should
# bail quickly because the first holds the lock.
REPO="fake/repo"
PR_NUM=99999
PR_LOCK_DIR=/tmp/pr-review-locks
rm -rf "$PR_LOCK_DIR"
mkdir -p "$PR_LOCK_DIR"

(
    # Simulate a long-running first invocation
    exec {fd}> "$PR_LOCK_DIR/${REPO//\//_}__${PR_NUM}"
    flock "$fd"
    sleep 3
) &
first_pid=$!
sleep 0.5  # ensure first holds the lock

# Now run the worker; should skip.
(
    REPO="$REPO" PR_NUM="$PR_NUM"
    PR_SLUG_FULL="${REPO//\//_}__${PR_NUM}"
    PR_LOCK_FILE="$PR_LOCK_DIR/$PR_SLUG_FULL"
    exec {fd2}> "$PR_LOCK_FILE"
    if flock -n "$fd2"; then
        echo "acquired lock (UNEXPECTED — first holder didn't block us)"
    else
        echo "skipped: another review in flight (EXPECTED)"
    fi
)

wait "$first_pid"
rm -rf "$PR_LOCK_DIR"
```

Expected: output includes `skipped: another review in flight (EXPECTED)`.

- [ ] **Step 4: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio commit -am "Per-PR advisory flock — second concurrent invocation for same PR no-ops"
```

---

## Task 5: Orchestrator refactor — enumerate eligible PRs, fan out with `MAX_CONCURRENT=3`

**Purpose:** Replace the orchestrator's serial for-loop with: enumerate all eligible PRs first, then fan out workers in background with `wait -n` bounding concurrency. Remove the global `/tmp/pr-reviewer.lock` (per-PR flocks are sufficient).

**Files:**
- Modify: `review.sh` — this is the core change.

- [ ] **Step 1: rewrite `review.sh`**

Replace the entire contents of `~/Hacking/knightwatch-reviewer/review.sh` with:

```bash
#!/bin/bash
# Orchestrator: enumerate eligible PRs across all tracked repos and fan out
# per-PR reviews via lib/review-one-pr.sh. Up to MAX_CONCURRENT reviews run
# concurrently per service tick. Per-PR locking is handled by the worker.

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

STATE_DIR="$HOME/.pr-reviewer"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/review.log"
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server" "srosro/knightwatch-reviewer")
REPOS_DIR="$STATE_DIR/repos"
STABLE_SECS=$((2 * 3600))
MAX_CONCURRENT="${MAX_CONCURRENT:-3}"

[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Rotate logs when they exceed 5MB.
for _log in "$LOG_FILE" "$STATE_DIR/cron.log"; do
    if [ -f "$_log" ] && [ "$(stat -c%s "$_log" 2>/dev/null)" -gt 5242880 ]; then
        mv "$_log" "$_log.1"
    fi
done

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
mkdir -p "$STATE_DIR" "$REPOS_DIR" /tmp/pr-review /tmp/pr-review-locks

. "$HOME/.pr-reviewer/lib/state-io.sh"

# ---------- enumerate eligible PRs ----------
declare -a ELIGIBLE=()

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number,title,headRefName,headRefOid 2>/dev/null) || {
        log "Failed to list PRs for $REPO"
        continue
    }
    [ "$(echo "$PR_LIST" | jq 'length')" -eq 0 ] && continue

    while IFS= read -r PR_JSON; do
        PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
        PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
        PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
        PR_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid')
        PR_ID="${REPO}#${PR_NUM}"

        KNOWN_SHA=$(state_get "$PR_ID" "sha")
        FORCE_REVIEW=false
        FORCE_WHOLE_PR=false

        if [ -n "$KNOWN_SHA" ]; then
            REVIEWED_AT=$(state_get "$PR_ID" "reviewed_at")
            REVIEWED_AT_ISO=$(date -d "@${REVIEWED_AT}" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
            COMMENTS_JSON=$(gh api "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null)
            WHOLE_MENTION=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" \
                    '[.[] | select(.created_at > $since and (.body | test("/review"; "i")))] | length')
            INCREMENTAL_MENTION=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" --arg user "$BOT_USER" \
                    '[.[] | select(.created_at > $since and (.body | test("@" + $user; "i")) and ((.body | test("/review"; "i")) | not))] | length')
            if [ "${WHOLE_MENTION:-0}" -gt 0 ]; then
                log "$PR_ID: /review requested — whole-PR re-review"
                FORCE_REVIEW=true
                FORCE_WHOLE_PR=true
            elif [ "${INCREMENTAL_MENTION:-0}" -gt 0 ]; then
                log "$PR_ID: @$BOT_USER mentioned — incremental re-review"
                FORCE_REVIEW=true
            fi
        fi

        # Skip if same SHA and not forced.
        if [ "$PR_SHA" = "$KNOWN_SHA" ] && [ "$FORCE_REVIEW" = "false" ]; then
            continue
        fi

        # Stability cooldown for non-forced re-reviews.
        if [ -n "$KNOWN_SHA" ] && [ "$FORCE_REVIEW" = "false" ]; then
            LAST_COMMIT_DATE=$(gh api "repos/$REPO/pulls/$PR_NUM/commits" --jq '.[-1].commit.committer.date' 2>/dev/null)
            if [ -z "$LAST_COMMIT_DATE" ]; then
                log "$PR_ID: could not get commit date, skipping"
                continue
            fi
            LAST_COMMIT_TS=$(date -d "$LAST_COMMIT_DATE" +%s)
            AGE_SECS=$(( $(date +%s) - LAST_COMMIT_TS ))
            if [ "$AGE_SECS" -lt "$STABLE_SECS" ]; then
                log "$PR_ID: last commit $(( AGE_SECS / 60 ))m ago — waiting for $(( STABLE_SECS / 3600 ))h stability"
                continue
            fi
        fi

        # Encode as tab-separated spec so titles with spaces survive.
        ELIGIBLE+=("$REPO"$'\t'"$PR_NUM"$'\t'"$PR_SHA"$'\t'"$PR_BRANCH"$'\t'"$PR_TITLE"$'\t'"$FORCE_WHOLE_PR")
    done < <(echo "$PR_LIST" | jq -c '.[]')
done

if [ ${#ELIGIBLE[@]} -eq 0 ]; then
    log "No PRs need review"
    exit 0
fi

log "Fan-out: ${#ELIGIBLE[@]} eligible PR(s), max $MAX_CONCURRENT concurrent"

# ---------- fan out with bounded concurrency ----------
active=0
for spec in "${ELIGIBLE[@]}"; do
    IFS=$'\t' read -r REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR <<< "$spec"

    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        wait -n
        active=$((active - 1))
    done

    ~/.pr-reviewer/lib/review-one-pr.sh "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
    active=$((active + 1))
done

wait
log "Fan-out complete (${#ELIGIBLE[@]} review(s) ended)"
exit 0
```

Note: the global `LOCK_FILE` and its trap are gone. Per-PR flocks inside the worker handle the same-PR contention case; the systemd unit itself (oneshot + `StartLimit`) prevents the whole service from running twice at once.

- [ ] **Step 2: remove the now-unused global lock block — already done above by full replacement**

Confirm by grepping:

```bash
grep -n LOCK_FILE ~/Hacking/knightwatch-reviewer/review.sh
```

Expected: no matches (or only unrelated comments).

- [ ] **Step 3: syntax check**

```bash
bash -n ~/Hacking/knightwatch-reviewer/review.sh && echo "OK"
```

- [ ] **Step 4: smoke test enumeration only (no eligible PRs)**

Run the orchestrator when nothing needs review. Should log "No PRs need review" and exit cleanly:

```bash
# If no PRs need review, the tool just logs and exits.
~/Hacking/knightwatch-reviewer/review.sh 2>&1 | tail -3
```

Expected: `No PRs need review` and exit 0.

- [ ] **Step 5: smoke test fan-out with 2 PRs (stub posts)**

Temporarily stub `gh pr comment` in the worker; clear state for 2 PRs; run orchestrator; verify both reviews run concurrently.

```bash
# Stub
cp ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh /tmp/worker.bak
sed -i 's|^gh pr comment|echo DRYRUN gh pr comment|; s|^    gh pr review|    echo DRYRUN gh pr review|' ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh

# Clear 2 PRs from state so both are eligible simultaneously
TARGETS=$(jq -r 'keys | .[0:2] | .[]' ~/.pr-reviewer/state.json)
for k in $TARGETS; do
    jq --arg k "$k" 'del(.[$k])' ~/.pr-reviewer/state.json > /tmp/state.json.new && mv /tmp/state.json.new ~/.pr-reviewer/state.json
done

# Run
MAX_CONCURRENT=2 ~/Hacking/knightwatch-reviewer/review.sh

# Restore worker
cp /tmp/worker.bak ~/Hacking/knightwatch-reviewer/lib/review-one-pr.sh
```

Expected: orchestrator logs "Fan-out: 2 eligible PR(s), max 2 concurrent", two workers run concurrently (their log lines interleave — stage names appear out of chronological order for the two PR IDs), both post DRYRUN comments, state is updated for both.

- [ ] **Step 6: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio commit -am "Orchestrator fan-out (MAX_CONCURRENT=3); drop global lock"
```

---

## Task 6: Widen systemd `TimeoutStartSec` and bump unit for fan-out

**Purpose:** Current `TimeoutStartSec=60min` assumes one ~20-min review. With fan-out, worst-case scenario is 3 concurrent reviews running through back-to-back, potentially ~30-40 min of wall time. Bump to 90 min.

**Files:**
- Modify: `systemd/pr-reviewer.service`

- [ ] **Step 1: edit the unit**

In `~/Hacking/knightwatch-reviewer/systemd/pr-reviewer.service`, change:

```
TimeoutStartSec=60min
```

to:

```
TimeoutStartSec=90min
```

- [ ] **Step 2: stage the updated unit to /tmp for sudo install**

```bash
cp ~/Hacking/knightwatch-reviewer/systemd/pr-reviewer.service /tmp/
diff /etc/systemd/system/pr-reviewer.service /tmp/pr-reviewer.service
```

Expected: one-line diff showing the TimeoutStartSec change.

- [ ] **Step 3: request the user run the sudo cycle**

Print the commands for the user to run:

```
sudo cp /tmp/pr-reviewer.service /etc/systemd/system/
sudo systemctl daemon-reload
```

Do NOT run them yourself. Wait for the user to confirm they ran them. (No need to restart the timer — the next tick picks up the new unit.)

- [ ] **Step 4: commit**

```bash
cd ~/Hacking/knightwatch-reviewer && \
  git -c user.email=eng@plow.co -c user.name=odio commit -am "systemd: TimeoutStartSec 60min -> 90min for concurrent reviews"
```

---

## Task 7: Live validation — trigger 3 concurrent reviews

**Purpose:** Confirm the end-to-end behavior in production: three PRs reviewed in parallel in one tick, all post cleanly, state updated for all three, no resource issues.

**Files:** none modified.

- [ ] **Step 1: confirm sudo cycle from Task 6 completed**

```bash
diff /etc/systemd/system/pr-reviewer.service ~/Hacking/knightwatch-reviewer/systemd/pr-reviewer.service
```

Expected: no output (identical). If they differ, do not proceed — ask user to re-run the sudo block.

- [ ] **Step 2: confirm the timer is active + fires on schedule**

```bash
systemctl list-timers pr-reviewer.timer --no-pager | head -3
```

Expected: `NEXT` shows a future time within 2 minutes.

- [ ] **Step 3: pick 3 low-risk target PRs and clear their state**

Pick 3 PRs from state.json whose reviews you wouldn't mind being re-posted. Small PRs are ideal. Example:

```bash
# Inspect
jq -r 'keys | .[:5] | .[]' ~/.pr-reviewer/state.json

# Clear three (replace with actual keys)
for k in "srosro/knightwatch-reviewer#1" "srosro/tkmx-client#5" "srosro/tkmx-server#3"; do
    jq --arg k "$k" 'del(.[$k])' ~/.pr-reviewer/state.json > /tmp/state.json.new && mv /tmp/state.json.new ~/.pr-reviewer/state.json
done
```

Note: picking PRs from 3 different repos avoids `just test` collision if any still exists. Plow PRs are fine too since the user stated plow's `just test` is parallel-safe.

- [ ] **Step 4: watch the next tick**

```bash
journalctl -u pr-reviewer.service -f --since "now" -o cat | \
    grep --line-buffered -E "Fan-out|Eligible|Reviewing|specialists completed|critic|aggregator|Posted|Done with|review.one.pr|aborting"
```

Expected sequence (interleaved across three PRs):

```
[timestamp] Fan-out: 3 eligible PR(s), max 3 concurrent
[timestamp] Reviewing PR_A (force_whole_pr=false)
[timestamp] Reviewing PR_B (force_whole_pr=false)
[timestamp] Reviewing PR_C (force_whole_pr=false)
[timestamp] PR_A: running `just test`...
[timestamp] PR_B: running `just test`...
[timestamp] PR_C: running `just test`...
... (interleaved stages) ...
[timestamp] Posted review comment on PR_A
[timestamp] Posted review comment on PR_B
[timestamp] Posted review comment on PR_C
[timestamp] Fan-out complete (3 review(s) ended)
```

- [ ] **Step 5: check resource metrics during the concurrent run**

In a second shell during the run:

```bash
watch -n 5 '
  echo "--- memory ---"
  free -h
  echo "--- codex processes ---"
  ps -C codex --no-headers | wc -l
  echo "--- specialist processes ---"
  pgrep -f run-specialist.sh | wc -l
'
```

Expected: ~15 `codex` processes (5 specialists × 3 PRs), ~5-8 GB used, no swap pressure, no OOM.

- [ ] **Step 6: after all three post, verify state**

```bash
for k in "srosro/knightwatch-reviewer#1" "srosro/tkmx-client#5" "srosro/tkmx-server#3"; do
    jq --arg k "$k" '.[$k] | {sha: .sha[:8], reviewed_at: (.reviewed_at|todate), approved}' ~/.pr-reviewer/state.json
done
```

Expected: all three entries present with fresh timestamps.

- [ ] **Step 7: verify workdir cleanup**

```bash
ls /tmp/pr-review/ 2>&1
```

Expected: empty (workers cleaned up after success). `PrivateTmp=yes` would also wipe this on service teardown, but the explicit cleanup in the worker is defense in depth.

- [ ] **Step 8: If anything looked bad, investigate before declaring done**

Failure modes to watch for:
- Workers race on state.json → entries missing. Check all three reviews appear in state. If not, review `state-io.sh` flock behavior.
- Specialist `codex exec` failures due to API rate-limit → look for HTTP 429 in journal.
- `just test` collisions → watch for Docker container name conflicts or port-in-use errors in `/tmp/review-tests-*.log`.

If any of the above fires, reduce `MAX_CONCURRENT` to 2 in `review.sh` and retest. If still bad, escalate.

- [ ] **Step 9: done — no commit for this task unless something was tweaked**

---

## Self-Review

**1. Spec coverage:**

- Enumerate all eligible PRs per tick → Task 5 (orchestrator rewrite).
- Up to 3 concurrent reviews → Task 5 (`MAX_CONCURRENT=3`, `wait -n` loop).
- Per-PR workdir → Task 3 (`git clone --shared` at `/tmp/pr-review/<slug>__<pr>/`).
- Per-PR scratch → inherited: `.codex-scratch/` lives inside the per-PR workdir already, so Task 3 implicitly gives us per-PR scratch.
- Per-PR lock → Task 4 (flock on `/tmp/pr-review-locks/<slug>__<pr>`).
- No git worktrees → Task 3 explicitly uses `git clone --shared`.
- State.json race-free → Task 1 (flock-serialized state_set).
- User's 128 GB RAM validates the concurrency target; no memory budget gating.
- User's "plow just test is parallel-safe" — assumed, verified in Task 7 Step 5/8.

All spec items accounted for.

**2. Placeholder scan:**

No "TBD", "implement later", "similar to Task N", or code-less change steps. Every step includes either the exact command or the exact code block to write. Smoke tests specify expected output.

**3. Type / name consistency checks:**

- `$PR_SLUG_FULL` used in Task 4 (per-PR lock) consistent with `${REPO_SLUG}__${PR_NUM}` elsewhere. ✓
- `/tmp/pr-review/${PR_SLUG}` (Task 3 workdir) and `/tmp/pr-review-locks/${PR_SLUG_FULL}` (Task 4 lock) — both derive from the same `REPO_SLUG__PR_NUM` convention. ✓ (Minor: variable is called `PR_SLUG` in Task 3 and `PR_SLUG_FULL` in Task 4. Consistent content, consistent file path, naming difference is cosmetic. An agent implementing both tasks should normalize to one name — either works, but pick one during Task 4 and reuse it.)
- `CANONICAL_DIR` (Task 3) vs. `REPOS_DIR/<slug>` (rest of codebase) — these refer to the same directory. Task 3 introduces `CANONICAL_DIR` as a clearer local variable. Consistent.
- `state_set` signature (`pr_id sha approved body`) and `state_get` (`pr_id key`) — consistent between `lib/state-io.sh` (Task 1) and the worker (Task 2 call sites).
- `build_specialist_prompt` signature (`name file pr_id pr_title pr_url`) — consistent.

**4. Concerns worth calling out during execution:**

- Git stale locks in the canonical clone: two workers fetching simultaneously into `$CANONICAL_DIR` could in theory race on `.git/index.lock` or `.git/refs/heads/.lock`. Git's own locking usually handles this, but if we hit errors on the `fetch origin` calls in step 1 of Task 3's worker replacement, we should serialize fetches via a per-canonical-clone flock. Leaving as a known-risk; the first full concurrent run will tell us.
- `gh pr comment` rate limits: unlikely to matter at 3 concurrent posts per tick, but noted.
- `preserve_scratch` moves `.codex-scratch/` to `$STATE_DIR/last-run-scratch/`. Multiple concurrent workers moving different `.codex-scratch/` directories into keyed subdirectories under `last-run-scratch/` are fine (no shared key).
- `kid-last-failure` file: global, not per-PR. If two workers both fail kid concurrently, the last-writer wins. Acceptable — it's a sticky debug flag, not state.
