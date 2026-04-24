#!/bin/bash
# Automated PR reviewer using Codex

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

LOCK_FILE="${LOCK_FILE:-/tmp/pr-reviewer.lock}"
STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/review.log}"
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server" "srosro/knightwatch-reviewer")
REPOS_DIR="${REPOS_DIR:-$STATE_DIR/repos}"
STABLE_SECS="${STABLE_SECS:-$((2 * 3600))}"

# Shared config (BOT_USER etc); fall back to sensible defaults if missing.
[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Rotate logs when they exceed 5MB (cron runs every 2min; logs grow fast)
for _log in "$LOG_FILE" "$STATE_DIR/cron.log"; do
    if [ -f "$_log" ] && [ "$(stat -c%s "$_log" 2>/dev/null)" -gt 5242880 ]; then
        mv "$_log" "$_log.1"
    fi
done

# Source state-io helpers. Use $REVIEWER_LIB_DIR if set (for sandboxed smoke
# tests), else fall back to ~/.pr-reviewer/lib (the production symlink).
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/state-io.sh"

[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

if [ -f "$LOCK_FILE" ]; then
    log "Review in progress, skipping"
    exit 0
fi

mkdir -p "$STATE_DIR" "$REPOS_DIR"
cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

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

        # Check for trigger comments since our last review:
        #   /review (anywhere in body)   → force whole-PR re-review (ignore state's KNOWN_SHA)
        #   @BOT_USER (without /review) → force incremental re-review
        # Both bypass the SHA-unchanged skip and the stability cooldown.
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
                log "$PR_ID: /review requested — forcing WHOLE-PR re-review"
                FORCE_REVIEW=true
                FORCE_WHOLE_PR=true
            elif [ "${INCREMENTAL_MENTION:-0}" -gt 0 ]; then
                log "$PR_ID: @$BOT_USER mentioned — forcing INCREMENTAL re-review"
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

        log "Eligible for review: $PR_ID (force=$FORCE_REVIEW, whole_pr=$FORCE_WHOLE_PR)"
        touch "$LOCK_FILE"

        # Delegate the entire per-PR pipeline to the worker.
        REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
            "$REVIEWER_LIB_DIR/review-one-pr.sh" \
            "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR"

        rm -f "$LOCK_FILE"
        exit 0

    done < <(echo "$PR_LIST" | jq -c '.[]')
done

log "No new PRs to review"
