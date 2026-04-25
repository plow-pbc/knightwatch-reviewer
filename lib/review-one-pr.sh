#!/bin/bash
# Reviews one PR end-to-end. Invoked by review.sh as:
#   TRIGGER_COMMENT_FILE=<path> lib/review-one-pr.sh REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# where FORCE_WHOLE_PR is "true" or "false". TRIGGER_COMMENT_FILE is
# optional and points to a tmp file holding the body of the comment that
# kicked off this review (when triggered by /review or @bot mention);
# the worker slurps it and rm -fs the file early.

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

# Trigger-comment context: review.sh sets TRIGGER_COMMENT_FILE to a tmp
# path holding the body of the comment that kicked off this review (when
# the trigger was a /review or @bot mention). Slurp it now and rm -f
# eagerly so the tmp file doesn't survive past this worker, regardless
# of which exit path we take below. Empty string when this review
# wasn't triggered by a comment.
TRIGGER_COMMENT_BODY=""
if [ -n "${TRIGGER_COMMENT_FILE:-}" ] && [ -f "${TRIGGER_COMMENT_FILE}" ]; then
    TRIGGER_COMMENT_BODY=$(cat "${TRIGGER_COMMENT_FILE}")
    rm -f "${TRIGGER_COMMENT_FILE}"
fi

# Captured here (before anything that can take minutes: just test, specialists,
# aggregator) and stamped into state.reviewed_at on success. The orchestrator
# filters "new comments since last review" with created_at > reviewed_at, so if
# we stamped completion time instead, a /review posted during this run would
# fall before the stamp and be invisible to the next tick.
REVIEW_START_TS=$(date +%s)

# --- per-PR advisory lock ----------------------------------------------------
# Prevents two concurrent invocations from stepping on each other for the same
# PR. If we can't acquire, exit silently (with a log line) — the other
# invocation will finish its own work.
#
# NB: this block runs BEFORE state-io.sh is sourced, so `log` isn't yet
# available. Use raw echo+tee for the contention message. We also don't have
# LOG_FILE defaulted yet, so fall back to $STATE_DIR/review.log or /dev/null.
PR_LOCK_SLUG="${REPO//\//_}__${PR_NUM}"
PR_LOCK_DIR="/tmp/pr-review-locks"
mkdir -p "$PR_LOCK_DIR"
PR_LOCK_FILE="${PR_LOCK_DIR}/${PR_LOCK_SLUG}"
exec {PR_LOCK_FD}> "$PR_LOCK_FILE"
if ! flock -n "$PR_LOCK_FD"; then
    _raw_log="${LOG_FILE:-${STATE_DIR:-$HOME/.pr-reviewer}/review.log}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $PR_ID: another review already in flight (lock held on $PR_LOCK_FILE) — skipping this invocation" \
        | tee -a "$_raw_log" 2>/dev/null || true
    exit 0
fi
# flock is held for the lifetime of PR_LOCK_FD; releases automatically on exit.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/review.log}"
REPOS_DIR="${REPOS_DIR:-$STATE_DIR/repos}"
# Per-PR workdirs live under $STATE_DIR (not /tmp). When the service runs with
# PrivateTmp=yes, /tmp is a unit-private mount — codex 0.122's unified-exec
# helper doesn't inherit that namespace and fails to find cwds under /tmp.
WORKDIRS_DIR="${WORKDIRS_DIR:-$STATE_DIR/workdirs}"

[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"

# Source state-io. Prefer REVIEWER_LIB_DIR if caller set it (smoke-test
# isolation); fall back to the worker's own directory.
_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LIB_DIR/state-io.sh"

# --- prompt-build helpers (sourced from lib/prompt-build.sh) ---
. "$_LIB_DIR/prompt-build.sh"

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

# Canonical clone lives at $REPOS_DIR/<slug>/ and is the source of truth for
# `fetch`. Multiple PR reviews on the same repo coexist by each working in
# their own per-PR workdir that shares objects (via git clone --shared) with
# the canonical clone.
#
# A repo-scoped flock serializes canonical clone/fetch and the per-PR
# shared-clone read. Without this, two workers on the same repo race through
# `git fetch` and can hand a half-initialized object store to `git clone
# --shared`. The lock is released before the slow specialist/aggregator
# phases, so cross-repo fan-out remains fully parallel and same-repo fan-out
# is only serialized for the short clone/fetch window.
REPO_SLUG=$(echo "$REPO" | tr '/' '_')
CANONICAL_DIR="$REPOS_DIR/$REPO_SLUG"
PR_WORKDIR_SLUG="${REPO_SLUG}__${PR_NUM}"
REPO_DIR="$WORKDIRS_DIR/${PR_WORKDIR_SLUG}"

CANONICAL_LOCK_DIR="$STATE_DIR/canonical-locks"
mkdir -p "$CANONICAL_LOCK_DIR"
CANONICAL_LOCK_FILE="$CANONICAL_LOCK_DIR/$REPO_SLUG"
exec {CANONICAL_LOCK_FD}> "$CANONICAL_LOCK_FILE"
flock "$CANONICAL_LOCK_FD" || { log "$PR_ID: canonical flock failed — aborting"; exit 1; }

if [ ! -d "$CANONICAL_DIR/.git" ]; then
    log "Cloning canonical $REPO..."
    if ! gh repo clone "$REPO" "$CANONICAL_DIR" -- --depth=50 --no-single-branch; then
        log "$PR_ID: canonical clone failed — aborting"
        exit 1
    fi
fi

# Fetch latest refs into the canonical clone. We fetch the PR head via
# `refs/pull/N/head` rather than by branch name, so fork PRs work
# uniformly with same-repo PRs (fork PRs' heads live on the fork, not
# on the base repo, so `origin/$PR_BRANCH` doesn't exist there — but
# GitHub mirrors every open PR's head at `refs/pull/N/head` on the base
# repo regardless of source). We still alias it into `refs/heads/
# $PR_BRANCH` so downstream code (per-PR workdir checkout, diff, log
# messages) can use the human-readable branch name.
#
# The default branch stays as a plain fetch (updating only refs/remotes/
# origin/$DEFAULT_BRANCH) because canonical has $DEFAULT_BRANCH checked
# out and git refuses to force-update a checked-out ref. Stale local
# main is fine for our use — we only need it for listing touched files.
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
if [ -z "$DEFAULT_BRANCH" ]; then
    log "$PR_ID: could not resolve default branch from gh repo view — aborting"
    exit 1
fi
if ! git -C "$CANONICAL_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet; then
    log "$PR_ID: canonical fetch of $DEFAULT_BRANCH failed — aborting"
    exit 1
fi
if ! git -C "$CANONICAL_DIR" fetch origin "+refs/pull/$PR_NUM/head:$PR_BRANCH" --depth=50 --quiet; then
    log "$PR_ID: refs/pull/$PR_NUM/head not fetchable (PR closed?) — skipping"
    exit 0
fi

# Tear down any stale per-PR workdir and create a fresh shared clone.
# --shared gives us hardlinked objects from canonical, so this is cheap.
# Canonical's refs/heads/$PR_BRANCH shows up here as origin/$PR_BRANCH.
rm -rf "$REPO_DIR"
mkdir -p "$(dirname "$REPO_DIR")"
if ! git clone --shared "$CANONICAL_DIR" "$REPO_DIR" --no-single-branch --quiet; then
    log "$PR_ID: git clone --shared failed — aborting"
    exit 1
fi

# Release the canonical lock now; the rest of the worker operates in
# $REPO_DIR and doesn't touch canonical object state.
exec {CANONICAL_LOCK_FD}>&-

# Check out the PR branch. Fail loud if it isn't there — silently falling
# back to the default branch (as the old code did) made every incremental
# re-review diff against the wrong base.
if ! git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" "origin/$PR_BRANCH" --quiet; then
    log "$PR_ID: checkout of origin/$PR_BRANCH failed in workdir — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Mirror gitignored env files from canonical into the workdir. `git clone
# --shared` only carries tracked content, so .env files the user keeps in
# canonical's working tree (e.g. live-API credentials for `just test`'s
# scenario suites) never land here, and recipes that source them trip
# `${ANTHROPIC_API_KEY:?...}`-style guards identically on every PR. For
# each `.env*.example` the repo ships, copy the matching real env file
# (name minus `.example`) from canonical if one exists. Deleted right
# after `just test` so secret-bearing files don't linger.
COPIED_ENV_FILES=()
while IFS= read -r -d '' example_path; do
    rel="${example_path#$REPO_DIR/}"
    target_rel="${rel%.example}"
    canonical_src="$CANONICAL_DIR/$target_rel"
    workdir_dst="$REPO_DIR/$target_rel"
    if [ -e "$canonical_src" ] && [ ! -e "$workdir_dst" ]; then
        cp -L "$canonical_src" "$workdir_dst"
        COPIED_ENV_FILES+=("$workdir_dst")
    fi
done < <(find "$REPO_DIR" -type f -name '.env*.example' \
    -not -path '*/.git/*' -not -path '*/node_modules/*' -print0)
[ "${#COPIED_ENV_FILES[@]}" -gt 0 ] && \
    log "$PR_ID: mirrored ${#COPIED_ENV_FILES[@]} env file(s) from canonical"

# ---- just test ----
TEST_LOG="$REPO_DIR/.test-output.log"
TEST_TIMEOUT=30m
log "$PR_ID: running \`just test\` (timeout ${TEST_TIMEOUT})..."
(cd "$REPO_DIR" && timeout "$TEST_TIMEOUT" just test) > "$TEST_LOG" 2>&1
TEST_EXIT=$?
# Env files were only needed for `just test`; delete eagerly so secrets
# don't sit in the workdir during the long specialist phase. REPO_DIR
# is also rm -rf'd on every exit path below, so this is a belt-and-
# suspenders early sweep, not the only cleanup.
for f in "${COPIED_ENV_FILES[@]}"; do
    rm -f "$f"
done
if [ "$TEST_EXIT" -eq 127 ]; then
    log "$PR_ID: 'just test' not available (exit 127) — aborting; check just is installed and a justfile exists at repo root"
    rm -rf "$REPO_DIR"
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
PREV_APPROVED=""
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
        # Specialists work the incremental diff; the aggregator separately
        # gets the full PR diff so it can verify whether prior blocking
        # findings touch code that's actually changed in this PR vs. has
        # been left as-is and is still unaddressed.
        FULL_PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
        if [ -z "$FULL_PR_DIFF" ]; then
            log "$PR_ID: full-PR diff fetch returned empty — re-review will run without full-diff.patch and the aggregator's prior-finding verification is degraded"
        fi
    else
        log "$PR_ID: prior SHA $KNOWN_SHA not in local history; using full PR diff"
        KID_INPUT_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
        FULL_PR_DIFF="$KID_INPUT_DIFF"
    fi
    REVIEW_TASK="Re-review: the author has pushed new commits since your previous review (at ${KNOWN_SHA:0:7}, approved=$PREV_APPROVED). Your prior review is in .codex-scratch/previous-review.md. The incremental diff since that review is in .codex-scratch/diff.patch; the full PR diff is in .codex-scratch/full-diff.patch (consult it when verifying whether prior findings are addressed). Assess whether the new commits address your prior concerns, then produce an updated review."
fi

if [ -z "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: empty diff — gh pr diff / git diff returned nothing (possible auth, network, or rebase issue), aborting"
    rm -rf "$REPO_DIR"
    exit 1
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
[ -n "${FULL_PR_DIFF:-}" ] && \
    write_scratch "$REPO_DIR" "full-diff.patch" "$FULL_PR_DIFF"
[ -n "$TRIGGER_COMMENT_BODY" ] && \
    write_scratch "$REPO_DIR" "trigger-comment.md" "$TRIGGER_COMMENT_BODY"

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

PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,author,commits,closingIssuesReferences 2>/dev/null)
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
if [ -z "$PR_AUTHOR" ]; then
    log "$PR_ID: gh pr view returned no author handle — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
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

COMMITS=$(printf '%s' "$PR_DATA" | jq -r '.commits[]? | "\(.oid[0:7]) \(.messageHeadline)"')
if [ -z "$COMMITS" ]; then
    log "$PR_ID: gh pr view returned no commits — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
write_scratch "$REPO_DIR" "commits.md" "$COMMITS"

SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
mkdir -p "$SPECIALISTS_DIR"

# Post a "reviewing" status comment so the PR author sees the bot picked up
# the work. Best-effort — failure here doesn't block the actual review.
gh pr comment "$PR_NUM" --repo "$REPO" \
    --body "👀 reviewing — [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)" \
    >/dev/null 2>&1 || log "$PR_ID: failed to post reviewing-status comment (continuing)"

log "$PR_ID: inferring developer intent..."
INTENT_PROMPT=$(substitute_placeholders \
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

INTENT_NONBLANK_LINES=$(grep -cv '^[[:space:]]*$' "$INTENT_OUT")
if [ "$INTENT_NONBLANK_LINES" -ne 1 ]; then
    log "$PR_ID: intent output has $INTENT_NONBLANK_LINES non-blank lines, expected exactly 1 — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi

if ! grep -q '^Inferred intent: ' "$INTENT_OUT"; then
    log "$PR_ID: intent output missing 'Inferred intent: ' prefix — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi

log "$PR_ID: intent inference complete: $(head -1 "$INTENT_OUT")"

log "$PR_ID: launching 5 specialists in parallel..."
for angle in security data-integrity architecture simplification tests; do
    PROMPT=$(build_specialist_prompt \
        "$angle" \
        "$HOME/.pr-reviewer/prompts/${angle}.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
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
    rm -rf "$REPO_DIR"
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
AGG_PROMPT=$(build_specialist_prompt \
    "aggregator" \
    "$HOME/.pr-reviewer/prompts/aggregator.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
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
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW=$(cat "$AGG_OUT")
if ! echo "$REVIEW" | grep -q '^VERDICT:'; then
    log "$PR_ID: aggregator output missing VERDICT line — aborting"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
VERDICT=$(echo "$REVIEW" | grep '^VERDICT:' | tail -1)
COMMENT_BODY=$(echo "$REVIEW" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/{ N; /^\n$/d }')
if [ -z "$COMMENT_BODY" ]; then
    log "Empty review body for $PR_ID, skipping"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
COMMENT_BODY="$COMMENT_BODY

---

_Generated by [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)._"
if ! gh pr comment "$PR_NUM" --repo "$REPO" --body "$COMMENT_BODY"; then
    log "$PR_ID: gh pr comment FAILED — not updating state (next tick will retry)"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
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

if ! state_set "$PR_ID" "$PR_SHA" "$APPROVED" "$COMMENT_BODY" "$REVIEW_START_TS"; then
    log "$PR_ID: state_set FAILED — review posted but state.json not updated; next tick will re-review this SHA"
    preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
    rm -rf "$REPO_DIR"
    exit 1
fi
preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
rm -rf "$REPO_DIR"
log "Done with $PR_ID"
exit 0
