#!/usr/bin/env bash
# Sourceable helper for computing loc-trend.md (per-round LOC trajectory)
# from the per-PR runs/ history. Lives outside review-one-pr.sh so the
# regression smoke can exercise the same function the worker calls
# (instead of testing a copy) — same shape as lib/run-dir.sh.
#
# Round discovery delegates to author_visible_rounds (lib/run-dir.sh) —
# single owner for the "which rounds count + canonical (ts, sha) per
# round" contract. We pull that in ourselves so callers don't have to
# remember the dependency order.

_LOC_TREND_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LOC_TREND_LIB_DIR/run-dir.sh"

# compute_loc_trend <repo_slash> <pr_num> <repo_dir> <merge_base_sha> <state_dir> <current_run_dir> <current_sha>
#   stdout: markdown loc-trend.md content
#
# repo_slash is the GitHub slash-form (e.g. "cncorp/plow"), NOT the
# PR_ID (which carries a "#N" suffix). The function converts to
# underscore-form for filesystem matching.
#
# Round discovery delegates to author_visible_rounds. compute_loc_trend
# adds:
#   - per-round typed state (unavailable / reachable_zero / deletion_only /
#     numeric) via `git diff --numstat` (structured: sum the additions
#     column, not regex on --shortstat human prose) for classification
#   - per-round display column via `git diff --shortstat`
#   - both diffs use three-dot syntax (<merge_base>...<sha>) so git
#     computes the dynamic merge-base for THAT round. Two-dot
#     (<merge_base>..<sha>) would diff against the current
#     default-branch SHA captured at orchestrator boot, which
#     retroactively distorts older rounds when main has advanced
#     between reviews.
#
# Then appends the current round explicitly using $current_sha so the
# aggregator + momentum specialist see "where we are right now" as the
# latest row. Empty runs/ (first review) is handled without aborting.
compute_loc_trend() {
    local repo="$1" pr_num="$2" repo_dir="$3" merge_base="$4" state_dir="$5" current_run_dir="$6" current_sha="$7"
    local owner_repo="${repo//\//_}"
    local current_ts
    current_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    echo "# LOC trend"
    echo

    # Collect (ts, sha) tuples for prior author-visible rounds from the
    # single-owner helper. tab-separated; sorted by timestamp ascending.
    local rounds=()
    local line ts sha
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        rounds+=("$line")
    done < <(author_visible_rounds "$state_dir" "$owner_repo" "$pr_num" "$current_run_dir")

    # Always append the current round so the table includes "where we are
    # now" (the SHA the aggregator/momentum specialist are reasoning about).
    rounds+=("$(printf '%s\t%s' "$current_ts" "$current_sha")")

    # Per-round typed state model. Four states drive the display column —
    # single source of truth instead of overloading "shortstat is empty"
    # to mean any of three different things ("SHA missing from local
    # history" / "SHA exists but legitimately zero-diff" / "SHA exists
    # but diff command failed").
    #
    #   unavailable    — git cat-file -e rejects the SHA (rebase /
    #                    force-push / shallow clone evicted it) OR
    #                    cat-file -e succeeded but `git diff --numstat`
    #                    itself exited non-zero (corrupted history,
    #                    partial fetch, weirder failure modes).
    #   reachable_zero — SHA exists, three-dot diff succeeded with empty
    #                    output (no files in the diff at all).
    #                    Legitimate zero-diff round (force-push that
    #                    didn't change content; rebase-only rounds where
    #                    the rebase target is already in main).
    #   deletion_only  — SHA exists, diff has rows but adds=0 and dels>0
    #                    (`git rm` round). Display distinguishes it from
    #                    reachable_zero.
    #   numeric        — SHA exists, diff has at least one file with
    #                    adds > 0. adds carries the count.
    #
    # Three-dot diff (<merge_base>...<sha>) so git computes the dynamic
    # merge-base per (base, sha) pair — each row reflects "what this
    # round looked like at the time," not "what this round looks like vs
    # current main."
    local round_dels=() round_states=()
    local round_sha numstat adds dels state diff_exit
    for line in "${rounds[@]}"; do
        round_sha="${line#*$'\t'}"
        if ! git -C "$repo_dir" cat-file -e "$round_sha" 2>/dev/null; then
            state="unavailable"
            dels=0
        else
            # Capture stdout AND exit code separately. `2>/dev/null || echo ""`
            # would mask a non-zero exit and let it fall through as
            # reachable_zero — wrong, since cat-file -e already confirmed
            # the SHA is reachable, so a non-zero diff exit means
            # something else is broken (corrupted history, partial
            # fetch). Classify as unavailable so a corrupted-history
            # row does not lie with a fabricated 0-adds count.
            numstat=$(git -C "$repo_dir" diff --numstat "${merge_base}...${round_sha}" 2>/dev/null)
            diff_exit=$?
            if [ $diff_exit -ne 0 ]; then
                state="unavailable"
                dels=0
            elif [ -n "$numstat" ]; then
                adds=$(printf '%s\n' "$numstat" | awk '{sum += $1} END {print sum+0}')
                dels=$(printf '%s\n' "$numstat" | awk '{sum += $2} END {print sum+0}')
                if [ "$adds" -gt 0 ]; then
                    state="numeric"
                elif [ "$dels" -gt 0 ]; then
                    # adds=0, dels>0 — `git rm` round. Display calls it
                    # out as deletion-only so readers don't misread it
                    # as "no diff."
                    state="deletion_only"
                else
                    # numstat returned rows but both adds and dels are
                    # 0 across all of them — shouldn't happen in
                    # practice (every diff row has at least one
                    # non-zero column), but treat as reachable_zero
                    # rather than fabricate a state.
                    state="reachable_zero"
                fi
            else
                # numstat is empty AND diff exited 0 — truly no files in
                # the diff (legitimate zero-diff round).
                dels=0
                state="reachable_zero"
            fi
        fi
        round_dels+=("$dels")
        round_states+=("$state")
    done

    if [ ${#rounds[@]} -eq 1 ]; then
        # Only the current round — no prior author-visible reviews.
        echo "(no prior rounds — first review)"
        echo
        echo "| Round | Timestamp | SHA | merge-base..head (additions only) |"
        echo "|---|---|---|---|"
        echo "| 1 | $current_ts | ${current_sha:0:7} | $(_loc_trend_display "$repo_dir" "$merge_base" "$current_sha" "${round_states[0]}" "${round_dels[0]}") |"
        return 0
    fi

    echo "This PR has been reviewed ${#rounds[@]} times."
    echo
    echo "| Round | Timestamp | SHA | merge-base..head (additions only) |"
    echo "|---|---|---|---|"
    local i=1 idx=0
    for line in "${rounds[@]}"; do
        ts="${line%$'\t'*}"
        sha="${line#*$'\t'}"
        echo "| $i | $ts | ${sha:0:7} | $(_loc_trend_display "$repo_dir" "$merge_base" "$sha" "${round_states[$idx]}" "${round_dels[$idx]}") |"
        i=$((i + 1))
        idx=$((idx + 1))
    done
}

# _loc_trend_display <repo_dir> <merge_base> <sha> <state> <dels>
#   stdout: one-line "merge-base..head" cell content for the trajectory table.
#
# Routes on the typed state, not on shortstat output — that conflation
# was the round-4 BCR(b): a force-push that didn't change content
# returned an empty shortstat and rendered as "(sha not in local
# history)" alongside truly-evicted SHAs.
#
# unavailable folds in two failure modes — SHA not reachable, AND
# diff command failed despite reachable SHA. Both render the same
# because the user's recourse is identical (rebase / force-push /
# corrupt history → can't compute trajectory for this row).
_loc_trend_display() {
    local repo_dir="$1" merge_base="$2" sha="$3" state="$4" dels="${5:-0}"
    case "$state" in
        unavailable)
            printf '%s' "(sha not in local history)"
            ;;
        reachable_zero)
            printf '%s' "(zero diff)"
            ;;
        deletion_only)
            printf '(0 adds, %s dels)' "$dels"
            ;;
        numeric)
            git -C "$repo_dir" diff --shortstat "${merge_base}...${sha}" 2>/dev/null | sed 's/^ *//' | tr '\n' ' '
            ;;
    esac
}
