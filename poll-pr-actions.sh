#!/bin/bash
# Single open-PR poller (every 2 min via systemd): enumerate the open PRs ONCE,
# then run both reply-driven actions per PR — the /<prefix>-approve check and the
# re-request-review trigger. Merged from the former pr-reviewer-approve (60s) +
# pr-reviewer-re-request (120s) timers so the enumeration is shared and the
# per-PR fetch rate against the shared srosro GitHub budget is halved.
#
# Mechanism per PR:
#   approve_check    — scan issue comments for a trusted /<prefix>-approve and
#                      submit gh pr review --approve (presence-deduped in
#                      approves-seen.json via the flock-safe state-io seen store).
#   rerequest_check  — scan the issue timeline for review_requested events
#                      targeting $BOT_USER and post a /<prefix>-review trigger,
#                      watermarked per PR by latest event time in re-request-seen.json.
set -o pipefail
# PATH inherited from the systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

# Shared entrypoint setup: STATE_DIR + BOT_* defaults + the lib core
# (tracked-repos, auth, state-io, gh-comments). pr-enumerate is poll-specific.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/bootstrap.sh"
. "$REVIEWER_LIB_DIR/pr-enumerate.sh"
require_tracked_targets
LOG_FILE="${LOG_FILE:-$STATE_DIR/poll.log}"
APPROVES_SEEN_FILE="${APPROVES_SEEN_FILE:-$STATE_DIR/approves-seen.json}"
RR_SEEN_FILE="${RR_SEEN_FILE:-$STATE_DIR/re-request-seen.json}"

# Both seen stores are created on demand by state-io's seen_set/seen_set_value
# (presence for approves, timestamp watermark for re-request), and seen_get
# returns either shape — so no explicit init or per-store helper is needed.

# Opt-in signal: comment body must START with /<prefix>-approve on a line
# (optional leading whitespace, optional trailing args). A substring match would
# treat "don't use /srosro-approve yet" as an approval — wrong for this side effect.
is_approve_request() {
    printf '%s' "$1" | grep -qiE "^[[:space:]]*/${BOT_CMD_PREFIX}-approve([[:space:]]|$)"
}

# Submit gh pr review --approve for any new trusted /<prefix>-approve on the PR.
approve_check() {
    local REPO="$1" PR_NUM="$2" PR_AUTHOR="$3" COMMENTS COMMENT BODY ID USER APPROVE_KEY APPROVE_BODY
    # On fetch failure, log loud + skip this PR for this tick rather than silently
    # treating "API broken" as "no comments". Pagination correctness lives in
    # lib/gh-comments.sh (shared) so callers can't reinvent the bug.
    COMMENTS=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
        log "$REPO#$PR_NUM: comments fetch failed — skipping approve check this tick"
        return 0
    }
    while IFS= read -r COMMENT; do
        BODY=$(echo "$COMMENT" | jq -r '.body')
        # Skip the bot's own auto-posts (footers/acks name /<prefix>-approve literally).
        printf '%s' "$BODY" | grep -qF "$BOT_AUTO_POST_MARKER" && continue
        is_approve_request "$BODY" || continue
        ID=$(echo "$COMMENT" | jq -r '.id')
        USER=$(echo "$COMMENT" | jq -r '.user.login')
        APPROVE_KEY="${REPO}#${PR_NUM}#${ID}"
        [ -n "$(seen_get "$APPROVES_SEEN_FILE" "$APPROVE_KEY")" ] && continue
        # Defensive bot filter (cheap pre-check before the trust API call).
        case "$USER" in
            *"[bot]"|"Copilot"|"copilot")
                log "$APPROVE_KEY: /${BOT_CMD_PREFIX}-approve from bot @$USER ignored"
                seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"; continue ;;
        esac
        # Trust gate: only push-access collaborators can trigger an approval.
        # rc 2 = the permission fetch itself failed (transient API error) — leave
        # the comment UNSEEN so a legitimate request is retried next tick rather
        # than silently dropped; rc 1 = genuine non-push author, mark seen + skip.
        is_trusted_repo_author "$REPO" "$USER"; trust_rc=$?
        if [ "$trust_rc" -eq 2 ]; then
            log "$APPROVE_KEY: permission check failed (API error) — leaving unseen to retry next tick"
            continue
        elif [ "$trust_rc" -ne 0 ]; then
            log "$APPROVE_KEY: /${BOT_CMD_PREFIX}-approve from @$USER ignored (no push access)"
            seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"; continue
        fi
        # Body carries the marker so later ticks (and review.sh's filter) treat it
        # as a bot post and don't reprocess.
        APPROVE_BODY="$BOT_AUTO_POST_MARKER
Approved on @${USER}'s /${BOT_CMD_PREFIX}-approve request."
        # Go through the shared approval seam (lib/auth.sh): it owns the
        # self-approval guard (GitHub forbids approving the bot's own PRs) and
        # loud failure logging. Mark seen regardless of outcome — approved,
        # self-approval-skip, or failure — so we don't retry forever; the human
        # can re-post /<prefix>-approve for another attempt.
        submit_approval "$REPO" "$PR_NUM" "$BOT_USER" "$PR_AUTHOR" "$APPROVE_BODY" || true
        seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY" \
            || log "$APPROVE_KEY: WARNING — seen_set failed after approval attempt; next tick may reprocess"
    done < <(echo "$COMMENTS" | jq -c '.[]')
}

# Translate a new GitHub "Re-request review" event into a /<prefix>-review trigger.
rerequest_check() {
    local REPO="$1" PR_NUM="$2" PR_KEY="$1#$2" TIMELINE LATEST LAST_SEEN
    # Fetch + detect failure explicitly (same shape as the comment fetch) so a
    # transient API error is logged + skipped, not silently read as "no event".
    TIMELINE=$(gh api "repos/$REPO/issues/$PR_NUM/timeline" --paginate 2>/dev/null) || {
        log "$PR_KEY: timeline fetch failed — skipping re-request check this tick"
        return 0
    }
    # Latest review_requested event targeting our bot user, if any. --paginate
    # emits one JSON array per page, so slurp (-s) + `add` merges them before
    # selecting — otherwise a newer event on page 2 is missed.
    LATEST=$(printf '%s' "$TIMELINE" | jq -s -r --arg u "$BOT_USER" \
        'add | [.[] | select(.event == "review_requested" and .requested_reviewer.login == $u)] | last | .created_at // empty')
    [ -z "$LATEST" ] && return 0
    LAST_SEEN=$(seen_get "$RR_SEEN_FILE" "$PR_KEY")
    # ISO-8601 timestamps compare lexically.
    if [ -n "$LAST_SEEN" ] && [ ! "$LATEST" \> "$LAST_SEEN" ]; then
        return 0
    fi
    log "$PR_KEY: re-request review event at $LATEST — posting /${BOT_CMD_PREFIX}-review trigger"
    # Command + a human-facing attribution so the auto-post isn't mistaken for a
    # hand-typed comment (it lands under BOT_USER, which is the operator's own
    # identity in a single-account deploy). The trailing BOT_AUTO_TRIGGER_MARKER
    # tells the orchestrator to treat the body as a bare command — dropping this
    # note from the staged trigger-comment.md so it isn't weighted as requester
    # framing (the original reason this was kept bare).
    RR_BODY="/${BOT_CMD_PREFIX}-review

<sub>↳ auto-posted by the review bot because a reviewer was re-requested — not a manual request.</sub>${BOT_AUTO_TRIGGER_MARKER}"
    if gh pr comment "$PR_NUM" --repo "$REPO" --body "$RR_BODY" >/dev/null 2>&1; then
        seen_set_value "$RR_SEEN_FILE" "$PR_KEY" "$LATEST"
    else
        log "$PR_KEY: failed to post /${BOT_CMD_PREFIX}-review trigger comment"
    fi
}

ALL_PRS=$(enumerate_open_prs) || { log "enumerate_open_prs failed — skipping this tick"; exit 0; }

while IFS= read -r PR_JSON; do
    REPO=$(echo "$PR_JSON" | jq -r '.repository.nameWithOwner')
    PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
    PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.author.login // ""')
    approve_check "$REPO" "$PR_NUM" "$PR_AUTHOR"
    rerequest_check "$REPO" "$PR_NUM"
done < <(echo "$ALL_PRS" | jq -c '.[]')
