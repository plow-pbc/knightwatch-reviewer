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
    local input
    input="$(cat)"
    [ -z "$input" ] && return 0
    grep -q '^### Probe ' <<<"$input" || return 0

    local missing=0 field
    # Skip content before the first `### Probe` header (specialists' shared
    # header may emit `### Surveyed` or other prose before any probes; that
    # is not a malformed probe). Once inside a probe block, terminate on the
    # next `### `-prefixed header that isn't `### Probe ` (e.g. `### Surveyed`
    # appearing AFTER the probes).
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
