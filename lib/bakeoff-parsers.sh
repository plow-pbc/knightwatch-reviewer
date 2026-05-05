#!/usr/bin/env bash
# Pure parsers for the specialist bake-off. Read from stdin, emit to stdout.
# No file I/O, no network — composable in pipelines + hermetic-testable.

# count_attributions: read a review body on stdin, emit one line per
# `[from: <specialist>]` attribution. Caller pipes through `sort | uniq -c`
# to aggregate.
count_attributions() {
    grep -oE '\[from: [a-z][a-z-]*\]' \
        | sed -E 's/\[from: ([a-z-]+)\]/\1/'
}
