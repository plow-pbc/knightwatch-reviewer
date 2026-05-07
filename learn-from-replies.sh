#!/bin/bash
# Hourly: maintain ~/.claude/COMMENT_REVIEW_MISTAKES.md as a ranked top-48
# list of calibration rules, and post acks to humans whose feedback shaped
# the list.
#
# Only EXPLICIT, OPT-IN signal is consumed: comments containing
# `/srosro-memorize` posted by trusted (push-access) repo collaborators
# after a bot review on the same PR. The earlier heuristic filter
# (looks_like_review_reply) over-included noise — bot replies, tangential
# human chatter, anything that happened to mention @<bot> or quote a
# severity tag. The slash command makes the signal opt-in: a human is
# explicitly asking the bot to remember a lesson, the trust gate keeps
# drive-by commenters from mutating the rule list, and the "after a bot
# review" sequencing keeps the request anchored to actual review context.
#
# REVIEW_PRACTICES.md and TESTING.md are not auto-tuned here. They are
# hand-curated; auto-tune targets only the mistakes file.

# pipefail so a failing `gh api ... | jq -s ...` propagates jq's 0 exit
# code into a non-zero pipeline exit. Without it, a failed gh api call
# produces empty input that jq turns into [] without surfacing the
# failure — silently dropping page-1 comments or a whole fetch.
set -o pipefail
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
REPLIES_SEEN_FILE="${REPLIES_SEEN_FILE:-$STATE_DIR/replies-seen.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/learn.log}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
# Tracked-repo manifest (single source of truth in repos.conf). The
# shared loader at lib/tracked-repos.sh is the ONE seam every consumer
# goes through.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
[ ${#REPOS[@]} -ge 1 ] || { echo "FATAL: no tracked repos — populate $STATE_DIR/repos.conf or set REPOS in config.env" >&2; exit 1; }
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# is_trusted_repo_author() — push-access trust gate, shared with review.sh.
# seen_get / seen_set + log — flock + atomic-rename, shared with approve-from-replies.sh.
. "$REVIEWER_LIB_DIR/auth.sh"
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/gh-comments.sh"

[ -f "$REPLIES_SEEN_FILE" ] || echo '{}' > "$REPLIES_SEEN_FILE"

# Opt-in signal: comment body must contain the literal `/srosro-memorize`
# slash command (case-insensitive). The bot's own review footer mentions
# this command but BOT_USER posts hit the LAST_OUR_TS branch above and
# never reach this check, so the footer can't self-trigger.
is_memorize_request() {
    printf '%s' "$1" | grep -qiF "/${BOT_CMD_PREFIX}-memorize"
}

# ---------- Opt-in signal: /srosro-memorize requests from trusted humans ----------
REPLIES=""
REPLIES_META_FILE=$(mktemp)
trap 'rm -f "$REPLIES_META_FILE"' EXIT

for REPO in "${REPOS[@]}"; do
    # Same fail-loud-then-skip pattern as the comments fetch below: an
    # outage on `gh pr list` shouldn't look like "this repo had no PRs"
    # in the operator's journal.
    PR_LIST=$(gh pr list --repo "$REPO" --json number --state all --limit 200 2>/dev/null | jq -r '.[].number') || {
        log "$REPO: pr list failed — skipping this repo for this tick"
        continue
    }

    for PR_NUM in $PR_LIST; do
        # Pagination correctness lives in lib/gh-comments.sh (shared with
        # review.sh + approve-from-replies.sh) so any future caller of
        # this endpoint can't reinvent the bug. On fetch failure, log
        # loud + skip this PR for this tick rather than silently treating
        # "API broken" as "no comments".
        COMMENTS=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
            log "$REPO#$PR_NUM: comments fetch failed — skipping this PR for this tick"
            continue
        }

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
            # Portable ISO→epoch via jq's fromdateiso8601 — already invoked
            # per-iteration above, so zero new process startup cost. (Earlier
            # python3 fix shipped per-comment subprocess; bot caught the
            # cost on PR #47 R32 and pointed at the jq-native one-liner.)
            TS=$(jq -nr --arg ts "$CREATED" '$ts | fromdateiso8601' 2>/dev/null || echo 0)

            if [ "$USER" = "$BOT_USER" ]; then
                LAST_OUR_TS=$TS
            elif [ "$LAST_OUR_TS" -gt 0 ] && [ "$TS" -gt "$LAST_OUR_TS" ]; then
                # Defensive: trust gate below would catch most bots (no
                # push access), but keep the explicit *[bot]/Copilot
                # filter as a cheap pre-check before the API call.
                case "$USER" in
                    *"[bot]"|"Copilot"|"copilot") continue ;;
                esac
                # Cheap body filter first — skip the trust API call for
                # any reply that isn't an explicit memorize request.
                if ! is_memorize_request "$BODY"; then
                    continue
                fi
                # Trust gate: only push-access collaborators can mutate
                # the rule list. Drive-by commenters can post
                # /srosro-memorize all they want; we ignore them. Logged
                # at info so misuse is visible.
                if ! is_trusted_repo_author "$REPO" "$USER"; then
                    log "${REPO}#${PR_NUM}: /${BOT_CMD_PREFIX}-memorize from @${USER} ignored (no push access)"
                    continue
                fi
                REPLY_KEY="${REPO}#${PR_NUM}#${ID}"
                if [ -z "$(seen_get "$REPLIES_SEEN_FILE" "$REPLY_KEY")" ]; then
                    REPLIES+="--- Memorize request [${REPLY_KEY}] by @${USER} on ${REPO} PR #${PR_NUM} ---"$'\n'
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
    log "no new /${BOT_CMD_PREFIX}-memorize requests"
    exit 0
fi

REPLY_COUNT=$(wc -l < "$REPLIES_META_FILE" 2>/dev/null || echo 0)
log "signals: memorize_requests=$REPLY_COUNT — updating mistakes list..."

MISTAKES=$(cat "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md")

PROMPT="You maintain a ranked top-48 list of review-calibration rules based on EXPLICIT, OPT-IN feedback. Each new signal is a comment containing \`/${BOT_CMD_PREFIX}-memorize\` posted by a trusted (push-access) human collaborator after a bot review on the same PR — they're explicitly asking the bot to remember a lesson. This list is rewritten end-to-end on each update — it is not append-only. Your default action is to make the SMALLEST possible change that captures new signal; over-writing the whole list for one datapoint is a failure mode.

INPUTS:
- The current \`COMMENT_REVIEW_MISTAKES.md\` (the list you are editing)
- New /${BOT_CMD_PREFIX}-memorize requests (each is a trusted human's explicit ask to remember something)

YOUR JOB:

1. For each new signal, infer the UNDERLYING PATTERN the human is teaching — NOT the specific instance. If they wrote 'this manifest mirroring doesn't need dedup,' the pattern is 'don't demand refactors when parity/drift tests adequately cover the risk.' Generalize before writing. No file paths, no specific PR references, no company-specific details — those belong in a commit message, not in a durable rule.

2. Decide what to do with each signal:
   - **Match an existing item** → merge it in (implicit: the item stays or moves up in rank). Do not add a near-duplicate.
   - **Genuinely new general pattern** → add it, but only if the pattern would plausibly repeat on FUTURE PRs. One-off observations are not rules.
   - **Not a clear calibration lesson** (vague request, just thanks/acknowledgment, or '/${BOT_CMD_PREFIX}-memorize' with nothing actionable after it) → ignore it.
   - **Soften an existing rule** → if the signal contradicts a too-broad rule, NARROW or soften that rule rather than adding a new one alongside.

3. Produce the updated list. Keep the format EXACTLY:
   - Numbered list, 1..N, with N ≤ 48.
   - Each line: \`N. <pattern statement>. <why it matters, one clause>.\`
   - No source tag prefix.
   - Under ~200 chars per item. Patterns, not case studies.
   - Ranked by importance: frequently-seen patterns outrank one-offs.
   - If the list exceeds 48 items after edits, DROP the lowest-ranked items.
   - Preserve the header text above the numbered list.

4. Produce a per-request acknowledgment inside an <ACKS> block. For each /${BOT_CMD_PREFIX}-memorize request, emit one <ACK> line that names the request by its key and explains in ONE CONCISE LINE what you did: what rule you added, what existing rule you softened, or that you made no change and why. ACK every request — the human asked you to remember something, so silence is wrong; tell them what happened.

ACK constraints:
- One line per ACK, under ~200 chars, plain prose.
- Do NOT use \`@${BOT_USER}\`, \`/${BOT_CMD_PREFIX}-review\`, \`/${BOT_CMD_PREFIX}-update-review\`, or \`/${BOT_CMD_PREFIX}-memorize\` in the ACK body (those would either trigger a re-review loop or recursively register as a new memorize request on the next tick).
- Focus on what changed (or didn't), not pleasantries.

OUTPUT FORMAT — exactly this shape, nothing else:

<COMMENT_REVIEW_MISTAKES>
...full updated file contents (header + numbered list)...
</COMMENT_REVIEW_MISTAKES>
<ACKS>
<ACK key=\"repo#pr#commentid\">One-line what-I-did.</ACK>
...
</ACKS>

Default to conservative edits. If a request doesn't clearly indicate a generalizable rule, leave the list unchanged and ACK with what you considered and why you didn't update. Quality over volume.

Current COMMENT_REVIEW_MISTAKES.md:
$MISTAKES

New /${BOT_CMD_PREFIX}-memorize requests:
$REPLIES"

RAW=$(printf '%s' "$PROMPT" | codex exec --skip-git-repo-check -c model="gpt-5.5" "Update the top-48 mistakes list and produce per-reply acknowledgments. Output COMMENT_REVIEW_MISTAKES + ACKS tags only." 2>&1)

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
# eligible for the next tick. Honor seen_set's fail-loud return code so a
# silent write failure can't lead to a duplicate ACK + duplicate codex
# work on the next tick.
while IFS= read -r META; do
    KEY=$(printf '%s' "$META" | jq -r '.key')
    if [ -n "$KEY" ]; then
        if ! seen_set "$REPLIES_SEEN_FILE" "$KEY"; then
            log "$KEY: WARNING — seen_set failed AFTER posting ACK; next tick may re-learn from this request and post a duplicate ACK"
        fi
    fi
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
        # Defang: strip leading @ and / so the ACK body can't (a) re-trigger
        # the orchestrator's slash-command tests, or (b) recursively register
        # as a new /srosro-memorize request on the next learn tick. The
        # codex prompt tells the model not to emit these, but belt-and-
        # suspenders: the marker filter alone protects us, and so does the
        # USER=BOT_USER filter, but a defanged body is also harder to
        # accidentally copy-paste into a real trigger.
        ACK_BODY=$(printf '%s' "$ACK_BODY" | sed \
            -e "s|@${BOT_USER}|${BOT_USER}|gI" \
            -e "s|/${BOT_CMD_PREFIX}-update-review|${BOT_CMD_PREFIX}-update-review|gI" \
            -e "s|/${BOT_CMD_PREFIX}-review|${BOT_CMD_PREFIX}-review|gI" \
            -e "s|/${BOT_CMD_PREFIX}-memorize|${BOT_CMD_PREFIX}-memorize|gI")

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

        COMMENT_BODY="$BOT_AUTO_POST_MARKER
@${USER} — noted. ${ACK_BODY}"
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
            commit -m "auto: tune review-mistakes list from /${BOT_CMD_PREFIX}-memorize requests" \
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
