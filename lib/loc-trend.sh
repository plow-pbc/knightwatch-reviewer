#!/bin/bash
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
#   - per-round adds count via `git diff --numstat` (structured: sum
#     the additions column, not regex on --shortstat human prose)
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

    # Per-round typed state model. Three states drive both the trajectory
    # classifier and the display column — single source of truth instead
    # of overloading "shortstat is empty" to mean both "SHA missing from
    # local history" AND "SHA exists but legitimately zero-diff."
    #
    #   unavailable    — git cat-file -e rejects the SHA (rebase /
    #                    force-push / shallow clone evicted it). adds=0
    #                    but the value is meaningless; trajectory must
    #                    bail to UNKNOWN.
    #   reachable_zero — SHA exists, three-dot diff returns empty/zero
    #                    adds. Legitimate zero-diff round (chore: bump
    #                    deps that's already merged, force-push that
    #                    didn't change content). adds=0 is real data.
    #   numeric        — SHA exists, diff has at least one file with
    #                    adds > 0. adds carries the count.
    #
    # Three-dot diff (<merge_base>...<sha>) so git computes the dynamic
    # merge-base per (base, sha) pair — each row reflects "what this
    # round looked like at the time," not "what this round looks like vs
    # current main."
    local round_adds=() round_states=()
    local round_sha numstat adds state
    for line in "${rounds[@]}"; do
        round_sha="${line#*$'\t'}"
        if ! git -C "$repo_dir" cat-file -e "$round_sha" 2>/dev/null; then
            state="unavailable"
            adds=0
        else
            numstat=$(git -C "$repo_dir" diff --numstat "${merge_base}...${round_sha}" 2>/dev/null)
            if [ -n "$numstat" ]; then
                adds=$(printf '%s\n' "$numstat" | awk '{sum += $1} END {print sum+0}')
            else
                adds=0
            fi
            if [ "$adds" -gt 0 ]; then
                state="numeric"
            else
                state="reachable_zero"
            fi
        fi
        round_adds+=("$adds")
        round_states+=("$state")
    done

    if [ ${#rounds[@]} -eq 1 ]; then
        # Only the current round — no prior author-visible reviews.
        echo "(no prior rounds — first review)"
        echo
        echo "| Round | Timestamp | SHA | base..head |"
        echo "|---|---|---|---|"
        echo "| 1 | $current_ts | ${current_sha:0:7} | $(_loc_trend_display "$repo_dir" "$merge_base" "$current_sha" "${round_states[0]}") |"
        return 0
    fi

    # Trajectory dispatch on the typed states. UNKNOWN supersedes every
    # other classification when at least one PRIOR row is unavailable —
    # the additions count for that row is unrecoverable, so a ratio
    # against it would be a lie. The current round being unavailable is
    # impossible (we just resolved it) so we don't have to special-case it.
    local first_state="${round_states[0]}"
    local last_state="${round_states[-1]}"
    local first_round_adds="${round_adds[0]}"
    local last_round_adds="${round_adds[-1]}"
    local trajectory ratio
    local had_unavailable_prior=false
    local s
    local last_idx=$((${#round_states[@]} - 1))
    local i_state=0
    for s in "${round_states[@]}"; do
        if [ "$s" = "unavailable" ] && [ "$i_state" -ne "$last_idx" ]; then
            had_unavailable_prior=true
            break
        fi
        i_state=$((i_state + 1))
    done

    if [ "$had_unavailable_prior" = "true" ]; then
        trajectory="UNKNOWN (one or more prior reviewed SHAs not in local history — likely rebased or force-pushed)"
    elif [ "$first_state" = "reachable_zero" ] && [ "$last_state" = "numeric" ]; then
        # First round was a legitimately zero-diff baseline (e.g. rebase-only
        # or chore: bump deps round); later rounds added real code. STABLE
        # would be misleading — there's clearly growth, just no first-round
        # baseline to compute a ratio against. Closes round-4 BCR(a).
        trajectory="GROWING (from zero baseline → ${last_round_adds} adds)"
    elif [ "$first_state" = "numeric" ] && [ "$last_state" = "numeric" ]; then
        ratio=$(awk -v a="$last_round_adds" -v b="$first_round_adds" 'BEGIN{printf "%.2f", a/b}')
        if awk -v r="$ratio" 'BEGIN{exit !(r >= 1.5)}'; then
            trajectory="GROWING (${ratio}× from first review)"
        elif awk -v r="$ratio" 'BEGIN{exit !(r <= 0.66)}'; then
            trajectory="SHRINKING (${ratio}× from first review)"
        else
            trajectory="STABLE"
        fi
    else
        # Remaining cases: first=numeric/last=reachable_zero (everything
        # reverted), or all rows reachable_zero. Both read as STABLE — no
        # meaningful trajectory because the latest round has no adds.
        trajectory="STABLE"
    fi

    echo "This PR has been reviewed ${#rounds[@]} times. Trajectory: $trajectory."
    echo
    echo "| Round | Timestamp | SHA | base..head |"
    echo "|---|---|---|---|"
    local i=1 idx=0
    for line in "${rounds[@]}"; do
        ts="${line%$'\t'*}"
        sha="${line#*$'\t'}"
        echo "| $i | $ts | ${sha:0:7} | $(_loc_trend_display "$repo_dir" "$merge_base" "$sha" "${round_states[$idx]}") |"
        i=$((i + 1))
        idx=$((idx + 1))
    done
}

# _loc_trend_display <repo_dir> <merge_base> <sha> <state>
#   stdout: one-line "base..head" cell content for the trajectory table.
#
# Routes on the typed state, not on shortstat output — that conflation
# was the round-4 BCR(b): a force-push that didn't change content
# returned an empty shortstat and rendered as "(sha not in local
# history)" alongside truly-evicted SHAs.
_loc_trend_display() {
    local repo_dir="$1" merge_base="$2" sha="$3" state="$4"
    case "$state" in
        unavailable)
            printf '%s' "(sha not in local history)"
            ;;
        reachable_zero)
            printf '%s' "(zero diff)"
            ;;
        numeric)
            git -C "$repo_dir" diff --shortstat "${merge_base}...${sha}" 2>/dev/null | sed 's/^ *//' | tr '\n' ' '
            ;;
    esac
}
