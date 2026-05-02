#!/bin/bash
# Sourceable helper for fetching and classifying operator decline replies
# from a PR's comment thread. Output is fed to the critic prompt as
# .codex-scratch/decline-history.md so re-flagged findings the operator
# has already declined ≥3 times can be dropped or footnoted.
#
# fetch_decline_history REPO PR_NUM
#   stdout: markdown decline-history.md content
#
# Class identification (conservative — under-classify is fine, over-classify
# silently drops findings the operator might still want flagged):
#   1. [Bug-Class-Recurrence] tags from prior bot reviews — class label
#      inside the brackets is the canonical class name.
#   2. "<noun>-<noun> finding" / "<noun>-<noun>:" prose patterns.
#   3. Known recurring classes (session-scoping, stale-auth, atomicity,
#      parsing, dispatch, retry, validation, error-envelope, race).
#   4. Fall back to "(unclassified)" — preserves the signal without
#      pretending we know the class.
#
# Empty / absent output is fail-soft (the critic just sees "(no decline
# history)" — no decline information available, fall back to existing
# behavior).

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

    local operator="${OPERATOR_NAME:-srosro}"
    # Bot auto-posts sign as the operator (kw-reviewer's GH identity is the
    # operator's account). The HTML marker `<!-- knightwatch-reviewer:auto-post -->`
    # distinguishes bot output from operator-authored replies — required so
    # the bot's own review bodies (which can mention the word "Declined" in
    # findings prose) don't leak in as operator declines.
    local declines counters
    declines=$(printf '%s' "$raw" | jq --arg op "$operator" -r '
        map(select(.user.login == $op))
        | map(select(.body | test("knightwatch-reviewer:auto-post") | not))
        | map(select(.body | test("Declined —|Declined -|^Declined |\\[Bug-Class-Recurrence\\]")))
        | map({ts: .created_at, body: .body})
        | sort_by(.ts)
        | .[]
        | "\(.ts)\t\(.body | gsub("\n"; " ") | .[:400])"
    ' 2>/dev/null)
    counters=$(printf '%s' "$raw" | jq --arg op "$operator" -r '
        map(select(.user.login == $op))
        | map(select(.body | test("knightwatch-reviewer:auto-post") | not))
        | map(select(.body | test("Counter-proposed")))
        | map({ts: .created_at, body: .body})
        | sort_by(.ts)
        | .[]
        | "\(.ts)\t\(.body | gsub("\n"; " ") | .[:400])"
    ' 2>/dev/null)

    if [ -z "$declines" ] && [ -z "$counters" ]; then
        echo "(no decline history)"
        return 0
    fi

    echo "# Decline history"
    echo
    echo "Operator ($operator) replies on prior reviews of this PR:"
    echo

    declare -A class_count class_first class_last class_reason
    local class_keys=()
    while IFS=$'\t' read -r ts body; do
        [ -z "$body" ] && continue
        # Priority order matters: the canonical aggregator BCR template
        # is `[Bug-Class-Recurrence] This is the Nth instance of <class>:`
        # (per prompts/aggregator.md). The "instance of <class>" capture
        # must come BEFORE the loose `\[Bug-Class-Recurrence\] <word>`
        # capture, otherwise the latter matches "This" as the class and
        # the operator's decline never re-classifies into the bot's own
        # canonical class names.
        local class=""
        if [[ "$body" =~ \[Bug-Class-Recurrence\].*instance[[:space:]]+of[[:space:]]+([A-Za-z][A-Za-z0-9_-]+) ]]; then
            class="${BASH_REMATCH[1]}"
        elif [[ "$body" =~ (session-scoping|stale-auth|atomicity|parsing|dispatch|retry|validation|error-envelope|race) ]]; then
            class="${BASH_REMATCH[1]}"
        elif [[ "$body" =~ \[Bug-Class-Recurrence\][[:space:]]+([A-Za-z][A-Za-z0-9_-]+) ]]; then
            class="${BASH_REMATCH[1]}"
        elif [[ "$body" =~ ([a-z][a-z]+-[a-z][a-z]+)[[:space:]]+finding ]]; then
            class="${BASH_REMATCH[1]}"
        else
            class="(unclassified)"
        fi
        if [ -z "${class_count[$class]:-}" ]; then
            class_keys+=("$class")
            class_first[$class]="$ts"
        fi
        class_count[$class]=$(( ${class_count[$class]:-0} + 1 ))
        class_last[$class]="$ts"
        class_reason[$class]="$body"
    done <<< "$declines"

    local class
    for class in "${class_keys[@]}"; do
        local plural=""
        [ "${class_count[$class]}" -gt 1 ] && plural="s"
        echo "## Class: $class (declined ${class_count[$class]} round${plural})"
        echo "- First declined: ${class_first[$class]}"
        echo "- Last declined: ${class_last[$class]}"
        echo "- Last decline reason: \"${class_reason[$class]}\""
        echo
    done

    if [ -n "$counters" ]; then
        echo "## Counter-proposed (operator applied LOC-negative version)"
        while IFS=$'\t' read -r ts body; do
            [ -z "$body" ] && continue
            echo "- $ts: $body"
        done <<< "$counters"
        echo
    fi
}

# Public entry point. Calls gh, then delegates to the pure-transform helper.
#
# Only fetches top-level (issue) comments — the operator's decline replies
# go to top-level threads (per the babysit-pr skill templates), not inline
# review-thread comments. Adding inline-comment fetch here would duplicate
# the lib/gh-comments.sh pagination contract for a use case that doesn't
# happen in production.
fetch_decline_history() {
    local repo="$1" pr_num="$2"
    local issue_comments
    if ! issue_comments=$(fetch_issue_comments "$repo" "$pr_num"); then
        echo "(decline history unavailable — gh fetch failed)"
        return 0
    fi
    _decline_history_from_json "$issue_comments"
}
