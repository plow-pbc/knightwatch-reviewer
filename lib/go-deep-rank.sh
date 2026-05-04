#!/usr/bin/env bash
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
# Round-5 reframe: ranks at FINDING-level granularity, not file-level.
# Earlier file-level ranking could spend a go-deep slot on a specialist
# whose calibrated finding was a low-severity nit while another file's
# blocking finding was correctly calibrated but ranked under it (because
# the first file also had an UNCALIBRATED blocking elsewhere in its
# layered output). The new shape: for each specialist file, find the
# max severity AMONG calibrated findings, then rank specialists by that
# score.
#
# Selection rules:
#   1. Hot = the file contains the critic-emitted token "Calibration
#      questions for go-deep" (only emitted for ≥20 LOC remedies) AND
#      a corresponding `### Finding N — <severity>` block exists.
#   2. Each hot file's "score" is the max severity among its CALIBRATED
#      findings (blocking > medium > low > nit), determined by pairing
#      the critic's per-finding sections (which carry calibration
#      blocks) with the specialist's per-finding severity headers.
#   3. If ≤3 hot, all returned in input order.
#   4. If >3 hot, pick top 3 by score (severity band desc). Within a
#      severity band, tiebreak is **caller order** — the order $@ was
#      passed (which is ANGLES, the orchestrator-fixed array in
#      lib/pipeline.py). Deterministic by virtue of ANGLES being a
#      static array; no alphabetical / remedy-LOC tiebreak.

# Internal: emit the max severity among calibrated findings in $1, or
# empty string if none. Output is one of: blocking | medium | low | nit | "".
_max_calibrated_severity() {
    awk '
        BEGIN { in_critic = 0; current = "" }
        # The orchestrator critic-splitter emits "---\n\n## Critic counter-arguments"
        # between the specialist body and the critic body. Detect both shapes —
        # the H2 alone is sufficient (the splitter always emits it).
        /^## Critic counter-arguments/ { in_critic = 1; current = ""; next }
        # Any other H2 ends the active section.
        /^## / && in_critic { in_critic = 0; current = ""; next }

        # Specialist Finding N — severity (occurs BEFORE the critic section).
        !in_critic && /^### Finding [0-9]+ — / {
            n = $0; sub(/^### Finding /, "", n); sub(/ — .*/, "", n)
            s = $0; sub(/^### Finding [0-9]+ — /, "", s)
            sub(/[[:space:]]*$/, "", s)
            sev[n] = s
            next
        }

        # Critic per-angle finding header — note the [<angle>] prefix.
        in_critic && /^### \[[a-z][a-z-]*\] Finding [0-9]+/ {
            n = $0; sub(/.*Finding /, "", n); sub(/ —.*/, "", n)
            current = n
            next
        }

        # Calibration block marker — pin to the current critic finding.
        in_critic && /Calibration questions for go-deep investigation/ {
            if (current != "") cal[current] = 1
            next
        }

        END {
            ranks["blocking"] = 4
            ranks["medium"] = 3
            ranks["low"] = 2
            ranks["nit"] = 1
            best_rank = 0
            best = ""
            for (n in cal) {
                s = sev[n]
                if (!(s in ranks)) continue
                r = ranks[s]
                if (r > best_rank) { best_rank = r; best = s }
            }
            if (best != "") print best
        }
    ' "$1"
}

rank_hot_angles() {
    local specialists_dir="$1"
    shift
    local -a candidates=("$@")

    # Stage 1: filter by "Calibration questions" presence + extract max severity.
    local -a hot=()
    declare -A sev_of=()
    local angle s
    for angle in "${candidates[@]}"; do
        local f="$specialists_dir/${angle}.md"
        [ -e "$f" ] || continue
        if ! grep -qF "Calibration questions for go-deep" "$f"; then
            continue
        fi
        s=$(_max_calibrated_severity "$f")
        if [ -n "$s" ]; then
            hot+=("$angle")
            sev_of["$angle"]="$s"
        fi
    done

    # Stage 2a: zero hot → emit nothing (explicit early return so caller's
    # `mapfile -t HOT_ANGLES < <(...)` produces an empty array, not a
    # 1-element array containing an empty string. Belt-and-suspenders
    # against printf/empty-array edge cases across shell versions.
    if [ "${#hot[@]}" -eq 0 ]; then
        return 0
    fi
    # Stage 2b: ≤3 hot, return as-is (input order).
    if [ "${#hot[@]}" -le 3 ]; then
        printf '%s\n' "${hot[@]}"
        return 0
    fi

    # Stage 3: severity-band ranker by max-calibrated-severity, capped at 3.
    local -a ranked=()
    local sev
    for sev in "blocking" "medium" "low" "nit"; do
        for angle in "${hot[@]}"; do
            if [ "${#ranked[@]}" -lt 3 ] && \
               [ "${sev_of[$angle]}" = "$sev" ] && \
               ! printf '%s\n' "${ranked[@]}" | grep -qxF "$angle"; then
                ranked+=("$angle")
            fi
        done
    done
    printf '%s\n' "${ranked[@]}"
}
