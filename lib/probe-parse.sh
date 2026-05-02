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

probe_validate() {
    local input
    input="$(cat)"
    [ -z "$input" ] && return 0
    grep -q '^### Probe ' <<<"$input" || return 0

    local missing=0 field
    local blocks
    blocks="$(awk '
        /^### Probe / {
            if (block) print block "\n---PROBE-SPLIT---";
            block = $0;
            next
        }
        { block = block "\n" $0 }
        END { if (block) print block }
    ' <<<"$input")"

    local probe_block="" line
    while IFS= read -r line; do
        if [ "$line" = "---PROBE-SPLIT---" ]; then
            for field in "${REQUIRED_PROBE_FIELDS[@]}"; do
                grep -q "^- \*\*${field}:\*\*" <<<"$probe_block" \
                    || { echo "missing field: $field" >&2; missing=1; }
            done
            probe_block=""
        else
            probe_block="$probe_block"$'\n'"$line"
        fi
    done <<<"$blocks"
    if [ -n "$probe_block" ]; then
        for field in "${REQUIRED_PROBE_FIELDS[@]}"; do
            grep -q "^- \*\*${field}:\*\*" <<<"$probe_block" \
                || { echo "missing field: $field" >&2; missing=1; }
        done
    fi

    return "$missing"
}

probe_extract_field() {
    local field="$1"
    grep "^- \*\*${field}:\*\*" | sed "s/^- \*\*${field}:\*\* //"
}
