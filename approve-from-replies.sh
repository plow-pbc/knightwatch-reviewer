#!/bin/bash
# Translates `/srosro-approve` PR comments from trusted (push-access)
# collaborators into a posted APPROVED review on the PR.
#
# Why a separate script (mirroring learn-from-replies.sh, not folded into
# review.sh):
#   - Approving is a different effect than re-reviewing. The orchestrator's
#     dispatch path ends in `gh pr comment` with a fresh review body;
#     approve ends in `gh pr review --approve`. Sharing the loop would
#     muddy both.
#   - Trust gating here is strictly stronger: only push-access humans can
#     trigger an approval. /srosro-review is honored regardless of author
#     because re-request-poller and external requesters need to keep
#     working — but auto-approve is not a re-request, it's a positive
#     review action.
#
# Edge cases:
#   - Bot's own auto-posts (review footers, ack comments) carry the
#     BOT_AUTO_POST_MARKER and are filtered out by the same content rule
#     review.sh uses. The footer mentions /srosro-approve literally; the
#     marker prevents self-trigger.
#   - PR author's own approval: GitHub's review API rejects self-approval
#     when BOT_USER == PR author. We log and move on; the request is
#     marked seen so we don't retry forever.
#   - PR already merged/closed: `gh pr review --approve` returns non-zero;
#     same outcome — log + mark seen.
#
# Idempotency model: at-most-once-per-tick, NOT true exactly-once. seen_set
# uses flock + atomic-rename (lib/state-io.sh) so concurrent ticks can't
# produce torn JSON. After a successful approve, the comment is marked
# seen so subsequent ticks skip it. On a process crash between the gh
# call and the seen_set, the next tick will replay the request — GitHub
# stacks reviews from the same user so a duplicate APPROVED is harmless.
# We deliberately do NOT implement claim-before-act exactly-once because
# it would silently lose requests on transient gh failures (worse UX
# than the very rare duplicate approval).

# pipefail so a failing `gh api ... | jq -s ...` propagates jq's 0 exit
# code into a non-zero pipeline exit. Without it, a failed gh api call
# produces empty input that jq turns into [] without surfacing the
# failure — silently dropping page-1 comments or a whole fetch.
set -o pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
# Defaults FIRST, then config.env so an operator override actually wins —
# matches review.sh's order. The previous order (config.env then
# REPOS=(...)) silently clobbered any operator override of REPOS, leaving
# /srosro-approve covering a different repo set than review.sh did.
REPOS=("cncorp/plow" "srosro/tkmx-client" "srosro/tkmx-server" "srosro/knightwatch-reviewer" "srosro/vibe-engineering")
APPROVES_SEEN_FILE="${APPROVES_SEEN_FILE:-$STATE_DIR/approves-seen.json}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/approve.log}"
[ -f "$STATE_DIR/config.env" ] && . "$STATE_DIR/config.env"
BOT_USER="${BOT_USER:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# is_trusted_repo_author() — push-access trust gate, shared with review.sh.
# seen_get / seen_set — flock + atomic-rename, shared with learn-from-replies.sh.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/auth.sh"
. "$REVIEWER_LIB_DIR/state-io.sh"

[ -f "$APPROVES_SEEN_FILE" ] || echo '{}' > "$APPROVES_SEEN_FILE"

# Opt-in signal: comment body must START with `/srosro-approve` on a line
# (optional leading whitespace, optional trailing args). The earlier
# substring match would treat "don't use /srosro-approve yet" as an
# approval, which is the wrong call for a side effect this strong.
is_approve_request() {
    printf '%s' "$1" | grep -qiE '^[[:space:]]*/srosro-approve([[:space:]]|$)'
}

PROCESSED=0
SKIPPED_UNTRUSTED=0
SKIPPED_FAILED=0

for REPO in "${REPOS[@]}"; do
    # Same fail-loud-then-skip pattern as the comments fetch below: an
    # outage on `gh pr list` shouldn't look like "this repo had no PRs"
    # in the operator's journal.
    PR_LIST=$(gh pr list --repo "$REPO" --json number --state open --limit 200 2>/dev/null | jq -r '.[].number') || {
        log "$REPO: pr list failed — skipping this repo for this tick"
        continue
    }

    for PR_NUM in $PR_LIST; do
        # --paginate so /srosro-approve requests on long PR threads (>30
        # issue comments) don't silently fall off the end of page 1.
        # On fetch failure, log loud + skip this PR for this tick rather
        # than silently treating "API broken" as "no comments".
        COMMENTS=$(gh api --paginate "repos/$REPO/issues/$PR_NUM/comments" 2>/dev/null | jq -s 'add // []') || {
            log "$REPO#$PR_NUM: comments fetch failed — skipping this PR for this tick"
            continue
        }

        while IFS= read -r COMMENT; do
            BODY=$(echo "$COMMENT" | jq -r '.body')
            # Marker filter: skip the bot's own auto-posts (review footers
            # and ack comments name /srosro-approve literally).
            if printf '%s' "$BODY" | grep -qF "$BOT_AUTO_POST_MARKER"; then
                continue
            fi
            # Cheap body filter: skip anything that isn't an approve request.
            if ! is_approve_request "$BODY"; then
                continue
            fi
            ID=$(echo "$COMMENT" | jq -r '.id')
            USER=$(echo "$COMMENT" | jq -r '.user.login')
            APPROVE_KEY="${REPO}#${PR_NUM}#${ID}"
            # Already-processed: skip silently.
            if [ -n "$(seen_get "$APPROVES_SEEN_FILE" "$APPROVE_KEY")" ]; then
                continue
            fi
            # Defensive bot filter (cheap pre-check before the trust API call).
            case "$USER" in
                *"[bot]"|"Copilot"|"copilot")
                    log "$APPROVE_KEY: /srosro-approve from bot @$USER ignored"
                    seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"
                    continue
                    ;;
            esac
            # Trust gate: only push-access collaborators can trigger an
            # approval. Drive-by commenters are recorded as seen so we
            # don't re-log on every tick.
            if ! is_trusted_repo_author "$REPO" "$USER"; then
                log "$APPROVE_KEY: /srosro-approve from @$USER ignored (no push access)"
                seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"
                SKIPPED_UNTRUSTED=$((SKIPPED_UNTRUSTED + 1))
                continue
            fi

            # Submit the approval. Body carries the marker so subsequent
            # ticks (and review.sh's own filter) treat it as a bot post
            # and don't reprocess it.
            APPROVE_BODY="$BOT_AUTO_POST_MARKER
Approved on @${USER}'s /srosro-approve request."
            if gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" >/dev/null 2>>"$LOG_FILE"; then
                log "$APPROVE_KEY: approved on @${USER}'s request"
                # Critical call site: if seen_set fails after a successful
                # approval, the next tick will post a duplicate APPROVED
                # review. The helper already logs a generic failure line;
                # this extra warning makes the user-visible consequence
                # explicit so an operator knows what to expect.
                if ! seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"; then
                    log "$APPROVE_KEY: WARNING — seen_set failed AFTER successful approval; next tick may post a duplicate APPROVED review"
                fi
                PROCESSED=$((PROCESSED + 1))
            else
                # Most common failures: PR author trying to self-approve,
                # PR already merged/closed, or transient API errors. Mark
                # seen so we don't retry forever — the human can re-post
                # /srosro-approve if they want another shot.
                log "$APPROVE_KEY: gh pr review --approve FAILED — see log; marking seen"
                seen_set "$APPROVES_SEEN_FILE" "$APPROVE_KEY"
                SKIPPED_FAILED=$((SKIPPED_FAILED + 1))
            fi
        done < <(echo "$COMMENTS" | jq -c '.[]')
    done
done

if [ "$PROCESSED" -eq 0 ] && [ "$SKIPPED_UNTRUSTED" -eq 0 ] && [ "$SKIPPED_FAILED" -eq 0 ]; then
    log "no new /srosro-approve requests"
else
    log "approves: processed=$PROCESSED skipped_untrusted=$SKIPPED_UNTRUSTED skipped_failed=$SKIPPED_FAILED"
fi
