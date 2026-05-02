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
