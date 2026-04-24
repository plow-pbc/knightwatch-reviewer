#!/bin/bash
# Hourly: maintain ~/.claude/COMMENT_REVIEW_MISTAKES.md as a ranked top-48
# list of calibration mistakes, and post acks to humans who pushed back on
# bot reviews.
#
# Only EXPLICIT signal is consumed: human replies to our review that pass
# the review-topicality filter below. Inferred signals (e.g. "PR merged
# despite our VERDICT: COMMENT") are intentionally NOT used — they produced
# too many speculative rules from too little signal. Rules that enter the
# mistakes list must be grounded in a real human reply with a clear @srosro
# tag, quote of our review, or severity reference.
#
# REVIEW_PRACTICES.md and TESTING.md are not auto-tuned here. They are
# hand-curated; auto-tune targets only the mistakes file.

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"

REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server" "srosro/knightwatch-reviewer")
REPLIES_SEEN_FILE="${REPLIES_SEEN_FILE:-$STATE_DIR/replies-seen.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/learn.log}"
MAC_HOST="${MAC_HOST:-so@so-mbp}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
MAC_CLAUDE_DIR="${MAC_CLAUDE_DIR:-/Users/so/.claude}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

[ -f "$REPLIES_SEEN_FILE" ]  || echo '{}' > "$REPLIES_SEEN_FILE"

reply_seen_get() { jq -r --arg k "$1" '.[$k] // empty' "$REPLIES_SEEN_FILE"; }
reply_seen_set() {
    local tmp; tmp=$(jq --arg k "$1" --argjson v true '.[$k] = $v' "$REPLIES_SEEN_FILE")
    echo "$tmp" > "$REPLIES_SEEN_FILE"
}

# Heuristic: does this comment look like a response to our review?
looks_like_review_reply() {
    printf '%s' "$1" | grep -qE "@${BOT_USER}|^>|\[blocking\]|\[medium\]|\[low\]|\[nit\]"
}

# ---------- Explicit signal: human replies to bot comments ----------
REPLIES=""
REPLIES_META_FILE=$(mktemp)
trap 'rm -f "$REPLIES_META_FILE"' EXIT

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number --state all --limit 200 2>/dev/null | jq -r '.[].number') || continue

    for PR_NUM in $PR_LIST; do
        COMMENTS=$(gh api "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null) || continue

        OUR_COMMENT_IDS=()
        while IFS= read -r COMMENT; do
            ID=$(echo "$COMMENT" | jq -r '.id')
            USER=$(echo "$COMMENT" | jq -r '.user.login')
            [ "$USER" = "$BOT_USER" ] && OUR_COMMENT_IDS+=("$ID")
        done < <(echo "$COMMENTS" | jq -c '.[]')

        [ ${#OUR_COMMENT_IDS[@]} -eq 0 ] && continue

        LAST_OUR_TS=0
        while IFS= read -r COMMENT; do
            USER=$(echo "$COMMENT" | jq -r '.user.login')
            BODY=$(echo "$COMMENT" | jq -r '.body')
            ID=$(echo "$COMMENT" | jq -r '.id')
            CREATED=$(echo "$COMMENT" | jq -r '.created_at')
            TS=$(date -d "$CREATED" +%s 2>/dev/null || echo 0)

            if [ "$USER" = "$BOT_USER" ]; then
                LAST_OUR_TS=$TS
            elif [ "$LAST_OUR_TS" -gt 0 ] && [ "$TS" -gt "$LAST_OUR_TS" ]; then
                case "$USER" in
                    *"[bot]"|"Copilot"|"copilot") continue ;;
                esac
                if ! looks_like_review_reply "$BODY"; then
                    continue
                fi
                REPLY_KEY="${REPO}#${PR_NUM}#${ID}"
                if [ -z "$(reply_seen_get "$REPLY_KEY")" ]; then
                    REPLIES+="--- Explicit reply [${REPLY_KEY}] by @${USER} on ${REPO} PR #${PR_NUM} ---"$'\n'
                    REPLIES+="$BODY"$'\n\n'
                    jq -c --null-input \
                        --arg k "$REPLY_KEY" --arg r "$REPO" --arg p "$PR_NUM" --arg u "$USER" \
                        '{key:$k, repo:$r, pr:$p, user:$u}' >> "$REPLIES_META_FILE"
                fi
            fi
        done < <(echo "$COMMENTS" | jq -c '.[]')
    done
done

if [ -z "$REPLIES" ]; then
    log "no new explicit signals (no human replies passed the filter)"
    exit 0
fi

REPLY_COUNT=$(wc -l < "$REPLIES_META_FILE" 2>/dev/null || echo 0)
log "signals: explicit=$REPLY_COUNT — updating mistakes list..."

MISTAKES=$(cat "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md")

PROMPT="You maintain a ranked top-48 list of review-calibration mistakes based on EXPLICIT HUMAN FEEDBACK only. Every entry in this list must be grounded in a real human reply that pushed back on, agreed with, or otherwise directly engaged with a bot review comment. This list is rewritten end-to-end on each update — it is not append-only. Your default action is to make the SMALLEST possible change that captures new signal; over-writing the whole list for one datapoint is a failure mode.

INPUTS:
- The current \`COMMENT_REVIEW_MISTAKES.md\` (the list you are editing)
- New explicit signals (human replies to bot reviews)

YOUR JOB:

1. For each new signal, infer the UNDERLYING PATTERN the feedback points at — NOT the specific instance. If a reply said 'this manifest mirroring doesn't need dedup,' the pattern is 'don't demand refactors when parity/drift tests adequately cover the risk.' Generalize before writing. No file paths, no specific PR references, no company-specific details — those belong in a commit message, not in a durable rule.

2. Decide what to do with each signal:
   - **Match an existing item** → merge it in (implicit: the item stays or moves up in rank). Do not add a near-duplicate.
   - **Genuinely new general pattern** → add it, but only if the pattern would plausibly repeat on FUTURE PRs. One-off observations are not rules.
   - **Not a real calibration signal** (question, agreement, off-topic) → ignore it.
   - **Soften an existing rule** → if the signal contradicts a too-broad rule, NARROW or soften that rule rather than adding a new one alongside.

3. Produce the updated list. Keep the format EXACTLY:
   - Numbered list, 1..N, with N ≤ 48.
   - Each line: \`N. <pattern statement>. <why it matters, one clause>.\`
   - No source tag prefix — this file only accepts explicit signals now, so there's no tag to disambiguate.
   - Under ~200 chars per item. Patterns, not case studies.
   - Ranked by importance: frequently-seen patterns outrank one-offs.
   - If the list exceeds 48 items after edits, DROP the lowest-ranked items.
   - Preserve the header text above the numbered list.

4. Produce a per-reply acknowledgment inside an <ACKS> block. For each reply that genuinely responds to the review (agreeing, pushing back, reporting a fix, debating a finding), emit one <ACK> line that names the reply by its key and explains in ONE CONCISE LINE what you learned (what rule you added, what over-call you corrected, or that you made no change and why). For off-topic replies, OMIT them from <ACKS> — silence is correct.

ACK constraints:
- One line per ACK, under ~200 chars, plain prose.
- Do NOT use \`@${BOT_USER}\` or \`/review\` (those would trigger a re-review loop).
- Focus on what changed (or didn't), not pleasantries.

OUTPUT FORMAT — exactly this shape, nothing else:

<COMMENT_REVIEW_MISTAKES>
...full updated file contents (header + numbered list)...
</COMMENT_REVIEW_MISTAKES>
<ACKS>
<ACK key=\"repo#pr#commentid\">One-line what-I-learned.</ACK>
...
</ACKS>

Default to conservative edits. If a batch of signals doesn't clearly indicate the reviewer erred in a generalizable way, output the current list unchanged and minimal/no ACKs. Quality over volume.

Current COMMENT_REVIEW_MISTAKES.md:
$MISTAKES

New explicit signals (human replies to bot reviews):
$REPLIES"

RAW=$(printf '%s' "$PROMPT" | codex exec --skip-git-repo-check "Update the top-48 mistakes list and produce per-reply acknowledgments. Output COMMENT_REVIEW_MISTAKES + ACKS tags only." 2>&1)

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

NEW_MISTAKES=$(extract_tag "COMMENT_REVIEW_MISTAKES")

if [ -z "$NEW_MISTAKES" ]; then
    log "codex output missing COMMENT_REVIEW_MISTAKES tag — raw saved to /tmp/learn-raw.txt, aborting without state change"
    echo "$RAW" > /tmp/learn-raw.txt
    exit 1
fi

# Only rewrite the file if content actually changed (avoid noisy commits).
if [ "$NEW_MISTAKES" != "$MISTAKES" ] && [ "$NEW_MISTAKES" != "$MISTAKES"$'\n' ]; then
    printf '%s\n' "$NEW_MISTAKES" > "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md"
    log "COMMENT_REVIEW_MISTAKES.md updated"
else
    log "no content change in COMMENT_REVIEW_MISTAKES.md"
fi

# Mark replies as seen — only after codex succeeded, so a crash leaves them
# eligible for the next tick.
while IFS= read -r META; do
    KEY=$(printf '%s' "$META" | jq -r '.key')
    [ -n "$KEY" ] && reply_seen_set "$KEY"
done < "$REPLIES_META_FILE"

# Post per-reply acknowledgments.
ACKS_BLOCK=$(echo "$OUTPUT" | awk '/<ACKS>/{found=1; next} found && /<\/ACKS>/{exit} found{print}')
ACK_POSTED=0
ACK_SKIPPED=0
if [ -n "$ACKS_BLOCK" ]; then
    while IFS= read -r LINE; do
        case "$LINE" in
            *"<ACK "*) ;;
            *) continue ;;
        esac
        KEY=$(printf '%s' "$LINE" | sed -n 's|.*key="\([^"]*\)".*|\1|p')
        ACK_BODY=$(printf '%s' "$LINE" | sed -e 's|.*<ACK[^>]*>||' -e 's|</ACK>.*||')
        ACK_BODY=$(printf '%s' "$ACK_BODY" | sed -e "s|@${BOT_USER}|${BOT_USER}|gI" -e 's|/review|re-review|gI')

        [ -z "$KEY" ] || [ -z "$ACK_BODY" ] && { ACK_SKIPPED=$((ACK_SKIPPED+1)); continue; }

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
    log "acknowledgments: no <ACKS> block in codex output"
fi

# Auto-commit + push guidance change to vibe-engineering.
VIBE_REPO="$HOME/Hacking/vibe-engineering"
if [ -d "$VIBE_REPO/.git" ]; then
    if git -C "$VIBE_REPO" diff --quiet claude-config/ 2>/dev/null; then
        log "vibe-engineering: no changes to commit"
    else
        git -C "$VIBE_REPO" add claude-config/ 2>>"$LOG_FILE"
        if git -C "$VIBE_REPO" -c user.email=eng@plow.co -c user.name=odio \
            commit -m "auto: tune review-mistakes list from PR-review signals" \
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

# Sync to Mac (best-effort).
rsync -az "$CLAUDE_DIR/REVIEW_PRACTICES.md" \
          "$CLAUDE_DIR/TESTING.md" \
          "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md" \
          "$MAC_CLAUDE_DIR/" 2>/dev/null \
    && log "Synced to Mac" \
    || log "Sync to Mac failed (check MAC_HOST/ssh config)"
