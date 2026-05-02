#!/bin/bash
# Sourceable helper for selecting which specialist files become "hot" —
# i.e. get a go-deep tech-lead investigation. Lives outside review-one-pr.sh
# so the smoke can exercise the selection logic directly with synthetic
# specialist files (rather than token-grepping the orchestrator regex,
# which can pass while the selection silently returns zero hot angles —
# the regression class flagged on PR #42 round 1).
#
# rank_hot_angles SPECIALISTS_DIR ANGLE1 [ANGLE2 ...]
#   stdout: each selected angle on its own line, in selection order
#
# Selection rules:
#   1. Hot = the file contains the critic-emitted token "Calibration
#      questions for go-deep" (only emitted for ≥20 LOC remedies).
#   2. If ≤3 hot angles, all of them go forward.
#   3. If >3 hot angles, rank by severity band ([blocking] band first,
#      then [medium], [low], [nit]). Within a band, file-name
#      alphabetical (deterministic). Cap at 3.
#   4. Severity is matched against the specialist contract
#      "### Finding N — <severity>" (per common-header.md:48), NOT the
#      aggregator-published "[severity]" bracketed format. Earlier
#      regression: matching the bracketed form silently emptied the
#      hot-list when 4+ specialists each had findings.

rank_hot_angles() {
    local specialists_dir="$1"
    shift
    local -a candidates=("$@")

    # Stage 1: filter by "Calibration questions" token.
    local -a hot=()
    local angle
    for angle in "${candidates[@]}"; do
        if grep -qF "Calibration questions for go-deep" "$specialists_dir/${angle}.md" 2>/dev/null; then
            hot+=("$angle")
        fi
    done

    # Stage 2: if ≤3 hot, return as-is.
    if [ "${#hot[@]}" -le 3 ]; then
        printf '%s\n' "${hot[@]}"
        return 0
    fi

    # Stage 3: severity-band ranker.
    local -a ranked=()
    local sev
    for sev in "blocking" "medium" "low" "nit"; do
        for angle in "${hot[@]}"; do
            if [ "${#ranked[@]}" -lt 3 ] && \
               grep -qE "^### Finding [0-9]+ — $sev\\b" "$specialists_dir/${angle}.md" 2>/dev/null && \
               ! printf '%s\n' "${ranked[@]}" | grep -qxF "$angle"; then
                ranked+=("$angle")
            fi
        done
    done
    printf '%s\n' "${ranked[@]}"
}
