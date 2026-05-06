#!/usr/bin/env bash
# Pure parsers for the specialist bake-off. Read from stdin, emit to stdout.
# No file I/O, no network — composable in pipelines + hermetic-testable.

# count_attributions: read review body(ies) on stdin, emit one specialist
# name per probe's RENDERED attribution slot. Anchored to the documented
# probe-line shape from prompts/aggregator.md step 6:
#   `N. [<severity>] [from: <specialist>] [<class>] ...`
# Only the leading [from: <specialist>] slot counts — inline mentions of
# `[from: <other>]` within probe prose, footer/README/doc tokens, and any
# unnumbered surface are excluded by construction. Caller pipes through
# `sort | uniq -c`. grep exits 1 on no match — normalize to 0.
count_attributions() {
    grep -oE '^[0-9]+\. \[[^]]+\] \[from: [a-z][a-z-]*\]' \
        | sed -E 's/.*\[from: ([a-z-]+)\]/\1/' \
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
