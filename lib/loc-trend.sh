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

# _diff_adds_dels <repo_dir> <merge_base> <sha>
#   echoes "<adds> <dels>" for the three-dot diff merge_base...sha — or
#   "n/a n/a" when sha is unreachable (evicted / force-pushed) OR the diff
#   command itself fails (corrupted history / partial fetch). Single owner of
#   the n/a-safe additions contract, shared by the per-round trajectory loop
#   and the T1 first-commit baseline (was duplicated across both). "0 0"
#   (reachable, empty diff) stays distinct from "n/a n/a" (unavailable), so
#   callers can still tell reachable_zero from unavailable. Never fabricates a
#   0 for an unreachable sha — momentum must not read that as arithmetic.
_diff_adds_dels() {
    local repo_dir="$1" merge_base="$2" sha="$3" numstat ec
    git -C "$repo_dir" cat-file -e "$sha" 2>/dev/null || { echo "n/a n/a"; return; }
    numstat=$(git -C "$repo_dir" diff --numstat "${merge_base}...${sha}" 2>/dev/null); ec=$?
    [ "$ec" -eq 0 ] || { echo "n/a n/a"; return; }
    printf '%s\n' "$numstat" | awk '{a+=$1; d+=$2} END {print (a+0), (d+0)}'
}

# compute_loc_trend <repo_slash> <pr_num> <repo_dir> <merge_base_sha> <state_dir> <current_run_dir> <current_sha>
#   stdout: markdown loc-trend.md content
#
# repo_slash is the GitHub slash-form (e.g. "some-org/some-repo"), NOT the
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
    # Per-round typed state derived from the shared _diff_adds_dels contract:
    #   "n/a n/a" → unavailable (sha evicted OR diff failed; never a fake 0)
    #   adds>0    → numeric
    #   adds=0,dels>0 → deletion_only (`git rm` round)
    #   adds=0,dels=0 → reachable_zero (reachable, empty diff)
    local round_adds=() round_dels=() round_states=()
    local round_sha adds dels state
    for line in "${rounds[@]}"; do
        round_sha="${line#*$'\t'}"
        read -r adds dels < <(_diff_adds_dels "$repo_dir" "$merge_base" "$round_sha")
        if [ "$adds" = "n/a" ]; then
            state="unavailable"; dels=0
        elif [ "$adds" -gt 0 ]; then
            state="numeric"
        elif [ "$dels" -gt 0 ]; then
            state="deletion_only"
        else
            state="reachable_zero"
        fi
        round_adds+=("$adds")
        round_dels+=("$dels")
        round_states+=("$state")
    done

    if [ ${#rounds[@]} -eq 1 ]; then
        echo "(no prior rounds — first review)"
    else
        echo "This PR has been reviewed ${#rounds[@]} times."
    fi
    echo
    echo "| Round | Timestamp | SHA | merge-base..head | Adds |"
    echo "|---|---|---|---|---|"
    local i=1 idx=0
    for line in "${rounds[@]}"; do
        ts="${line%$'\t'*}"
        sha="${line#*$'\t'}"
        echo "| $i | $ts | ${sha:0:7} | $(_loc_trend_display "$repo_dir" "$merge_base" "$sha" "${round_states[$idx]}" "${round_dels[$idx]}") | ${round_adds[$idx]} |"
        i=$((i + 1))
        idx=$((idx + 1))
    done

    # --- T1: LOC-growth re-eval trigger (deterministic) ------------------
    # Fires when the current round's additions have ballooned past
    # the PR's OPENING size (first commit) * 1.33 + 100. A PR that has
    # grown this far past the size it was opened at is showing scope creep
    # / wrong shape / a buggy original that needed heavy patching — exactly
    # the trajectory the re-eval banner exists to surface, and earlier than the 3-round
    # blocker-stall trigger (T2) can. Integer math (1.33 ≈ *133/100); the
    # +100 floor protects tiny PRs from noise. Both endpoints must be
    # numeric — an `n/a` endpoint means rebased/evicted history (delta
    # unknown), so we abstain rather than read it as a 0. Emitted as a
    # trailing flag line the orchestrator greps verbatim (no float math
    # in any LLM); review-one-pr.sh folds it into reeval-status.md.
    # --- T1 baseline: the PR's OPENING size (first commit), not round-1's
    # review snapshot. Anchoring to round_adds[0] missed the dominant creep
    # pattern — a PR opened near-empty (tiny first commit) and built out
    # in-PR over many commits: round-1's review snapshot already captured
    # the grown size, so the round-over-round delta stayed flat and never
    # tripped. The first commit is the true "starting LOC"; growth past it
    # is creep. Uses the shared _diff_adds_dels helper for the n/a-safe
    # contract: an evicted first commit or a failed diff yields "n/a"
    # (delta unknown), never a fabricated 0.
    local first_commit base_adds="n/a"
    first_commit=$(git -C "$repo_dir" rev-list --reverse "${merge_base}..${current_sha}" 2>/dev/null | head -1)
    [ -n "$first_commit" ] && read -r base_adds _ < <(_diff_adds_dels "$repo_dir" "$merge_base" "$first_commit")
    local n_rounds=${#round_adds[@]}
    local first_adds="$base_adds" cur_adds="${round_adds[$((n_rounds - 1))]}"
    echo
    if [ "$n_rounds" -lt 2 ]; then
        echo "REEVAL-LOC-TRIGGER: not-fired (single round — no trajectory yet)"
    elif [ "$first_adds" = "n/a" ] || [ "$cur_adds" = "n/a" ]; then
        echo "REEVAL-LOC-TRIGGER: insufficient-data (opening or current Adds is n/a — delta unknown)"
    else
        local threshold=$(( first_adds * 133 / 100 + 100 ))
        if [ "$cur_adds" -gt "$threshold" ]; then
            echo "REEVAL-LOC-TRIGGER: fired (open=$first_adds current=$cur_adds threshold=$threshold)"
        else
            echo "REEVAL-LOC-TRIGGER: not-fired (open=$first_adds current=$cur_adds threshold=$threshold)"
        fi
    fi

    # --- T-SIZE: first-review absolute-altitude trigger (deterministic) --
    # T1/T2 are TRAJECTORY triggers — they need >=2 rounds to accumulate.
    # A PR that is BORN large (opened already spanning many files / thousands
    # of additions) generates few blockers yet still can't be reviewed well
    # as one unit. This fires on the FIRST review only, keying on absolute
    # size against the altitude bar, and feeds the aggregator's Path 1
    # redirect (close + resubmit smaller) independent of blocker count.
    # Re-reviews emit not-applicable — the trajectory triggers own those.
    # Bars are tunable; kept hardcoded to match the existing 1.33/+100 style
    # and the authoring-side gate in claude-config CLAUDE.md (20 files / 600 adds).
    local SIZE_FILES_BAR=20 SIZE_ADDS_BAR=600
    if [ "$n_rounds" -ge 2 ]; then
        echo "REEVAL-SIZE-TRIGGER: not-applicable (re-review — size redirect is first-review only)"
    elif [ "$cur_adds" = "n/a" ]; then
        echo "REEVAL-SIZE-TRIGGER: insufficient-data (current Adds is n/a — size unknown)"
    else
        local cur_files
        cur_files=$(git -C "$repo_dir" diff --name-only "${merge_base}...${current_sha}" 2>/dev/null | grep -c .)
        if [ "$cur_files" -ge "$SIZE_FILES_BAR" ] || [ "$cur_adds" -ge "$SIZE_ADDS_BAR" ]; then
            echo "REEVAL-SIZE-TRIGGER: fired (files=$cur_files adds=$cur_adds bars=${SIZE_FILES_BAR}f/${SIZE_ADDS_BAR}a)"
        else
            echo "REEVAL-SIZE-TRIGGER: not-fired (files=$cur_files adds=$cur_adds bars=${SIZE_FILES_BAR}f/${SIZE_ADDS_BAR}a)"
        fi
    fi
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
