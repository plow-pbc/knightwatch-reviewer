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
        # "Regardless of outcome" above holds for real outcomes — approved,
        # self-approval-skip, permission failure. A rate limit is not an outcome:
        # the request was never delivered, so marking it seen would silently drop
        # a trusted human's approve and make them re-post because WE were
        # throttled. Branch on THIS call's result, not on global pause state: the
        # pause file is shared by every host timer, so a sibling stamping one in
        # the window after a SUCCESSFUL approve would leave the key unseen and
        # the next tick would post a second approve plus a duplicate comment.
        if ! submit_approval "$REPO" "$PR_NUM" "$BOT_USER" "$PR_AUTHOR" "$APPROVE_BODY" \
           && gh_pause_active; then
            log "$APPROVE_KEY: github rate-limited — leaving unseen to retry after the pause"
            continue
        fi
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
    # Via the wrapper so a throttled post stamps the pause. On failure this skips
    # seen_set_value, so the event stays unseen and re-POSTs every 2-minute tick
    # forever — as a bare `gh` that storm never armed the pause. No
    # GH_API_RETRY_MAX=1 needed: the create-verb guard refuses the retry on argv.
    if gh pr comment "$PR_NUM" --repo "$REPO" --body "$RR_BODY" >/dev/null 2>&1; then
        seen_set_value "$RR_SEEN_FILE" "$PR_KEY" "$LATEST"
    else
        log "$PR_KEY: failed to post /${BOT_CMD_PREFIX}-review trigger comment"
    fi
}

# Honor the GitHub rate-limit pause, like review-loop.sh. This poller is a
# PRODUCER of that pause (its timeline fetch, comment fetch and trust check all
# route through the gh seam), so without this gate it would stamp a pause and
# then keep calling the same throttled PAT itself every two minutes. The pause
# it writes is shared with the other HOST timers (same $HOME/.pr-reviewer state
# dir), not with the containers — see lib/state-io.sh for that boundary.
if gh_pause_active; then
    log "github rate-limited — skipping poll tick"
    exit 0
fi

ALL_PRS=$(enumerate_open_prs) || { log "enumerate_open_prs failed — skipping this tick"; exit 0; }

while IFS= read -r PR_JSON; do
    # A wrapped call inside this tick may have just stamped the pause. The outer
    # gate only guards the NEXT tick, so without this the loop walks every
    # remaining PR (~3 calls each) straight into the throttle it just detected.
    if gh_pause_active; then
        log "github rate-limited mid-tick — stopping the poll loop here"
        break
    fi
    REPO=$(echo "$PR_JSON" | jq -r '.repository.nameWithOwner')
    PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
    PR_AUTHOR=$(echo "$PR_JSON" | jq -r '.author.login // ""')
    approve_check "$REPO" "$PR_NUM" "$PR_AUTHOR"
    rerequest_check "$REPO" "$PR_NUM"
done < <(echo "$ALL_PRS" | jq -c '.[]')
