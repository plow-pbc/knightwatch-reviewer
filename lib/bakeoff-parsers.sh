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

# probe_cited_paths: read review body(ies) on stdin, emit one cited path
# per line for every probe that has a `Files:` clause. Anchored to the
# probe-line shape `N. [<sev>] [from: <spec>] [<class>] ...` per
# prompts/aggregator.md:162. Files-only — `Edit:` clause paths are
# intentionally excluded (the Edit: is the proposed remedy, not the
# subject the probe is about). [open] probes (no Files: clause today)
# silently emit nothing — they earn no Applied credit by construction.
# Caller pipes through grep/sort/uniq for set ops or counting.
probe_cited_paths() {
    awk '
    /^[0-9]+\. \[[^]]+\] \[from: [a-z][a-z-]*\]/ {
        # Extract the Files: segment. Terminator: " Edit:" (yes probes),
        # " If yes," (open probes that gain Files: in the future), or
        # end of line. Trim trailing punctuation.
        files_seg = $0
        if (sub(/^.*Files: /, "", files_seg)) {
            sub(/ Edit: .*$/, "", files_seg)
            sub(/ If yes,.*$/, "", files_seg)
            sub(/[.;]$/, "", files_seg)
        } else {
            next
        }
        # Each comma-separated token: strip backticks, leading/trailing
        # whitespace, and the optional `:LINE` suffix.
        n = split(files_seg, parts, /, */)
        for (i = 1; i <= n; i++) {
            p = parts[i]
            gsub(/`/, "", p)
            gsub(/^[ \t]+|[ \t]+$/, "", p)
            sub(/:[0-9]+$/, "", p)
            if (p != "") print p
        }
    }
    '
}

# Specialists invoked on this review, from the write-time bake-off marker.
# Format on the wire: `<!-- knightwatch-bakeoff: specialists=a,b,c -->` (one
# line, comma-separated). Tolerate optional whitespace before the closing
# `-->` since markdown comment writers commonly insert it. Emits one
# specialist per line.
extract_roster_marker() {
    grep -oE '<!-- knightwatch-bakeoff: specialists=[a-z][a-z,-]*[[:space:]]*-->' \
        | sed -E 's/.*specialists=([a-z,-]+).*/\1/' \
        | tr ',' '\n' \
        | grep -v '^$' || true
}

# Extracts the directly-targeted specialist from the leading `[from: X]`
# slot of each /${BOT_CMD_PREFIX}-props line. Subsequent `[from: ...]`
# tokens in the same line (prose mentions, contrasts) are intentionally
# ignored — one comment is one bool credit per specialist.
extract_props_attributions() {
    local prefix="${BOT_CMD_PREFIX:-srosro}"
    grep -oE "^/${prefix}-props \[from: [a-z][a-z-]*\]" \
        | sed -E 's/^.*\[from: ([a-z-]+)\]/\1/' \
        | sort -u || true
}

# Extracts the directly-targeted specialist from the leading `[from: X]`
# slot of each /${BOT_CMD_PREFIX}-critique line. Subsequent `[from: ...]`
# tokens in the same line (prose mentions, contrasts) are intentionally
# ignored — one comment is one bool credit per specialist.
extract_critique_attributions() {
    local prefix="${BOT_CMD_PREFIX:-srosro}"
    grep -oE "^/${prefix}-critique \[from: [a-z][a-z-]*\]" \
        | sed -E 's/^.*\[from: ([a-z-]+)\]/\1/' \
        | sort -u || true
}
