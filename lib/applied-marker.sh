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

# args: $1 = path to a file (or process substitution) listing touched paths,
#       one per line.
# stdin: probe records from extract_probes_from_review (specialist\tcsv-paths).
# stdout: per-specialist applied count (specialist\tcount), no header,
#         only specialists with count>=1.
compute_applied() {
    local touched_file="$1"
    awk -v touched_file="$touched_file" '
    BEGIN {
        # Load touched-path set from the file passed via -v.
        while ((getline line < touched_file) > 0) {
            if (line != "") touched[line] = 1
        }
        close(touched_file)
    }
    {
        spec = $1
        paths = $2
        if (paths == "") next
        n = split(paths, ps, ",")
        for (i = 1; i <= n; i++) {
            if (ps[i] in touched) {
                count[spec]++
                next  # one match is enough for this probe
            }
        }
    }
    END {
        for (s in count) printf "%s\t%d\n", s, count[s]
    }
    '
}

# Marker that the bake-off greps for. Single-line on purpose so the JSON
# survives any markdown-renderer line-wrapping in mobile clients.
APPLIED_MARKER_PREFIX='<!-- knightwatch-applied: '
APPLIED_MARKER_SUFFIX=' -->'

# stdin: per-specialist applied counts (specialist\tcount, output of
# compute_applied). stdout: one-line marker + human-readable prose.
# Empty input → empty output (no probes applied → don't dirty the comment).
render_applied_footer() {
    local lines
    lines=$(cat)
    [ -z "$lines" ] && return 0

    local json prose total
    json=$(printf '%s\n' "$lines" \
        | jq -Rs 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): (.[1] | tonumber)}) | add | {applied: .}' \
        -c)
    total=$(printf '%s\n' "$lines" | awk 'NF >= 2 {s += $2} END {print s}')
    prose=$(printf '%s\n' "$lines" | awk -F'\t' 'NF >= 2 {printf "%s×%d, ", $1, $2}' | sed 's/, $//')

    printf '%s%s%s\n' "$APPLIED_MARKER_PREFIX" "$json" "$APPLIED_MARKER_SUFFIX"
    printf '**Applied since this review:** %d probe(s) — %s.\n' "$total" "$prose"
}

# Strip a previously-rendered footer from a body. Invariants the strip
# must preserve: any line not in the marker+footer block stays intact;
# trailing newline behavior matches the input. We match the marker line,
# then optionally one following "**Applied since this review:**" line.
strip_applied_footer() {
    awk -v prefix="$APPLIED_MARKER_PREFIX" '
    BEGIN { skip_next = 0 }
    {
        if (skip_next) { skip_next = 0; next }
        if (index($0, prefix) == 1) { skip_next = 1; next }
        print
    }
    '
}

# Edit the prior review comment in place: strip any existing applied
# footer, append the freshly-rendered one. PATCH via gh api. Idempotent
# on re-run.
#
# args: $1=repo (owner/name), $2=comment_id, $3=footer_text (output of
#       render_applied_footer; may be empty, in which case we just strip).
# Returns 0 on success, non-zero on gh failure.
patch_review_with_applied() {
    local repo="$1" comment_id="$2" footer="$3"
    local body new_body
    body=$(gh api "repos/$repo/issues/comments/$comment_id" --jq .body) || return 1
    new_body=$(printf '%s' "$body" | strip_applied_footer)
    if [ -n "$footer" ]; then
        new_body=$(printf '%s\n\n%s\n' "$new_body" "$footer")
    fi
    # gh api PATCH with --input - reads JSON from stdin; jq builds the
    # JSON safely so backticks/quotes in the body don't break shell.
    jq -n --arg b "$new_body" '{body: $b}' \
        | gh api "repos/$repo/issues/comments/$comment_id" --method PATCH --input - >/dev/null
}
