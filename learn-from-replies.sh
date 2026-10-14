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

# Shared entrypoint setup: STATE_DIR + BOT_* defaults + the lib core
# (tracked-repos, auth, state-io, gh-comments).
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/bootstrap.sh"
require_repos
REPLIES_SEEN_FILE="${REPLIES_SEEN_FILE:-$STATE_DIR/replies-seen.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/learn.log}"
LEARN_CURSOR_FILE="${LEARN_CURSOR_FILE:-$STATE_DIR/learn-cursor.json}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
CODE_CONFIG_REPO="$HOME/services/code-config"
GUIDANCE_PATH="claude/COMMENT_REVIEW_MISTAKES.md"
GUIDANCE_PUSH_STATE="$STATE_DIR/code-config-guidance-push.json"

push_recorded_guidance() {
    local pending pending_sha pending_remote pending_ref
    pending=$(seen_get "$GUIDANCE_PUSH_STATE" pending)
    pending_sha=$(jq -r '.sha' <<< "$pending")
    pending_remote=$(jq -r '.remote' <<< "$pending")
    pending_ref=$(jq -r '.ref' <<< "$pending")
    if git -C "$CODE_CONFIG_REPO" push -- "$pending_remote" \
        "$pending_sha:$pending_ref" >> "$LOG_FILE" 2>&1; then
        seen_set_json_value "$GUIDANCE_PUSH_STATE" pending null
        log "code-config: pushed recorded learner commit $pending_sha"
        return 0
    fi
    log "code-config: learner push pending; will retry next tick (check log)"
    return 1
}

persist_guidance() {
    [ -d "$CODE_CONFIG_REPO/.git" ] || return 0

    [ -z "$(seen_get "$GUIDANCE_PUSH_STATE" pending)" ] || push_recorded_guidance || return 0

    if ! git -C "$CODE_CONFIG_REPO" diff --quiet HEAD -- "$GUIDANCE_PATH" 2>/dev/null; then
        local branch remote merge_ref head_sha upstream_sha pending_sha pending
        branch=$(git -C "$CODE_CONFIG_REPO" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
            log "code-config: detached HEAD; refusing to commit learned guidance"
            return 0
        }
        remote=$(git -C "$CODE_CONFIG_REPO" config --get "branch.$branch.remote")
        merge_ref=$(git -C "$CODE_CONFIG_REPO" config --get "branch.$branch.merge")
        head_sha=$(git -C "$CODE_CONFIG_REPO" rev-parse HEAD 2>/dev/null)
        upstream_sha=$(git -C "$CODE_CONFIG_REPO" rev-parse '@{upstream}' 2>/dev/null) || {
            log "code-config: no upstream configured; refusing to commit learned guidance"
            return 0
        }
        if [ -z "$remote" ] || [ -z "$merge_ref" ] || [ "$head_sha" != "$upstream_sha" ]; then
            log "code-config: checkout is not exactly at its upstream; refusing to commit or publish learned guidance"
            return 0
        fi
        if git -C "$CODE_CONFIG_REPO" -c user.email=eng@plow.co -c user.name=odio \
            commit --only -m "auto: tune review-mistakes list from /${BOT_CMD_PREFIX}-memorize requests" \
            -- "$GUIDANCE_PATH" >> "$LOG_FILE" 2>&1; then
            pending_sha=$(git -C "$CODE_CONFIG_REPO" rev-parse HEAD)
            pending=$(jq -cn --arg sha "$pending_sha" --arg remote "$remote" --arg ref "$merge_ref" \
                '{sha: $sha, remote: $remote, ref: $ref}')
            seen_set_json_value "$GUIDANCE_PUSH_STATE" pending "$pending" || return 0
            log "code-config: committed auto-tune $pending_sha"
        else
            log "code-config: guidance commit failed (check log)"
            return 0
        fi
    fi

    if [ -n "$(seen_get "$GUIDANCE_PUSH_STATE" pending)" ]; then
        push_recorded_guidance || true
    else
        log "code-config: no changes to commit or push"
    fi
}

[ -f "$REPLIES_SEEN_FILE" ] || echo '{}' > "$REPLIES_SEEN_FILE"

# Honor the GitHub rate-limit pause, like review-loop.sh and poll-pr-actions.sh.
# This poller is a PRODUCER of that pause too (its comments fetch routes
# through the gh seam), so an ungated tick would keep calling the throttled PAT
# it just told the other host timers to back off from.
if gh_pause_active; then
    log "github rate-limited — skipping memorize tick"
    exit 0
fi

# ---------- Opt-in signal: /srosro-memorize requests from trusted humans ----------
REPLIES=""
REPLIES_META_FILE=$(mktemp)
# Keys whose ACK reached a terminal state this tick — posted, or failed for a
# reason retrying cannot fix. A key absent from here is one the rate limit
# stopped, and it must stay UNSEEN so the next tick still learns from it.
ACK_DONE_FILE=$(mktemp)
# Set when the rate limit is what stopped the ACK loop. Only then is an
# un-ACKed key worth holding back for the next tick.
ACK_PAUSED=0
trap 'rm -f "$REPLIES_META_FILE" "$ACK_DONE_FILE"' EXIT

# Incremental walk: one repo-wide comments call per repo, from the start of the
# last complete walk. A full per-PR rescan outgrew its 15-minute timeout and was
# killed mid-walk every tick, so nothing was ever learned. `since` filters on
# updated_at, so an edited request resurfaces — replies-seen dedups it.
WALK_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SINCE=$(seen_get "$LEARN_CURSOR_FILE" since)
[ -n "$SINCE" ] || SINCE=$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)
# Set when this tick may have missed a request a retry could still catch. The
# cursor then stays put, and the next tick re-reads the same window.
CURSOR_HOLD=0
advance_cursor() {
    if [ "$CURSOR_HOLD" -eq 0 ]; then
        seen_set_value "$LEARN_CURSOR_FILE" since "$WALK_STARTED" || log "WARNING — cursor write failed; next tick re-reads from $SINCE"
    else
        log "cursor held at $SINCE — a fetch, trust lookup or ACK was stopped this tick"
    fi
}

# A request is a PR comment whose first line is the command — the same anchored
# `asks` the approve and review selectors use. Every bot post leads with the
# auto-post marker (lib/bootstrap.sh), so the review footer that mentions this
# command never matches, and neither does a quote-reply of it. That is what
# lets the operator's own unmarked comments under BOT_USER count.
MEMORIZE_JQ="$JQ_FIRSTLINE"'add // [] | .[]
    | select(.html_url | test("/pull/[0-9]+#"))
    | select((.body // "") | asks($cmd))
    | {id, user: .user.login, body, pr: (.html_url | capture("/pull/(?<n>[0-9]+)#").n)}'

for REPO in "${REPOS[@]}"; do
    # Mid-tick pause: a wrapped call in an earlier repo may have stamped it, and
    # the outer gate only guards the next tick.
    if gh_pause_active; then
        log "github rate-limited mid-tick — stopping the memorize walk here"
        CURSOR_HOLD=1
        break
    fi
    ERR_FILE=$(mktemp)
    REQUESTS=$(gh api --paginate "repos/${REPO}/issues/comments?since=${SINCE}" 2>"$ERR_FILE" \
        | jq -s -c --arg cmd "${BOT_CMD_PREFIX}-memorize" "$MEMORIZE_JQ") || {
        log "$REPO: comments fetch failed — $(tr '\n' ' ' < "$ERR_FILE" | head -c 400)"
        rm -f "$ERR_FILE"
        CURSOR_HOLD=1
        continue
    }
    rm -f "$ERR_FILE"

    while IFS= read -r REQ; do
        [ -n "$REQ" ] || continue
        USER=$(jq -r '.user' <<< "$REQ")
        PR_NUM=$(jq -r '.pr' <<< "$REQ")
        ID=$(jq -r '.id' <<< "$REQ")
        is_bot_account "$USER" && continue
        # Trust gate: only push-access collaborators can mutate the rule list.
        # LIVE (#233): /memorize mutates the shared rule corpus and pushes it,
        # so it shapes every future review — no cached verdict. rc captured, not
        # collapsed to a boolean: the log has to name WHY
        # (lib/auth.sh::trust_denial_reason), and rc 2 (lookup failed) is the
        # one a retry can change.
        is_trusted_repo_author_live "$REPO" "$USER"; MEMO_RC=$?
        if [ "$MEMO_RC" -ne 0 ]; then
            log "${REPO}#${PR_NUM}: /${BOT_CMD_PREFIX}-memorize from @${USER} ignored ($(trust_denial_reason "$MEMO_RC" "$REPO"))"
            [ "$MEMO_RC" -eq 2 ] && CURSOR_HOLD=1
            continue
        fi
        REPLY_KEY="${REPO}#${PR_NUM}#${ID}"
        if [ -z "$(seen_get "$REPLIES_SEEN_FILE" "$REPLY_KEY")" ]; then
            REPLIES+="--- Memorize request [${REPLY_KEY}] by @${USER} on ${REPO} PR #${PR_NUM} ---"$'\n'
            REPLIES+="$(jq -r '.body' <<< "$REQ")"$'\n\n'
            jq -c --null-input \
                --arg k "$REPLY_KEY" --arg r "$REPO" --arg p "$PR_NUM" --arg u "$USER" \
                '{key:$k, repo:$r, pr:$p, user:$u}' >> "$REPLIES_META_FILE"
        fi
    done <<< "$REQUESTS"
done

if [ -z "$REPLIES" ]; then
    # A previous tick may have committed successfully while its push failed.
    # Retry that remote half even when there is no new feedback to process.
    persist_guidance
    advance_cursor
    log "no new /${BOT_CMD_PREFIX}-memorize requests"
    exit 0
fi

REPLY_COUNT=$(wc -l < "$REPLIES_META_FILE" 2>/dev/null || echo 0)
log "signals: memorize_requests=$REPLY_COUNT — updating mistakes list..."

MISTAKES=$(cat "$CLAUDE_DIR/COMMENT_REVIEW_MISTAKES.md")

PROMPT="You maintain a ranked top-48 list of review-calibration rules based on EXPLICIT, OPT-IN feedback. Each new signal is a comment containing \`/${BOT_CMD_PREFIX}-memorize\` posted by a trusted (push-access) human collaborator on a reviewed PR — they're explicitly asking the bot to remember a lesson. This list is rewritten end-to-end on each update — it is not append-only. Your default action is to make the SMALLEST possible change that captures new signal; over-writing the whole list for one datapoint is a failure mode.

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
   - When an item TAGS a finding's severity, use exactly one of \`blocking\`, \`medium\`, \`low\`, \`nit\` (same taxonomy as \`prompts/common-header.md\`) — never \`high\`, \`critical\`, or \`major\`; \`high\` is a Confidence value, not a severity. Leave non-severity prose uses of those words alone (\`high confidence\`, \`high-churn\`, \`critical path\` are all fine).

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

RAW=$(printf '%s' "$PROMPT" | codex exec --skip-git-repo-check -c model="gpt-5.6-sol" "Update the top-48 mistakes list and produce per-reply acknowledgments. Output COMMENT_REVIEW_MISTAKES + ACKS tags only." 2>&1)

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
        # Stop the loop, don't just stamp. The wrapper makes a throttled ack
        # ARM the pause; it does not end the loop, so without this gate acks
        # 2..N keep POSTing after ack 1 trips the limit — the loop's only other
        # pause check sits upstream of it.
        if gh_pause_active; then
            log "github rate-limited — stopping ack posts here"
            ACK_SKIPPED=$((ACK_SKIPPED+1))
            ACK_PAUSED=1
            break
        fi
        if gh pr comment "$PR" --repo "$REPO" --body "$COMMENT_BODY" >/dev/null 2>>"$LOG_FILE"; then
            ACK_POSTED=$((ACK_POSTED+1))
            printf '%s\n' "$KEY" >> "$ACK_DONE_FILE"
        else
            log "ack: failed to post on $REPO#$PR to @$USER (see log)"
            ACK_SKIPPED=$((ACK_SKIPPED+1))
            # A rate-limit failure is retryable, so hold this key back. Any
            # other failure is terminal for this request — let it fall through to
            # seen, or a permanently-failing ACK re-runs codex every tick forever.
            if gh_pause_active; then ACK_PAUSED=1; else printf '%s\n' "$KEY" >> "$ACK_DONE_FILE"; fi
        fi
    done <<< "$ACKS_BLOCK"
    log "acknowledgments: posted=$ACK_POSTED skipped=$ACK_SKIPPED"
else
    log "acknowledgments: no <ACKS> block in codex output"
fi

# Mark replies as seen — AFTER the ACK loop above, which is what populates the
# bookkeeping this reads. (Running it before left every key unmarked, so each
# hourly tick re-ran codex at full cost and posted a duplicate ACK, forever.)
#
# Default is SEEN; only a key the rate limit stopped is held back. Defaulting the
# other way looks safer but isn't: a key that never reached a post at all — codex
# emitted no <ACK> line for it, an empty key/body, no meta — would then stay
# unseen permanently and re-run codex every tick, which is the unbounded-spend
# outcome this is trying to avoid. Retrying only helps when a retry can change
# the answer, and only the pause qualifies.
while IFS= read -r META; do
    KEY=$(printf '%s' "$META" | jq -r '.key')
    [ -n "$KEY" ] || continue
    if [ "$ACK_PAUSED" -eq 1 ] && ! grep -qxF "$KEY" "$ACK_DONE_FILE" 2>/dev/null; then
        log "$KEY: ACK stopped by the github rate limit — leaving unseen to retry next tick"
        continue
    fi
    if ! seen_set "$REPLIES_SEEN_FILE" "$KEY"; then
        log "$KEY: WARNING — seen_set failed AFTER posting ACK; next tick may re-learn from this request and post a duplicate ACK"
    fi
done < "$REPLIES_META_FILE"
[ "$ACK_PAUSED" -eq 1 ] && CURSOR_HOLD=1
advance_cursor

# Commit only the learner-owned file and synchronize any locally pending commit.
# Unrelated operator changes elsewhere in code-config retain their index state.
persist_guidance
