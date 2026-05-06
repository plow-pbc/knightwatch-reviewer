#!/usr/bin/env bash
# Pure parsers for the specialist bake-off. Read stdin, emit one token per line.
# _extract is the shared shape: optional line-prefilter, token regex, cleanup.
# grep exits 1 on no-match — normalize to 0 so callers under set -e don't abort.

_extract() {
    local pre="$1" pat="$2" cleanup="$3"
    if [ -z "$pre" ]; then
        grep -oE "$pat" | sed -E "$cleanup" || true
    else
        grep -oE "$pre" | grep -oE "$pat" | sed -E "$cleanup" || true
    fi
}

# Specialist name from probe's leading [from:] slot (anchored to ^N. per
# prompts/aggregator.md step 6). Inline mentions / unnumbered lines excluded.
count_attributions() {
    _extract '' \
        '^[0-9]+\. \[[^]]+\] \[from: [a-z][a-z-]*\]' \
        's/.*\[from: ([a-z-]+)\]/\1/'
}

# File paths cited in probe-line Files: clauses. Production renders unquoted
# (prompts/aggregator.md:162); regex tolerates older backticked output.
probe_cited_paths() {
    _extract '^[0-9]+\..*' \
        '`?[a-zA-Z][a-zA-Z0-9_./-]*\.[a-z]+(:[0-9]+)?`?' \
        's/^`//; s/`$//; s/:[0-9]+$//'
}

# Deduped specialist names quoted in /srosro-memorize bodies. Drives Loved.
extract_memorize_attributions() {
    _extract '' '\[from: [a-z][a-z-]*\]' 's/\[from: ([a-z-]+)\]/\1/' \
        | sort -u
}
