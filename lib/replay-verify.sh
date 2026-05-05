#!/usr/bin/env bash
# Run a fixture-driven replay verification.
#
# Usage:
#   lib/replay-verify.sh --fixture FIXTURE.md [--prompts DIR] [--output-dir PATH]
#   lib/replay-verify.sh --fixture FIXTURE.md --no-replay AGGREGATOR_OUTPUT.md
#
# In default mode, invokes lib/replay.sh with --repo/--pr/--sha derived from
# the fixture's frontmatter, then asserts the resulting aggregator-output.md
# against the fixture's expected_verdict + expected_contains + expected_absent
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

# --- Parse a fixture section (exact-match section header) -----------------
# Emits all non-empty lines between `## <section>` (exact match, no prefix
# accepted) and the next `## ` header. Exact match prevents `expected_verdict`
# from accidentally matching `expected_verdict_old` or any other typo'd
# section header — fixture-as-contract: malformed section names must fail
# parse, not silently match a similar one.
parse_section() {
    local section="$1" file="$2"
    awk -v section="$section" '
        $0 == "## " section { in_block = 1; next }
        /^## / && in_block { exit }
        in_block && NF > 0 { print }
    ' "$file"
}

# --- Parse expected_verdict ------------------------------------------------
# Shape: one VERDICT value (APPROVE / COMMENT) per fixture. We take the
# first non-empty line of the section.
EXPECTED_VERDICT=$(parse_section "expected_verdict" "$FIXTURE" | head -1)

# Fixture-as-contract: a fixture without expected_verdict is malformed.
# Without this guard, the runtime verdict-check block would skip silently
# (its `[ -n "$EXPECTED_VERDICT" ]` predicate falls through), reaching
# `verify-replay: ALL PASS` without asserting the production contract.
if [ -z "$EXPECTED_VERDICT" ]; then
    echo "FAIL: fixture $FIXTURE missing or empty ## expected_verdict section" >&2
    exit 2
fi

# Sealed section contract: any `## expected_*` header outside the canonical
# set is a fixture typo and must fail-fast. Without this, `## expected_contans`
# (typo for `## expected_contains`) silently no-ops — fixture has no
# enforcement, verifier reaches `verify-replay: ALL PASS` false-green.
unknown_sections=$(awk '
    /^## expected_/ {
        # Strip "## " prefix; everything after the first space (if any) is comment
        sub("^## ", "")
        sub("[ ].*$", "")
        if ($0 != "expected_verdict" && $0 != "expected_contains" && $0 != "expected_absent") {
            print $0
        }
    }
' "$FIXTURE")
if [ -n "$unknown_sections" ]; then
    echo "FAIL: fixture $FIXTURE has unknown expected_* section(s): $unknown_sections" >&2
    echo "       canonical sections: expected_verdict, expected_contains, expected_absent" >&2
    exit 2
fi

# --- Run replay (or skip) --------------------------------------------------
if [ -z "$NO_REPLAY" ]; then
    LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
    . "$LIB_DIR/replay-paths.sh"
    # Both lib/replay.sh and the verifier derive the same default path
    # via lib/replay-paths.sh, so the verifier can read replay's output
    # without forcing --output-dir. When --output-dir IS passed, propagate.
    PROMPT_SLUG="$(replay_prompt_slug "${PROMPTS:-}")"
    DERIVED_OUT="${OUT_DIR:-$HOME/.pr-reviewer/replays/$(replay_run_dir "$REPO" "$PR" "$SHA" "$PROMPT_SLUG")}"
    REPLAY_ARGS=(--repo "$REPO" --pr "$PR" --sha "$SHA")
    [ -n "$PROMPTS" ] && REPLAY_ARGS+=(--prompts "$PROMPTS")
    [ -n "$OUT_DIR" ] && REPLAY_ARGS+=(--output-dir "$OUT_DIR")
    "$LIB_DIR/replay.sh" "${REPLAY_ARGS[@]}"
    AGG="$DERIVED_OUT/aggregator-output.md"
else
    AGG="$NO_REPLAY"
fi
[ -f "$AGG" ] || { echo "FAIL: aggregator-output not found at $AGG" >&2; exit 1; }

# --- Verify ---------------------------------------------------------------
PASS=1

# Verdict check — read the LAST VERDICT line to match production
# (lib/review-one-pr.sh:1166) and the aggregator contract
# (prompts/aggregator.md:196 — "On the VERY LAST LINE of your output").
# Rendered reviews can quote earlier verdict-shaped text (e.g. a previous
# review's "VERDICT: APPROVE"); using head -1 would assert against that
# quoted line and bypass production's contract.
#
# EXPECTED_VERDICT is guaranteed non-empty by the parse-time guard above
# (mandatory section, exits 2 if missing). `|| true` on the grep keeps a
# missing-VERDICT in the aggregator-output as a recoverable FAIL: rather
# than letting `set -euo pipefail` kill the script before any diagnostic
# is emitted.
actual_verdict=$(grep -E '^VERDICT:' "$AGG" | tail -1 | awk '{print $2}' || true)
if [ -z "$actual_verdict" ]; then
    echo "  FAIL: aggregator-output has no VERDICT: line — malformed review" >&2
    PASS=0
elif [ "$actual_verdict" = "$EXPECTED_VERDICT" ]; then
    echo "  PASS: verdict $actual_verdict (expected $EXPECTED_VERDICT)"
else
    echo "  FAIL: verdict mismatch — expected $EXPECTED_VERDICT, got $actual_verdict" >&2
    PASS=0
fi

# expected_contains: each substring must appear (case-insensitive) somewhere
# in the rendered aggregator-output. Match is whole-document — use distinct
# entries for distinct concerns rather than trying to encode joint shape.
parse_substrings() {
    local section="$1" file="$2"
    parse_section "$section" "$file" | awk '
        /^- / {
            sub("^- ", "")
            sub("[ ]+$", "")
            if (NF > 0) print
        }
    '
}

while IFS= read -r kw; do
    [ -z "$kw" ] && continue
    if grep -qiF -- "$kw" "$AGG"; then
        echo "  PASS: expected_contains '$kw'"
    else
        echo "  FAIL: expected_contains '$kw' not found in aggregator-output" >&2
        PASS=0
    fi
done < <(parse_substrings "expected_contains" "$FIXTURE")

while IFS= read -r kw; do
    [ -z "$kw" ] && continue
    if grep -qiF -- "$kw" "$AGG"; then
        echo "  FAIL: expected_absent '$kw' found in aggregator-output (false-positive guard tripped)" >&2
        PASS=0
    else
        echo "  PASS: expected_absent '$kw' not present"
    fi
done < <(parse_substrings "expected_absent" "$FIXTURE")

if [ "$PASS" = 1 ]; then
    echo "verify-replay: ALL PASS"
    exit 0
else
    echo "verify-replay: ONE OR MORE FAIL" >&2
    exit 1
fi
