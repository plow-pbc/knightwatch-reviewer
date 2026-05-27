#!/usr/bin/env bash
# Sourceable helper for fetching operator decline replies from a PR's
# comment thread. Output is fed to the critic prompt as
# .codex-scratch/decline-history.md so the critic has prior pushback as
# context (and so explicitly-marked classes can drive auto-drop logic).
#
# fetch_decline_history REPO PR_NUM
#   stdout: markdown decline-history.md content
#
# Round-5 architectural reframe: this used to bash-parse operator replies
# into class buckets via a regex priority chain (BCR template, known-class
# list, "<noun>-<noun> finding"). The chain accumulated edge cases across
# 4 review rounds — the bot kept finding cases the regex missed or
# misclassified. Replaced with a structured/raw event contract:
#
#   1. Free-form decline replies are emitted VERBATIM as context. The
#      critic reads them as prose and uses its own judgement on whether
#      a class recurs.
#   2. Class-count auto-drop logic (the "declined ≥3 rounds → drop" rule
#      in critic.md) only fires for classes the operator has EXPLICITLY
#      marked via `<!-- decline:class=X -->` in their reply body. Implicit
#      class inference is left to the critic.
#
# This keeps the per-PR decline-memory feature while removing the brittle
# regex-classification seam.
#
# Empty / absent output is fail-soft (the critic just sees "(no decline
# history)" — falls back to existing behavior).

_DECLINE_HISTORY_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_DECLINE_HISTORY_LIB_DIR/gh-comments.sh"

# Internal: take a JSON array of comments as arg, emit decline-history.md
# content. Pure transform — no gh calls — so the smoke can drive it
# directly with synthetic fixtures.
_decline_history_from_json() {
    local raw="$1"
    if [ -z "$raw" ] || [ "$raw" = "null" ] || [ "$raw" = "[]" ]; then
        echo "(no decline history)"
        return 0
    fi

    # BOT_USER is the GitHub login seam (review.sh:26, learn-from-replies.sh:36,
    # approve-from-replies.sh:54). Distinct from OPERATOR_NAME (the voice/display
    # seam in lib/pipeline.py) — using the wrong one would silently filter
    # out real decline replies under a renamed operator.
    local operator="${BOT_USER:-srosro}"
    # Bot auto-posts sign as $operator (kw-reviewer's GH identity is the
    # operator's account). The HTML marker distinguishes bot output from
    # operator-authored replies.
    local marker="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
    local declines counters explicit_classes
    declines=$(printf '%s' "$raw" | jq --arg op "$operator" --arg marker "$marker" -r '
        map(select(.user.login == $op))
        | map(select(.body | contains($marker) | not))
        | map(select(.body | test("(?i)\\b(declin(?:e[ds]?|ing))\\b|\\[Bug-Class-Recurrence\\]")))
        | sort_by(.created_at)
        | .[]
        | "\(.created_at)\t\(.body | gsub("\n"; " ") | .[:600])"
    ' 2>/dev/null)
    counters=$(printf '%s' "$raw" | jq --arg op "$operator" --arg marker "$marker" -r '
        map(select(.user.login == $op))
        | map(select(.body | contains($marker) | not))
        | map(select(.body | test("Counter-proposed")))
        | sort_by(.created_at)
        | .[]
        | "\(.created_at)\t\(.body | gsub("\n"; " ") | .[:600])"
    ' 2>/dev/null)
    # Explicit class markers — operator-authored, not bot. One marker per
    # reply body counts as one class instance. The critic uses these for
    # the ≥3-rounds auto-drop rule; everything else is read as context.
    explicit_classes=$(printf '%s' "$raw" | jq --arg op "$operator" --arg marker "$marker" -r '
        map(select(.user.login == $op))
        | map(select(.body | contains($marker) | not))
        | sort_by(.created_at)
        | .[]
        | .body as $b
        | $b
        | scan("<!-- decline:class=([A-Za-z][A-Za-z0-9_-]+) -->")
        | .[0]
    ' 2>/dev/null)

    if [ -z "$declines" ] && [ -z "$counters" ] && [ -z "$explicit_classes" ]; then
        echo "(no decline history)"
        return 0
    fi

    echo "# Decline history"
    echo
    echo "Operator ($operator) replies on prior reviews of this PR. Two channels — read both:"
    echo
    echo "1. **Decline replies / Counter-proposed**: free-form operator prose, emitted verbatim as **context**. If a probe's class matches a prior prose decline, the critic defaults to \`Answer: no\` quoting the prior decline reason; it upgrades to \`Answer: unknown\` ONLY when this PR's diff cites specific new file/line/contract evidence that defeats the prior reasoning. See \`prompts/critic.md\` § Decline-history channel for the full rule."
    echo "2. **Explicit class markers**: counts of \`<!-- decline:class=X -->\` markers the operator deliberately added to a reply. THIS is the only channel that drives mechanical auto-drop (\"declined ≥3 rounds → drop\"). Without an explicit marker, no auto-drop fires — the operator has to opt in by tagging a reply."
    echo

    if [ -n "$declines" ]; then
        echo "## Decline replies"
        echo
        local i=0
        while IFS=$'\t' read -r ts body; do
            [ -z "$body" ] && continue
            i=$((i + 1))
            echo "### Reply $i — $ts"
            echo
            echo "$body"
            echo
        done <<< "$declines"
    fi

    if [ -n "$counters" ]; then
        echo "## Counter-proposed (operator applied LOC-negative version)"
        echo
        while IFS=$'\t' read -r ts body; do
            [ -z "$body" ] && continue
            echo "- **$ts:** $body"
        done <<< "$counters"
        echo
    fi

    echo "## Explicit class markers"
    echo
    if [ -z "$explicit_classes" ]; then
        echo "(none — operator has not declared any explicit \`<!-- decline:class=X -->\` markers on this PR)"
    else
        # Count occurrences per class.
        echo "$explicit_classes" | sort | uniq -c | sort -rn | while read -r count class; do
            local plural=""
            [ "$count" -gt 1 ] && plural="s"
            echo "- **\`$class\`**: $count round${plural}"
        done
    fi
    echo
}

# Public entry point. Calls gh, then delegates to the pure-transform helper.
#
# Only fetches top-level (issue) comments — the operator's decline replies
# go to top-level threads (per the babysit-pr skill templates), not inline
# review-thread comments.
fetch_decline_history() {
    local repo="$1" pr_num="$2"
    local issue_comments
    if ! issue_comments=$(fetch_issue_comments "$repo" "$pr_num"); then
        echo "(decline history unavailable — gh fetch failed)"
        return 0
    fi
    _decline_history_from_json "$issue_comments"
}
