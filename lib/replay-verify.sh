#!/usr/bin/env bash
# Run a fixture-driven replay verification.
#
# Usage:
#   lib/replay-verify.sh --fixture FIXTURE.md [--prompts DIR] [--output-dir PATH]
#   lib/replay-verify.sh --fixture FIXTURE.md --no-replay AGGREGATOR_OUTPUT.md
#
# In default mode, invokes lib/replay.sh with --repo/--pr/--sha derived from
# the fixture's frontmatter, then asserts the resulting aggregator-output.md
# against the fixture's expected_verdict + expected_findings + expected_NOT
# blocks.
#
# In --no-replay mode, skips replay invocation and asserts directly against
# the supplied aggregator-output.md. Used by the smoke test (no codex burn)
# and by operators re-checking a prior replay's outputs against a fixture.
#
# Exit codes:
#   0 — all expectations met
#   1 — at least one expectation failed (per-line FAIL: diagnostic on stderr)
#   2 — argument / fixture parse error
#
# Trust boundary: when default mode invokes lib/replay.sh, that script's
# trust caveats apply (see lib/replay.sh header). --no-replay mode reads
# only local files; safe to run against artifacts of arbitrary origin.

set -euo pipefail

FIXTURE=""
NO_REPLAY=""
PROMPTS=""
OUT_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --fixture) FIXTURE="$2"; shift 2 ;;
        --no-replay) NO_REPLAY="$2"; shift 2 ;;
        --prompts) PROMPTS="$2"; shift 2 ;;
        --output-dir) OUT_DIR="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$FIXTURE" ] || { echo "usage: $0 --fixture FIXTURE.md [--no-replay AGG.md] [--prompts DIR] [--output-dir PATH]" >&2; exit 2; }
[ -f "$FIXTURE" ] || { echo "fixture not found: $FIXTURE" >&2; exit 2; }

# --- Parse frontmatter (--- delimited) -------------------------------------
read_frontmatter_field() {
    local field="$1" file="$2"
    awk -v field="$field" '
        BEGIN { in_fm = 0 }
        /^---$/ { in_fm = !in_fm; next }
        in_fm && $1 == field":" {
            sub(field":[ ]*", "")
            print
            exit
        }
    ' "$file"
}

REPO=$(read_frontmatter_field "repo" "$FIXTURE")
PR=$(read_frontmatter_field "pr" "$FIXTURE")
SHA=$(read_frontmatter_field "sha" "$FIXTURE")

if [ -z "$NO_REPLAY" ]; then
    [ -n "$REPO" ] && [ -n "$PR" ] && [ -n "$SHA" ] || {
        echo "FAIL: fixture missing repo/pr/sha frontmatter: $FIXTURE" >&2
        exit 2
    }
fi

# --- Parse expected_verdict ------------------------------------------------
EXPECTED_VERDICT=$(awk '
    /^## expected_verdict/ { in_block = 1; next }
    /^## / && in_block { exit }
    in_block && NF > 0 { print; exit }
' "$FIXTURE")

# --- Parse expected_findings + expected_NOT --------------------------------
# Yields one line per finding-block: name|keywords_all|keywords_any|severity_min|class_any
parse_finding_blocks() {
    local section="$1" file="$2"
    awk -v section="$section" '
        $0 == "## " section { in_section = 1; next }
        /^## / && in_section { exit }
        in_section && /^- name:/ {
            if (cur_name != "") {
                printf "%s|%s|%s|%s|%s\n", cur_name, cur_all, cur_any, cur_sev, cur_class
            }
            sub("^- name:[ ]*", "")
            cur_name = $0
            cur_all = ""; cur_any = ""; cur_sev = ""; cur_class = ""
            next
        }
        in_section && /^[ ]+keywords_all:/ {
            sub(".*keywords_all:[ ]*\\[", ""); sub("\\][ ]*$", "")
            cur_all = $0
            next
        }
        in_section && /^[ ]+keywords_any:/ {
            sub(".*keywords_any:[ ]*\\[", ""); sub("\\][ ]*$", "")
            cur_any = $0
            next
        }
        in_section && /^[ ]+severity_min:/ {
            sub(".*severity_min:[ ]*", "")
            cur_sev = $0
            next
        }
        in_section && /^[ ]+class_any:/ {
            sub(".*class_any:[ ]*\\[", ""); sub("\\][ ]*$", "")
            cur_class = $0
            next
        }
        END {
            if (cur_name != "") {
                printf "%s|%s|%s|%s|%s\n", cur_name, cur_all, cur_any, cur_sev, cur_class
            }
        }
    ' "$file"
}

# --- Severity ladder -------------------------------------------------------
sev_rank() {
    case "$1" in
        low) echo 1 ;;
        medium) echo 2 ;;
        blocking) echo 3 ;;
        *) echo 0 ;;
    esac
}

# --- Probe-line matcher ----------------------------------------------------
# A "probe line" in the rendered aggregator-output looks like:
#   - [from: simplification] **Q:** ... `Severity: medium` `Class: simplification`
# Match: every keywords_all term + at least one keywords_any term + severity ≥ min + class ∈ class_any (if present).
# Returns 0 if any probe in the aggregator-output matches; 1 if none.
probe_matches() {
    local agg="$1" all="$2" any="$3" sev_min="$4" class_set="$5"
    local sev_min_rank
    sev_min_rank=$(sev_rank "$sev_min")
    [ -z "$sev_min" ] && sev_min_rank=0

    while IFS= read -r line; do
        # Required: every all-keyword present
        local ok_all=1
        if [ -n "$all" ]; then
            IFS=',' read -ra all_kw <<<"$all"
            for kw in "${all_kw[@]}"; do
                kw=$(echo "$kw" | sed 's/^[ "]*//; s/[ "]*$//')
                [ -z "$kw" ] && continue
                grep -qiF -- "$kw" <<<"$line" || { ok_all=0; break; }
            done
        fi
        [ "$ok_all" = 1 ] || continue

        # Required: at least one any-keyword present (if list non-empty)
        local ok_any=1
        if [ -n "$any" ]; then
            ok_any=0
            IFS=',' read -ra any_kw <<<"$any"
            for kw in "${any_kw[@]}"; do
                kw=$(echo "$kw" | sed 's/^[ "]*//; s/[ "]*$//')
                [ -z "$kw" ] && continue
                if grep -qiF -- "$kw" <<<"$line"; then ok_any=1; break; fi
            done
        fi
        [ "$ok_any" = 1 ] || continue

        # Severity gate
        if [ "$sev_min_rank" -gt 0 ]; then
            local line_sev=""
            if [[ "$line" =~ Severity:[[:space:]]*(low|medium|blocking) ]]; then
                line_sev="${BASH_REMATCH[1]}"
            fi
            local line_sev_rank
            line_sev_rank=$(sev_rank "$line_sev")
            [ "$line_sev_rank" -ge "$sev_min_rank" ] || continue
        fi

        # Class gate
        if [ -n "$class_set" ]; then
            local line_class=""
            if [[ "$line" =~ Class:[[:space:]]*([a-zA-Z-]+) ]]; then
                line_class="${BASH_REMATCH[1]}"
            fi
            local ok_class=0
            IFS=',' read -ra class_kw <<<"$class_set"
            for c in "${class_kw[@]}"; do
                c=$(echo "$c" | sed 's/^[ "]*//; s/[ "]*$//')
                [ "$line_class" = "$c" ] && { ok_class=1; break; }
            done
            [ "$ok_class" = 1 ] || continue
        fi

        return 0
    done < <(grep -E '^\s*-\s+\[from:' "$agg" || true)
    return 1
}

# --- Run replay (or skip) --------------------------------------------------
if [ -z "$NO_REPLAY" ]; then
    LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
    REPLAY_ARGS=(--repo "$REPO" --pr "$PR" --sha "$SHA")
    [ -n "$PROMPTS" ] && REPLAY_ARGS+=(--prompts "$PROMPTS")
    [ -n "$OUT_DIR" ] && REPLAY_ARGS+=(--output-dir "$OUT_DIR")
    "$LIB_DIR/replay.sh" "${REPLAY_ARGS[@]}"
    AGG="${OUT_DIR:-replays/${REPO//\//-}-${PR}-${SHA:0:7}-default}/aggregator-output.md"
else
    AGG="$NO_REPLAY"
fi
[ -f "$AGG" ] || { echo "FAIL: aggregator-output not found at $AGG" >&2; exit 1; }

# --- Verify ---------------------------------------------------------------
PASS=1

# Verdict check
if [ -n "$EXPECTED_VERDICT" ]; then
    actual_verdict=$(grep -E '^VERDICT:' "$AGG" | head -1 | awk '{print $2}')
    if [ "$actual_verdict" = "$EXPECTED_VERDICT" ]; then
        echo "  PASS: verdict $actual_verdict (expected $EXPECTED_VERDICT)"
    else
        echo "  FAIL: verdict mismatch — expected $EXPECTED_VERDICT, got $actual_verdict" >&2
        PASS=0
    fi
fi

# expected_findings
while IFS='|' read -r name all any sev_min class_set; do
    [ -z "$name" ] && continue
    if probe_matches "$AGG" "$all" "$any" "$sev_min" "$class_set"; then
        echo "  PASS: expected_finding '$name'"
    else
        echo "  FAIL: expected_finding '$name' not satisfied (no probe matched all|any|severity|class criteria)" >&2
        PASS=0
    fi
done < <(parse_finding_blocks "expected_findings" "$FIXTURE")

# expected_NOT
while IFS='|' read -r name all any sev_min class_set; do
    [ -z "$name" ] && continue
    if probe_matches "$AGG" "$all" "$any" "$sev_min" "$class_set"; then
        echo "  FAIL: expected_NOT triggered — '$name' (a probe matched the bad-pattern criteria)" >&2
        PASS=0
    else
        echo "  PASS: expected_NOT '$name' clean"
    fi
done < <(parse_finding_blocks "expected_NOT" "$FIXTURE")

if [ "$PASS" = 1 ]; then
    echo "verify-replay: ALL PASS"
    exit 0
else
    echo "verify-replay: ONE OR MORE FAIL" >&2
    exit 1
fi
