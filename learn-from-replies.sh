#!/bin/bash
# Hourly: scan for replies to our review comments, update guidance files, sync to Mac

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server")
STATE_FILE="$HOME/.pr-reviewer/replies-seen.json"
LOG_FILE="$HOME/.pr-reviewer/learn.log"
MAC_HOST="so@so-mbp"  # update if needed
CLAUDE_DIR="$HOME/.claude"
MAC_CLAUDE_DIR="/Users/so/.claude"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

seen_get() { jq -r --arg k "$1" '.[$k] // empty' "$STATE_FILE"; }
seen_set() {
    local tmp; tmp=$(jq --arg k "$1" --argjson v true '.[$k] = $v' "$STATE_FILE")
    echo "$tmp" > "$STATE_FILE"
}

REPLIES=""

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number 2>/dev/null | jq -r '.[].number') || continue

    for PR_NUM in $PR_LIST; do
        COMMENTS=$(gh api "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null) || continue

        # Find our comments and any replies that follow them
        OUR_COMMENT_IDS=()
        while IFS= read -r COMMENT; do
            ID=$(echo "$COMMENT" | jq -r '.id')
            USER=$(echo "$COMMENT" | jq -r '.user.login')
            [ "$USER" = "srosro" ] && OUR_COMMENT_IDS+=("$ID")
        done < <(echo "$COMMENTS" | jq -c '.[]')

        [ ${#OUR_COMMENT_IDS[@]} -eq 0 ] && continue

        # Collect replies: comments by others that came after one of our comments
        LAST_OUR_TS=0
        while IFS= read -r COMMENT; do
            USER=$(echo "$COMMENT" | jq -r '.user.login')
            BODY=$(echo "$COMMENT" | jq -r '.body')
            ID=$(echo "$COMMENT" | jq -r '.id')
            CREATED=$(echo "$COMMENT" | jq -r '.created_at')
            TS=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)

            if [ "$USER" = "srosro" ]; then
                LAST_OUR_TS=$TS
            elif [ "$LAST_OUR_TS" -gt 0 ] && [ "$TS" -gt "$LAST_OUR_TS" ]; then
                REPLY_KEY="${REPO}#${PR_NUM}#${ID}"
                if [ -z "$(seen_get "$REPLY_KEY")" ]; then
                    REPLIES+="--- Reply on $REPO PR #$PR_NUM ---"$'\n'
                    REPLIES+="$BODY"$'\n\n'
                    seen_set "$REPLY_KEY"
                fi
            fi
        done < <(echo "$COMMENTS" | jq -c '.[]')
    done
done

if [ -z "$REPLIES" ]; then
    log "No new replies found"
    exit 0
fi

log "Found new replies, updating guidance files..."

PRACTICES=$(cat "$CLAUDE_DIR/REVIEW_PRACTICES.md")
TESTING=$(cat "$CLAUDE_DIR/TESTING.md")
MISTAKES=$(cat "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md")

PROMPT="You are maintaining a code reviewer's guidance files. Authors have replied to automated review comments. Update the three files based on the feedback — refine rules, correct over-calls, adjust the testing bar.

Output the complete updated content for each file wrapped in XML tags exactly like this:
<REVIEW_PRACTICES>
...full updated content...
</REVIEW_PRACTICES>
<TESTING>
...full updated content...
</TESTING>
<COMMENT_REVIEW_MISTAKES>
...full updated content...
</COMMENT_REVIEW_MISTAKES>

Current REVIEW_PRACTICES.md:
$PRACTICES

Current TESTING.md:
$TESTING

Current COMMENT_REVIEW_MISTAKES.md:
$MISTAKES

New author replies to process:
$REPLIES"

RAW=$(printf '%s' "$PROMPT" | codex exec "Update the three review guidance files based on author feedback. Output full file contents in XML tags." 2>&1)

# Extract each section from codex output (take content after last "codex" marker)
OUTPUT=$(echo "$RAW" | awk '
    /^codex$/ { capturing=1; buf=""; next }
    capturing && /^tokens used/ { exit }
    capturing { buf = buf $0 "\n" }
    END { printf "%s", buf }
')

extract_tag() {
    local tag="$1"
    echo "$OUTPUT" | awk "/<${tag}>/{found=1; next} found && /<\/${tag}>/{exit} found{print}"
}

NEW_PRACTICES=$(extract_tag "REVIEW_PRACTICES")
NEW_TESTING=$(extract_tag "TESTING")
NEW_MISTAKES=$(extract_tag "COMMENT_REVIEW_MISTAKES")

if [ -z "$NEW_PRACTICES" ] || [ -z "$NEW_TESTING" ] || [ -z "$NEW_MISTAKES" ]; then
    log "codex output parsing failed — raw output saved to /tmp/learn-raw.txt"
    echo "$RAW" > /tmp/learn-raw.txt
    exit 1
fi

printf '%s\n' "$NEW_PRACTICES" > "$CLAUDE_DIR/REVIEW_PRACTICES.md"
printf '%s\n' "$NEW_TESTING"   > "$CLAUDE_DIR/TESTING.md"
printf '%s\n' "$NEW_MISTAKES"  > "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md"
log "Guidance files updated"

# Auto-commit + push to the vibe-engineering repo where ~/.claude/*.md
# symlinks point. Non-fatal on any step so a transient push failure doesn't
# kill the whole learn pass.
VIBE_REPO="$HOME/Hacking/vibe-engineering"
if [ -d "$VIBE_REPO/.git" ]; then
    if git -C "$VIBE_REPO" diff --quiet claude-config/ 2>/dev/null; then
        log "vibe-engineering: no changes to commit"
    else
        git -C "$VIBE_REPO" add claude-config/ 2>>"$LOG_FILE"
        if git -C "$VIBE_REPO" -c user.email=eng@plow.co -c user.name=odio \
            commit -m "auto: tune guidance files from PR-review replies" \
            >> "$LOG_FILE" 2>&1; then
            if git -C "$VIBE_REPO" push >> "$LOG_FILE" 2>&1; then
                log "vibe-engineering: committed + pushed auto-tune"
            else
                log "vibe-engineering: committed locally; push failed (check log)"
            fi
        else
            log "vibe-engineering: commit failed (check log)"
        fi
    fi
fi

# Sync to Mac
rsync -az "$CLAUDE_DIR/REVIEW_PRACTICES.md" \
          "$CLAUDE_DIR/TESTING.md" \
          "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md" \
          "$MAC_CLAUDE_DIR/" 2>/dev/null \
    && log "Synced to Mac" \
    || log "Sync to Mac failed (check MAC_HOST/ssh config)"
