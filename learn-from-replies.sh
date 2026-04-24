#!/bin/bash
# Hourly: scan for replies to our review comments, update guidance files,
# post a per-reply acknowledgment comment (explains what was learned and
# tags the author), commit+push guidance updates to vibe-engineering, sync
# to Mac.

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
REPLIES_META_FILE=$(mktemp)    # jsonl: one {key,repo,pr,user} record per new reply
trap 'rm -f "$REPLIES_META_FILE"' EXIT

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number --state all --limit 200 2>/dev/null | jq -r '.[].number') || continue

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
                # Skip bot-authored comments (GitHub convention: login ends in [bot]).
                # Catches vercel[bot], dependabot[bot], github-actions[bot], etc.
                # Also skip the Copilot assistant by its canonical login.
                case "$USER" in
                    *"[bot]"|"Copilot"|"copilot") continue ;;
                esac
                REPLY_KEY="${REPO}#${PR_NUM}#${ID}"
                if [ -z "$(seen_get "$REPLY_KEY")" ]; then
                    # Tag each reply with a key so codex can target its ACK back
                    REPLIES+="--- Reply [${REPLY_KEY}] by @${USER} on ${REPO} PR #${PR_NUM} ---"$'\n'
                    REPLIES+="$BODY"$'\n\n'
                    jq -c --null-input \
                        --arg k "$REPLY_KEY" --arg r "$REPO" --arg p "$PR_NUM" --arg u "$USER" \
                        '{key:$k, repo:$r, pr:$p, user:$u}' >> "$REPLIES_META_FILE"
                    # NOTE: seen_set is deferred until after codex succeeds so
                    # a codex failure doesn't leave replies marked seen-but-unacked.
                fi
            fi
        done < <(echo "$COMMENTS" | jq -c '.[]')
    done
done

if [ -z "$REPLIES" ]; then
    log "No new replies found"
    exit 0
fi

REPLY_COUNT=$(wc -l < "$REPLIES_META_FILE")
log "Found $REPLY_COUNT new replies, updating guidance files..."

PRACTICES=$(cat "$CLAUDE_DIR/REVIEW_PRACTICES.md")
TESTING=$(cat "$CLAUDE_DIR/TESTING.md")
MISTAKES=$(cat "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md")

PROMPT="You are maintaining a code reviewer's guidance files. Authors have replied to automated review comments. Do two things:

1. Update the three guidance files below based on the feedback — refine rules, correct over-calls, adjust the testing bar. Output the complete updated content for each file inside XML tags.

2. Produce a per-reply acknowledgment inside an <ACKS> block. For each reply above, emit one <ACK> line that:
   - names the reply by its key (the bracketed id in the reply header)
   - explains in ONE CONCISE LINE what you learned from that specific reply (what rule you added, what over-call you corrected, what testing bar you adjusted)
   - if the reply did NOT lead to a guidance change (it was a question, a pushback you decided was unfounded, or a judgment call), say so honestly in one line

Important ACK constraints:
- One line per ACK, under ~200 characters, plain prose.
- Do NOT use \`@srosro\` or \`/review\` in ACK bodies (those tokens would trigger the reviewer to re-review the PR).
- Focus on what changed (or didn't), not pleasantries.

Output format — exactly this shape, nothing else:

<REVIEW_PRACTICES>
...full updated content...
</REVIEW_PRACTICES>
<TESTING>
...full updated content...
</TESTING>
<COMMENT_REVIEW_MISTAKES>
...full updated content...
</COMMENT_REVIEW_MISTAKES>
<ACKS>
<ACK key=\"repo#pr#commentid\">One-line what-I-learned.</ACK>
<ACK key=\"repo#pr#commentid\">...</ACK>
</ACKS>

Current REVIEW_PRACTICES.md:
$PRACTICES

Current TESTING.md:
$TESTING

Current COMMENT_REVIEW_MISTAKES.md:
$MISTAKES

New author replies to process:
$REPLIES"

RAW=$(printf '%s' "$PROMPT" | codex exec --skip-git-repo-check "Update guidance files and produce per-reply acknowledgments. Output full file contents in XML tags plus an <ACKS> block." 2>&1)

# Extract output between the last "codex" marker and "tokens used"
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

# Now mark the scanned replies as seen — only after codex succeeded + files
# updated, so a crash doesn't leave replies flagged seen-but-unacked.
while IFS= read -r META; do
    KEY=$(printf '%s' "$META" | jq -r '.key')
    [ -n "$KEY" ] && seen_set "$KEY"
done < "$REPLIES_META_FILE"

# Post per-reply acknowledgments. Parse each <ACK key="..."> line; look up
# the repo/pr/user from the meta jsonl; post a tagged comment.
ACKS_BLOCK=$(echo "$OUTPUT" | awk '/<ACKS>/{found=1; next} found && /<\/ACKS>/{exit} found{print}')
ACK_POSTED=0
ACK_SKIPPED=0
if [ -n "$ACKS_BLOCK" ]; then
    while IFS= read -r LINE; do
        # Match <ACK key="...">body</ACK>
        case "$LINE" in
            *"<ACK "*) ;;
            *) continue ;;
        esac
        KEY=$(printf '%s' "$LINE" | sed -n 's|.*key="\([^"]*\)".*|\1|p')
        ACK_BODY=$(printf '%s' "$LINE" | sed -e 's|.*<ACK[^>]*>||' -e 's|</ACK>.*||')
        # Safety: strip any @srosro/ /review tokens that would trigger re-review
        ACK_BODY=$(printf '%s' "$ACK_BODY" | sed -e 's|@srosro|srosro|gI' -e 's|/review|re-review|gI')

        [ -z "$KEY" ] || [ -z "$ACK_BODY" ] && { ACK_SKIPPED=$((ACK_SKIPPED+1)); continue; }

        # Look up the reply meta by key
        META=$(jq -c --arg k "$KEY" 'select(.key == $k)' "$REPLIES_META_FILE" | head -1)
        if [ -z "$META" ]; then
            log "ack: no meta found for key=$KEY — skipping"
            ACK_SKIPPED=$((ACK_SKIPPED+1))
            continue
        fi
        REPO=$(printf '%s' "$META" | jq -r '.repo')
        PR=$(printf '%s' "$META" | jq -r '.pr')
        USER=$(printf '%s' "$META" | jq -r '.user')

        COMMENT_BODY="@${USER} — noted. ${ACK_BODY}"
        if gh pr comment "$PR" --repo "$REPO" --body "$COMMENT_BODY" >/dev/null 2>>"$LOG_FILE"; then
            ACK_POSTED=$((ACK_POSTED+1))
        else
            log "ack: failed to post on $REPO#$PR to @$USER (see log)"
            ACK_SKIPPED=$((ACK_SKIPPED+1))
        fi
    done <<< "$ACKS_BLOCK"
    log "acknowledgments: posted=$ACK_POSTED skipped=$ACK_SKIPPED"
else
    log "acknowledgments: no <ACKS> block in codex output — skipping"
fi

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
