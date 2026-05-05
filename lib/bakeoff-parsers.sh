#!/usr/bin/env bash
# Pure parsers for the specialist bake-off. Read from stdin, emit to stdout.
# No file I/O, no network — composable in pipelines + hermetic-testable.
#
# Also sources lib/auth.sh to expose is_trusted_repo_author — the canonical
# trust-gate shared by review.sh, learn-from-replies.sh, and
# specialist-bakeoff.sh. Single source of truth lives in auth.sh; this file
# is the one-stop import for the bake-off driver.
_BAKEOFF_PARSERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_BAKEOFF_PARSERS_DIR/auth.sh"

# count_attributions: read a review body on stdin, emit one line per
# `[from: <specialist>]` attribution. Caller pipes through `sort | uniq -c`
# to aggregate. grep exits 1 when no match — normalize to 0 so callers
# under set -e don't abort when a review has no attributions.
count_attributions() {
    grep -oE '\[from: [a-z][a-z-]*\]' \
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
