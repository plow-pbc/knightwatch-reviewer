#!/bin/bash
# Automated PR reviewer using Codex

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

LOCK_FILE="/tmp/pr-reviewer.lock"
STATE_DIR="$HOME/.pr-reviewer"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/review.log"
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server")
REPOS_DIR="$STATE_DIR/repos"
STABLE_SECS=$((2 * 3600))

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Rotate logs when they exceed 5MB (cron runs every 2min; logs grow fast)
for _log in "$LOG_FILE" "$STATE_DIR/cron.log"; do
    if [ -f "$_log" ] && [ "$(stat -c%s "$_log" 2>/dev/null)" -gt 5242880 ]; then
        mv "$_log" "$_log.1"
    fi
done

# Escape user-supplied text for use in a sed s||| replacement. Handles | & \.
safe_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Build a specialist prompt by substituting PR metadata into common-header.md
# and appending the specialist's angle prompt.
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

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

if [ -f "$LOCK_FILE" ]; then
    log "Review in progress, skipping"
    exit 0
fi

mkdir -p "$STATE_DIR" "$REPOS_DIR"
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

state_get() { jq -r --arg id "$1" --arg k "$2" '.[$id][$k] // empty' "$STATE_FILE"; }
state_set() {
    local pr_id="$1" sha="$2" approved="$3" body="$4"
    local tmp; tmp=$(jq --arg id "$pr_id" --arg sha "$sha" --arg body "$body" \
        --argjson ts "$(date +%s)" --argjson appr "$approved" \
        '.[$id] = {sha: $sha, reviewed_at: $ts, approved: $appr, body: $body}' "$STATE_FILE")
    echo "$tmp" > "$STATE_FILE"
}

# Per-PR scratch directory inside the repo workdir. Codex runs with
# -C $REPO_DIR, so scratch lives under $REPO_DIR. Cleaned up on exit.
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

        # Check for @srosro mention or /review tag since our last review
        if [ -n "$KNOWN_SHA" ]; then
            REVIEWED_AT=$(state_get "$PR_ID" "reviewed_at")
            REVIEWED_AT_ISO=$(date -d "@${REVIEWED_AT}" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
            MENTION_COUNT=$(gh api "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null |                 jq --arg since "$REVIEWED_AT_ISO"                 '[.[] | select(.created_at > $since and (.body | test("@srosro|/review"; "i")))] | length')
            if [ "${MENTION_COUNT:-0}" -gt 0 ]; then
                log "$PR_ID: tagged/refresh requested — forcing re-review"
                FORCE_REVIEW=true
            fi
        fi

        # Skip if same SHA and not forced
        if [ "$PR_SHA" = "$KNOWN_SHA" ] && [ "$FORCE_REVIEW" = "false" ]; then
            continue
        fi

        # For re-reviews only (and not forced): wait for the commit to stabilize
        # (STABLE_SECS) so we don't burn tokens re-reviewing on every push.
        if [ -n "$KNOWN_SHA" ] && [ "$FORCE_REVIEW" = "false" ]; then
            LAST_COMMIT_DATE=$(gh api "repos/$REPO/pulls/$PR_NUM/commits" \
                --jq '.[-1].commit.committer.date' 2>/dev/null)
            if [ -z "$LAST_COMMIT_DATE" ]; then
                log "$PR_ID: could not get commit date, skipping"
                continue
            fi
            LAST_COMMIT_TS=$(date -d "$LAST_COMMIT_DATE" +%s)
            AGE_SECS=$(( $(date +%s) - LAST_COMMIT_TS ))
            if [ "$AGE_SECS" -lt "$STABLE_SECS" ]; then
                log "$PR_ID: re-review pending — last commit $(( AGE_SECS / 60 ))m ago, waiting for $(( STABLE_SECS / 3600 ))h stability"
                continue
            fi
        fi

        log "Reviewing $PR_ID (force=$FORCE_REVIEW)"
        touch "$LOCK_FILE"

        # Clone or update repo
        REPO_SLUG=$(echo "$REPO" | tr '/' '_')
        REPO_DIR="$REPOS_DIR/$REPO_SLUG"
        if [ ! -d "$REPO_DIR/.git" ]; then
            log "Cloning $REPO..."
            gh repo clone "$REPO" "$REPO_DIR" -- --depth=50 --no-single-branch 2>&1 | tail -2
        fi

        DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
        git -C "$REPO_DIR" fetch origin "$DEFAULT_BRANCH" --depth=50 --quiet
        git -C "$REPO_DIR" fetch origin "$PR_BRANCH" --depth=50 --quiet
        git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" FETCH_HEAD --quiet

        # First thing after checkout: run `just test` and capture results.
        # Tests are treated as review content (a failure is a finding, not a
        # pipeline error). But a missing `just` / missing `justfile` IS a
        # pipeline error — fail loud.
        TEST_LOG="/tmp/review-tests-${REPO_SLUG}-${PR_NUM}.log"
        TEST_TIMEOUT=30m
        log "$PR_ID: running \`just test\` (timeout ${TEST_TIMEOUT})..."
        (cd "$REPO_DIR" && timeout "$TEST_TIMEOUT" just test) > "$TEST_LOG" 2>&1
        TEST_EXIT=$?
        if [ "$TEST_EXIT" -eq 127 ]; then
            log "$PR_ID: 'just test' not available (exit 127) — aborting; check just is installed and a justfile exists at repo root"
            rm -f "$LOCK_FILE"
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

        STANDARDS=""
        [ -f ~/.claude/CODING_STANDARDS.md ]     && STANDARDS+=$(cat ~/.claude/CODING_STANDARDS.md)
        STANDARDS+=$'\n\n'
        [ -f ~/.claude/REVIEW_PRACTICES.md ]     && STANDARDS+=$(cat ~/.claude/REVIEW_PRACTICES.md)
        STANDARDS+=$'\n\n'
        [ -f ~/.claude/TESTING.md ]              && STANDARDS+=$(cat ~/.claude/TESTING.md)
        STANDARDS+=$'\n\n'
        [ -f ~/.claude/COMMENT_REVIEW_MISTAKES.md ] && STANDARDS+="## Known Review Mistakes (avoid repeating these)\n"$(cat ~/.claude/COMMENT_REVIEW_MISTAKES.md)

        # Build review input depending on first review vs re-review
        PREV_BODY=""
        if [ -z "$KNOWN_SHA" ]; then
            KID_INPUT_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>/dev/null)
            REVIEW_TASK="Review the diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md."
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

        # Kid prior-art lookup. Per-repo index — plow uses a dedicated mirror
        # at ~/Hacking/plow-kid; tkmx repos are indexed in place. Prior-art
        # is nice-to-have, not a correctness gate. On failure: log loud,
        # write a sticky flag file, degrade to kid-less review.
        PRIOR_ART=""
        KID_FLAG="$STATE_DIR/kid-last-failure"
        case "$REPO" in
            "cncorp/plow")         KID_PROJECT_PATH="$HOME/Hacking/plow-kid" ;;
            "srosro/tkmx-client")  KID_PROJECT_PATH="$HOME/Hacking/tkmx-client" ;;
            "srosro/tkmx-server")  KID_PROJECT_PATH="$HOME/Hacking/tkmx-server" ;;
            *)                     KID_PROJECT_PATH="" ;;
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
            log "$PR_ID: kid index not yet built at $KID_PROJECT_PATH — skipping prior-art lookup (will be indexed on next refresh tick)"
        fi

        log "$PR_ID: diff is ${#KID_INPUT_DIFF} bytes"

        # Write all specialist inputs to the repo's scratch dir
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

        # Pre-compute recent git history for each touched file (5 most recent
        # commits each, capped at 30 files to avoid overwhelming the prompt on
        # huge merges). Gives specialists context for "is this file stable or
        # churny?" without each needing to run git log themselves. Specialists
        # can still run `git blame -L a,b <file>` on specific lines when intent
        # is unclear; this pre-compute is the starting surface.
        FILE_HISTORY=""
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            FILE_HISTORY+="### $f"$'\n'
            hist=$(git -C "$REPO_DIR" log --oneline -n 5 -- "$f" 2>/dev/null)
            FILE_HISTORY+="${hist:-(no history)}"$'\n\n'
        done < <(git -C "$REPO_DIR" diff --name-only "$DEFAULT_BRANCH"...HEAD 2>/dev/null | head -30)
        write_scratch "$REPO_DIR" "file-history.md" "${FILE_HISTORY:-(no touched files)}"

        # Pre-compute author intent: the PR's own description plus any linked
        # issues. Helps distinguish "author missed the invariant" from "author
        # is deliberately changing documented behavior."
        PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,closingIssuesReferences 2>/dev/null)
        AUTHOR_INTENT="## PR Title
$(printf '%s' "$PR_DATA" | jq -r '.title // empty')

## PR Description (author's own explanation)

$(printf '%s' "$PR_DATA" | jq -r '.body // "(no description provided)"')
"
        # Expand closing-issue references (issues this PR claims to close).
        # Cap at 5 to avoid runaway bodies on PRs that close many issues.
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

        PR_URL="https://github.com/$REPO/pull/$PR_NUM"
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
            rm -f "$LOCK_FILE"
            continue
        fi

        log "$PR_ID: all 5 specialists completed"

        for angle in security data-integrity architecture simplification tests; do
            LINES=$(wc -l < "$SPECIALISTS_DIR/${angle}.md")
            NO_FINDINGS=""
            grep -q '^No findings\.' "$SPECIALISTS_DIR/${angle}.md" && NO_FINDINGS=" (no findings)"
            log "$PR_ID: specialist=$angle lines=$LINES$NO_FINDINGS"
        done

        # ========== Stage 1 of 2: critic stress-tests specialist findings ==========
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
            log "$PR_ID: critic output empty — continuing without counterarguments (aggregator will fall back to raw specialist findings)"
            echo "(critic output empty — fall back)" > "$CRITIC_OUT"
        fi

        # ========== Stage 2 of 2: aggregator synthesizes final review ==========
        log "$PR_ID: aggregator (with critic input)..."
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
            rm -f "$LOCK_FILE"
            continue
        fi

        REVIEW=$(cat "$AGG_OUT")

        if ! echo "$REVIEW" | grep -q '^VERDICT:'; then
            log "$PR_ID: aggregator output missing VERDICT line — aborting"
            preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
            rm -f "$LOCK_FILE"
            continue
        fi

        VERDICT=$(echo "$REVIEW" | grep '^VERDICT:' | tail -1)
        COMMENT_BODY=$(echo "$REVIEW" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/{ N; /^\n$/d }')

        if [ -z "$COMMENT_BODY" ]; then
            log "Empty review body for $PR_ID, skipping"
            preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
            rm -f "$LOCK_FILE"
            continue
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
            gh pr review "$PR_NUM" --repo "$REPO" --approve \
                --body "$APPROVE_BODY" 2>&1 \
                || log "Approve skipped (own PR or already approved)"
            APPROVED=true
            log "Approved $PR_ID ($APPROVE_BODY)"
        else
            log "Commented on $PR_ID (no approval)"
        fi

        state_set "$PR_ID" "$PR_SHA" "$APPROVED" "$COMMENT_BODY"
        preserve_scratch "$REPO_DIR" "$(echo "$PR_ID" | tr "/#" "__")"
        rm -f "$LOCK_FILE"
        log "Done with $PR_ID"
        exit 0

    done < <(echo "$PR_LIST" | jq -c '.[]')
done

log "No new PRs to review"
