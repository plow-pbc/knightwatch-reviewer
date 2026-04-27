#!/bin/bash
# Orchestrator: enumerate eligible PRs across all tracked repos and fan out
# per-PR reviews via lib/review-one-pr.sh. Up to MAX_CONCURRENT reviews run
# concurrently per service tick. Per-PR locking is handled by the worker.

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/review.log}"
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server" "srosro/knightwatch-reviewer")
REPOS_DIR="${REPOS_DIR:-$STATE_DIR/repos}"
WORKDIRS_DIR="${WORKDIRS_DIR:-$STATE_DIR/workdirs}"
STABLE_SECS="${STABLE_SECS:-$((2 * 3600))}"
MAX_CONCURRENT="${MAX_CONCURRENT:-8}"

[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"
# Hidden HTML-comment marker prepended to every auto-post by this repo
# (review ack, final review, learn-from-replies ack). The orchestrator's
# jq filter excludes any comment containing this string so the bot
# doesn't self-trigger on its own posts. Must match the literal used in
# lib/review-one-pr.sh and learn-from-replies.sh — a smoke-test scenario
# catches drift.
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# Source helpers. Use $REVIEWER_LIB_DIR if set (for sandboxed smoke tests),
# else fall back to ~/.pr-reviewer/lib (the production symlink).
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/auth.sh"

# Rotate logs when they exceed 5MB.
for _log in "$LOG_FILE" "$STATE_DIR/cron.log"; do
    if [ -f "$_log" ] && [ "$(stat -c%s "$_log" 2>/dev/null)" -gt 5242880 ]; then
        mv "$_log" "$_log.1"
    fi
done

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
mkdir -p "$STATE_DIR" "$REPOS_DIR" "$WORKDIRS_DIR" /tmp/pr-review-locks

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
        TRIGGER_FILE=""

        if [ -n "$KNOWN_SHA" ]; then
            REVIEWED_AT=$(state_get "$PR_ID" "reviewed_at")
            REVIEWED_AT_ISO=$(date -d "@${REVIEWED_AT}" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
            COMMENTS_JSON=$(gh api "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null)
            # Exclude the bot's own auto-posts (review ack, final review,
            # learn-from-replies acks) by matching the hidden HTML-comment
            # marker every auto-post template prepends. The earlier
            # `.user.login != $user` filter (e1d91a0) over-excluded: in
            # single-account deployments BOT_USER is the human's own GH
            # identity, so user-based filtering also drops legitimate
            # /review and @<bot> comments the human posts.
            WHOLE_MENTION=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" \
                    '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/review"; "i")))] | length')
            INCREMENTAL_MENTION=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" --arg user "$BOT_USER" --arg mark "$BOT_AUTO_POST_MARKER" \
                    '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("@" + $user + "\\b"; "i")) and ((.body | test("/review"; "i")) | not))] | length')
            if [ "${WHOLE_MENTION:-0}" -gt 0 ]; then
                FORCE_REVIEW=true
                FORCE_WHOLE_PR=true
            elif [ "${INCREMENTAL_MENTION:-0}" -gt 0 ]; then
                FORCE_REVIEW=true
            fi
            # If a comment triggered this re-review, capture the latest matching
            # comment's author + body to a tmp file so the worker can stage it
            # as `.codex-scratch/trigger-comment.md`. Lets the requester's own
            # framing ("trying to DRY but ended up adding 2k LoC...") shape the
            # inferred intent and the review's emphasis. Path is passed via the
            # 7th spec field; the worker reads and rm -fs it once received.
            if [ "$FORCE_REVIEW" = "true" ]; then
                if [ "$FORCE_WHOLE_PR" = "true" ]; then
                    TRIGGER_JSON=$(printf '%s' "$COMMENTS_JSON" |
                        jq -c --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" \
                            '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/review"; "i")))] | sort_by(.created_at) | last // empty' 2>/dev/null)
                else
                    TRIGGER_JSON=$(printf '%s' "$COMMENTS_JSON" |
                        jq -c --arg since "$REVIEWED_AT_ISO" --arg user "$BOT_USER" --arg mark "$BOT_AUTO_POST_MARKER" \
                            '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("@" + $user + "\\b"; "i")) and ((.body | test("/review"; "i")) | not))] | sort_by(.created_at) | last // empty' 2>/dev/null)
                fi
                if [ -n "$TRIGGER_JSON" ]; then
                    TRIGGER_USER=$(printf '%s' "$TRIGGER_JSON" | jq -r '.user.login // ""')
                    # Trust gate: the /review or @<bot> trigger itself is
                    # honored regardless of who posted it (re-request-poller
                    # and external requesters need to keep working), but the
                    # comment's prose only gets staged as
                    # `.codex-scratch/trigger-comment.md` when the commenter
                    # has push access. Otherwise drive-by commenters could
                    # shape intent inference + aggregator on the
                    # auto-approve path.
                    if is_trusted_repo_author "$REPO" "$TRIGGER_USER"; then
                        TRIGGER_BODY=$(printf '%s' "$TRIGGER_JSON" | jq -r '.body // ""')
                        TRIGGER_FILE=$(mktemp /tmp/pr-review-trigger.XXXXXX)
                        printf 'Comment by @%s:\n\n%s\n' "$TRIGGER_USER" "$TRIGGER_BODY" > "$TRIGGER_FILE"
                    else
                        log "$PR_ID: trigger from @$TRIGGER_USER — not staging trigger-comment.md (no push access)"
                    fi
                fi
            fi
        fi

        # Skip if SHA unchanged and not /review-forced. A bare @-mention with
        # no new commits would otherwise spawn a worker that runs `git diff
        # KNOWN_SHA..HEAD`, gets an empty diff (KNOWN_SHA == HEAD), and
        # aborts in lib/review-one-pr.sh. /review (FORCE_WHOLE_PR=true)
        # bypasses this because the worker uses `gh pr diff` for the full
        # PR regardless of base SHA, so there's always something to review.
        #
        # Stale-mention behavior (deliberate): a skipped @-mention is NOT
        # consumed — the comment-selection query keys off
        # `created_at > reviewed_at`, so the mention stays "open" until the
        # next actual review. If the author later pushes a commit before
        # that review, the still-open mention flips FORCE_REVIEW=true on
        # the next tick and bypasses the 2h stability gate. We accept this
        # as eager-review behavior: the user pinged the bot for attention,
        # and we deliver it as soon as there is something meaningful to
        # review (the new commits). Marking mentions consumed on skip
        # would require a state schema change for a low-impact edge case
        # at our scale.
        if [ "$PR_SHA" = "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" = "false" ]; then
            continue
        fi

        # Log the trigger reason now that we know we're dispatching. Logged
        # AFTER the skip check so the log matches what actually runs (a
        # bare @-mention on an unchanged PR no longer logs "incremental
        # re-review" before silently skipping).
        if [ "$FORCE_WHOLE_PR" = "true" ]; then
            log "$PR_ID: /review requested — whole-PR re-review"
        elif [ "$FORCE_REVIEW" = "true" ]; then
            log "$PR_ID: @$BOT_USER mentioned + new commits — incremental re-review"
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

        # Tab-separated spec so titles with spaces survive.
        ELIGIBLE+=("$REPO"$'\t'"$PR_NUM"$'\t'"$PR_SHA"$'\t'"$PR_BRANCH"$'\t'"$PR_TITLE"$'\t'"$FORCE_WHOLE_PR"$'\t'"$TRIGGER_FILE")
    done < <(echo "$PR_LIST" | jq -c '.[]')
done

if [ ${#ELIGIBLE[@]} -eq 0 ]; then
    log "No PRs need review"
    exit 0
fi

log "Fan-out: ${#ELIGIBLE[@]} eligible PR(s), max $MAX_CONCURRENT concurrent"

# ---------- fan out with bounded concurrency ----------
# We capture each worker's exit code as it finishes so a failed worker
# propagates into the service's exit code instead of silently degrading
# the tick to "successful with log-only evidence". Per-PR flock skips
# (another copy already reviewing the same PR) exit 0 and don't count
# here.
active=0
FAILED=0
for spec in "${ELIGIBLE[@]}"; do
    IFS=$'\t' read -r REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR TRIGGER_FILE <<< "$spec"

    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        if ! wait -n; then
            FAILED=$((FAILED + 1))
        fi
        active=$((active - 1))
    done

    TRIGGER_COMMENT_FILE="$TRIGGER_FILE" \
    REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
        "$REVIEWER_LIB_DIR/review-one-pr.sh" \
        "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
    active=$((active + 1))
done

while [ "$active" -gt 0 ]; do
    if ! wait -n; then
        FAILED=$((FAILED + 1))
    fi
    active=$((active - 1))
done

if [ "$FAILED" -gt 0 ]; then
    log "Fan-out complete with $FAILED worker failure(s) out of ${#ELIGIBLE[@]}"
    exit 1
fi
log "Fan-out complete (${#ELIGIBLE[@]} review(s) ended)"
exit 0
