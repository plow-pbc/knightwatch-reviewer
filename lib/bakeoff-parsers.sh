#!/usr/bin/env bash
# Pure parsers for the specialist bake-off. Read from stdin, emit to stdout.
# No file I/O, no network — composable in pipelines + hermetic-testable.

# count_attributions: read review body(ies) on stdin, emit one specialist
# name per `[from: <specialist>]` attribution found in numbered probe
# lines (`^N. ...`). Line-pattern filter excludes prose/footer/doc/
# README/example tokens by construction — only probe-line attributions
# count. Caller pipes through `sort | uniq -c`. grep exits 1 on no match
# — normalize to 0 so callers under `set -e` don't abort.
count_attributions() {
    grep -E '^[0-9]+\.' \
        | grep -oE '\[from: [a-z][a-z-]*\]' \
        | sed -E 's/\[from: ([a-z-]+)\]/\1/' \
        || true
}

# extract_memorize_attributions: read a /srosro-memorize comment body on
# stdin. If it contains quoted `[from: <specialist>]` tags from a prior
# bot review, emit those specialist names (one per line, deduplicated).
# If it has no tags, emit nothing — we don't attribute the love to anyone.
# grep exits 1 when no match — normalize to 0 same reason as above.
extract_memorize_attributions() {
    grep -oE '\[from: [a-z][a-z-]*\]' \
        | sed -E 's/\[from: ([a-z-]+)\]/\1/' \
        | sort -u \
        || true
}
