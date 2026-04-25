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

# Source state-io helpers. Use $REVIEWER_LIB_DIR if set (for sandboxed smoke
# tests), else fall back to ~/.pr-reviewer/lib (the production symlink).
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/state-io.sh"

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
                FORCE_REVIEW=true
                FORCE_WHOLE_PR=true
            elif [ "${INCREMENTAL_MENTION:-0}" -gt 0 ]; then
                FORCE_REVIEW=true
            fi
        fi

        # Skip if SHA unchanged and not /review-forced. A bare @-mention with
        # no new commits would otherwise spawn a worker that runs `git diff
        # KNOWN_SHA..HEAD`, gets an empty diff (KNOWN_SHA == HEAD), and
        # aborts in lib/review-one-pr.sh. /review (FORCE_WHOLE_PR=true)
        # bypasses this because the worker uses `gh pr diff` for the full
        # PR regardless of base SHA, so there's always something to review.
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
        ELIGIBLE+=("$REPO"$'\t'"$PR_NUM"$'\t'"$PR_SHA"$'\t'"$PR_BRANCH"$'\t'"$PR_TITLE"$'\t'"$FORCE_WHOLE_PR")
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
    IFS=$'\t' read -r REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR <<< "$spec"

    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        if ! wait -n; then
            FAILED=$((FAILED + 1))
        fi
        active=$((active - 1))
    done

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
