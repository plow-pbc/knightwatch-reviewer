#!/usr/bin/env bash
# Write-time Applied helper. Pure functions read stdin / take args; no
# global state. Sourced by lib/review-one-pr.sh (production hook) and
# lib/tests/applied-marker-unit.sh (unit tests).
#
# Contract: probe lines match `^N. [<sev>] [from: <specialist>] [<class>]`
# per prompts/aggregator.md step 6. Cited paths are taken ONLY from the
# `Files:` clause (single-line, semicolon-or-period-terminated) — Edit:
# describes the proposed remedy and is intentionally excluded.

# stdin: a review body. stdout: one TAB-separated `<specialist>\t<csv-paths>`
# record per probe with a `[from:]` tag. Probes without [from:] are dropped.
extract_probes_from_review() {
    awk '
    # Match a probe line. Capture specialist; capture rest (after the
    # 3rd []-block) for path scraping. Probes without [from:] are skipped.
    /^[0-9]+\. \[[^]]+\] \[from: [a-z][a-z-]*\] \[[^]]+\]/ {
        # Pull specialist out of the [from: X] slot.
        spec = $0
        sub(/^.*\[from: /, "", spec)
        sub(/\].*$/, "", spec)

        # Pull the Files: clause. It runs from "Files: " up to the next
        # "Edit:" or end of line. Clause is `Files: a, b/c.md, d:42`.
        files_seg = $0
        if (sub(/^.*Files: /, "", files_seg)) {
            # Trim at " Edit:" if present, then trim trailing punctuation.
            sub(/ Edit: .*$/, "", files_seg)
            sub(/[.;]$/, "", files_seg)
        } else {
            files_seg = ""
        }

        # Files: tokens are comma-separated paths, possibly with :LINE
        # suffix or backticks. Normalize: strip backticks, strip :NNN.
        n = split(files_seg, parts, /, */)
        out = ""
        for (i = 1; i <= n; i++) {
            p = parts[i]
            gsub(/`/, "", p)
            gsub(/^[ \t]+|[ \t]+$/, "", p)
            sub(/:[0-9]+$/, "", p)
            if (p == "") continue
            if (out == "") out = p; else out = out "," p
        }
        printf "%s\t%s\n", spec, out
    }
    '
}
