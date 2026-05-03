#!/usr/bin/env bash
# Probe parser. Sourceable. See prompts/probe-schema.md for the canonical
# contract. Functions:
#   probe_validate    — read probe-formatted text on stdin, exit 0 if all
#                       probes have required fields, exit 1 otherwise. Logs
#                       missing-field names to stderr. Empty input is
#                       vacuously valid (exit 0).
#   probe_extract_field FIELD — read on stdin, print the value of FIELD
#                       per probe (one line per probe, in document order).

REQUIRED_PROBE_FIELDS=(From Class Q Files "If yes, edit" "If no, cost" Confidence "Severity if yes" Answer Evidence)

# Enum constraints — fields where free-form values would silently drift the
# contract. Confidence/Answer/Severity-if-yes drive aggregator render logic;
# an invalid enum makes a probe render in the wrong band or get dropped.
PROBE_ENUM_CLASS=(bug bypass shape DRY tests dead-code perf complexity-cost)
PROBE_ENUM_CONFIDENCE=(high medium low)
PROBE_ENUM_SEVERITY=(blocking medium low nit)
PROBE_ENUM_ANSWER=(yes no unknown)

probe_validate() {
    # Optional first arg: expected `From:` value. When set, every full
    # probe block (### Probe N) must have `- **From:** <expected>`.
    # Catches a specialist that emits a probe with the wrong attribution
    # — e.g. shape's output emitting `From: security`, which would
    # corrupt the aggregator's per-specialist Security/Test summaries.
    # Critic isn't pinned (it emits multiple `From:` values legitimately).
    local expected_from="${1:-}"
    local input
    input="$(cat)"
    [ -z "$input" ] && return 0

    # Reject legacy `### Finding` headers — those mean the specialist
    # ignored the probe contract and emitted finding-era output. Pre-probe
    # parser was permissive (returned 0 for anything without `### Probe`),
    # which let legacy output drift through. Now: explicit reject.
    if grep -q '^### Finding' <<<"$input"; then
        echo "legacy '### Finding' header — must emit probe-format per .codex-scratch/probe-schema.md" >&2
        return 1
    fi

    # Require at least ONE of: full probe block, critic resolved-probe
    # delta block, `## Surveyed` section, or critic-shape section
    # headers (`## Resolved probes` / `## Generated probes`). The
    # critic-shape headers are valid even with empty bodies — a clean
    # PR with no specialist probes legitimately has no resolved or
    # generated content. Bare `No probes.` with none of the above
    # means the agent failed to prove it looked.
    if ! grep -qE '^### Probe |^### \[from: [a-z][a-z-]+\] Probe |^## Surveyed|^### Surveyed|^## Resolved probes|^## Generated probes' <<<"$input"; then
        echo "no probe blocks, Surveyed section, or critic-shape headers — agent must emit one of these" >&2
        return 1
    fi

    local missing=0 field

    # Validate critic resolved-probe delta blocks (header form
    # `### [from: <angle>] Probe N`). Each delta MUST carry an
    # `Answer:` line with a valid enum value — otherwise a specialist
    # blocker the critic claimed to resolve actually has no override
    # and falls back to specialist's `Answer: unknown` (rendered as
    # `[open]`, demoting the blocker). Each delta ALSO must carry an
    # `Evidence:` line.
    local resolved_blocks
    resolved_blocks="$(awk '
        /^### \[from: [a-z][a-z-]+\] Probe / {
            if (in_block) print block "\n---DELTA-SPLIT---";
            block = $0;
            in_block = 1;
            next
        }
        /^### |^## / && in_block {
            print block "\n---DELTA-SPLIT---";
            in_block = 0;
            next
        }
        { if (in_block) block = block "\n" $0 }
        END { if (in_block) print block }
    ' <<<"$input")"
    if [ -n "$resolved_blocks" ]; then
        local delta_block="" line val v ok
        _validate_delta() {
            local block="$1"
            local hdr=$(printf '%s' "$block" | head -1)
            # Required fields on every resolved delta
            grep -q "^- \*\*Answer:\*\*" <<<"$block" || {
                echo "resolved-probe delta missing Answer field: '$hdr'" >&2
                missing=1
                return
            }
            grep -q "^- \*\*Evidence:\*\*" <<<"$block" || {
                echo "resolved-probe delta missing Evidence field: '$hdr'" >&2
                missing=1
            }
            # Answer enum
            val=$(grep '^- \*\*Answer:\*\*' <<<"$block" | head -1 | sed 's/^- \*\*Answer:\*\* //;s/[[:space:]]*$//')
            ok=0
            for v in "${PROBE_ENUM_ANSWER[@]}"; do
                [ "$val" = "$v" ] && { ok=1; break; }
            done
            if [ "$ok" -eq 0 ]; then
                echo "invalid Answer enum in resolved-probe delta '$hdr': '$val' (expected: ${PROBE_ENUM_ANSWER[*]})" >&2
                missing=1
            fi
        }
        while IFS= read -r line; do
            if [ "$line" = "---DELTA-SPLIT---" ]; then
                _validate_delta "$delta_block"
                delta_block=""
            else
                delta_block="$delta_block"$'\n'"$line"
            fi
        done <<<"$resolved_blocks"
        [ -n "$delta_block" ] && _validate_delta "$delta_block"
    fi

    # Skip content before the first `### Probe` header (specialists' shared
    # header may emit `### Surveyed` or other prose before any probes; that
    # is not a malformed probe). Once inside a probe block, terminate on the
    # next `### `-prefixed header that isn't `### Probe ` (e.g. `### Surveyed`
    # appearing AFTER the probes).
    if ! grep -q '^### Probe ' <<<"$input"; then
        # Surveyed-only or resolved-only input (already validated above).
        return "$missing"
    fi
    local blocks
    blocks="$(awk '
        /^### Probe / {
            if (in_probe) print block "\n---PROBE-SPLIT---";
            block = $0;
            in_probe = 1;
            next
        }
        /^### / && in_probe {
            print block "\n---PROBE-SPLIT---";
            in_probe = 0;
            next
        }
        { if (in_probe) block = block "\n" $0 }
        END { if (in_probe) print block }
    ' <<<"$input")"

    # _validate_probe_block: invoked per probe block; checks required fields
    # AND enum-constrained fields (Class / Confidence / Severity if yes /
    # Answer). Sets `missing=1` on any failure.
    _validate_probe_block() {
        local block="$1"
        local field val
        for field in "${REQUIRED_PROBE_FIELDS[@]}"; do
            grep -q "^- \*\*${field}:\*\*" <<<"$block" \
                || { echo "missing field: $field" >&2; missing=1; }
        done
        # Enum checks. Skip when the field is missing (already reported above).
        _check_enum() {
            local field="$1"; shift
            local valid=("$@")
            local val v
            val=$(grep "^- \*\*${field}:\*\*" <<<"$block" | head -1 | sed "s/^- \*\*${field}:\*\* //" | sed 's/[[:space:]]*$//')
            [ -z "$val" ] && return 0
            for v in "${valid[@]}"; do
                [ "$val" = "$v" ] && return 0
            done
            echo "invalid enum: ${field}='${val}' (expected: ${valid[*]})" >&2
            missing=1
        }
        _check_enum "Class" "${PROBE_ENUM_CLASS[@]}"
        _check_enum "Confidence" "${PROBE_ENUM_CONFIDENCE[@]}"
        _check_enum "Severity if yes" "${PROBE_ENUM_SEVERITY[@]}"
        _check_enum "Answer" "${PROBE_ENUM_ANSWER[@]}"
        # If caller pinned the expected From value, enforce it. R9 added
        # this so a specialist whose probe emits a wrong From value
        # (e.g. shape's output saying `From: security`) trips the
        # validator. Skipped when expected_from is empty (critic case —
        # critic legitimately emits multiple From values per round).
        if [ -n "$expected_from" ]; then
            local from_val
            from_val=$(grep "^- \*\*From:\*\*" <<<"$block" | head -1 | sed 's/^- \*\*From:\*\* //;s/[[:space:]]*$//')
            if [ -n "$from_val" ] && [ "$from_val" != "$expected_from" ]; then
                echo "wrong From: '$from_val' (expected '$expected_from')" >&2
                missing=1
            fi
        fi
    }

    local probe_block="" line
    while IFS= read -r line; do
        if [ "$line" = "---PROBE-SPLIT---" ]; then
            _validate_probe_block "$probe_block"
            probe_block=""
        else
            probe_block="$probe_block"$'\n'"$line"
        fi
    done <<<"$blocks"
    [ -n "$probe_block" ] && _validate_probe_block "$probe_block"

    return "$missing"
}

probe_extract_field() {
    local field="$1"
    grep "^- \*\*${field}:\*\*" | sed "s/^- \*\*${field}:\*\* //"
}
