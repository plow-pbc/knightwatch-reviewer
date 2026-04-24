#!/bin/bash
# Translates GitHub "Re-request review" button events into /review comments
# so the existing review.sh force-review path picks them up. Runs every 2 min
# via systemd timer.
#
# Mechanism: polls the issue timeline for each tracked PR, finds
# review_requested events targeting $BOT_USER newer than the last-seen event
# we recorded for that PR, and posts a /review trigger comment once per new
# event. Seen events are recorded in ~/.pr-reviewer/re-request-seen.json so
# we never double-post.

set -u
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

STATE_DIR="$HOME/.pr-reviewer"
LOG_FILE="$STATE_DIR/re-request.log"
SEEN_FILE="$STATE_DIR/re-request-seen.json"
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server")
BOT_USER="srosro"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE"

seen_get() { jq -r --arg k "$1" '.[$k] // empty' "$SEEN_FILE"; }
seen_set() {
    local k="$1" v="$2"
    local tmp; tmp=$(jq --arg k "$k" --arg v "$v" '.[$k] = $v' "$SEEN_FILE")
    echo "$tmp" > "$SEEN_FILE"
}

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number 2>/dev/null | jq -r '.[].number') || continue

    for PR_NUM in $PR_LIST; do
        PR_KEY="${REPO}#${PR_NUM}"

        # Latest review_requested event targeting our bot user, if any.
        # jq selects events where requested_reviewer.login == BOT_USER, takes the last.
        LATEST=$(gh api "repos/$REPO/issues/$PR_NUM/timeline" --paginate 2>/dev/null \
            | jq -r --arg u "$BOT_USER" \
                '[.[] | select(.event == "review_requested" and .requested_reviewer.login == $u)] | last | .created_at // empty')

        [ -z "$LATEST" ] && continue

        LAST_SEEN=$(seen_get "$PR_KEY")

        # ISO-8601 timestamps compare lexically.
        if [ -n "$LAST_SEEN" ] && [ ! "$LATEST" \> "$LAST_SEEN" ]; then
            continue
        fi

        log "$PR_KEY: re-request review event at $LATEST — posting /review trigger"
        if gh pr comment "$PR_NUM" --repo "$REPO" \
            --body "/review (triggered by GitHub re-request-review)" >/dev/null 2>&1; then
            seen_set "$PR_KEY" "$LATEST"
        else
            log "$PR_KEY: failed to post /review trigger comment"
        fi
    done
done
