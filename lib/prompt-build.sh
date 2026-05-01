#!/bin/bash
# Sourceable helpers for assembling prompts.
#
# `safe_sed`: escape a string for use as a sed replacement.
# `substitute_placeholders`: substitute {{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
# {{PR_AUTHOR}}, {{SPECIALIST_NAME}}, and {{OPERATOR_NAME}} in a single prompt
# file. Used by build_specialist_prompt for both the common header AND the
# angle file, and directly by standalone prompts (e.g. the intent step) that
# should NOT inherit the specialist common header.
# `build_specialist_prompt`: assemble a specialist prompt by concatenating the
# substituted common header with the substituted angle file. The intent step
# does NOT use this — it has its own contract that conflicts with the
# specialist contract in common-header.md.
#
# {{OPERATOR_NAME}}: the human whose calibration / opinions back this bot
# (defaults to "Sam"; overridable so a forked install can re-skin the
# voice). Used by aggregator.md as a deflection device for opinionated
# low/nit findings ("blame OPERATOR_NAME, but…") so each PR's voice is
# novel — the deterministic surface stays bare-fact. Read from the
# OPERATOR_NAME env var so call sites don't need to know it exists; the
# aggregator template no-ops the substitution to "Sam" when unset.

safe_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

substitute_placeholders() {
    local prompt_file="$1" pr_id="$2" pr_title="$3" pr_url="$4" pr_author="$5" specialist_name="${6:-}"
    local operator_name="${OPERATOR_NAME:-Sam}"
    sed -e "s|{{PR_ID}}|$(safe_sed "$pr_id")|g" \
        -e "s|{{PR_TITLE}}|$(safe_sed "$pr_title")|g" \
        -e "s|{{PR_URL}}|$(safe_sed "$pr_url")|g" \
        -e "s|{{PR_AUTHOR}}|$(safe_sed "$pr_author")|g" \
        -e "s|{{SPECIALIST_NAME}}|$(safe_sed "$specialist_name")|g" \
        -e "s|{{OPERATOR_NAME}}|$(safe_sed "$operator_name")|g" \
        "$prompt_file"
}

build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5" pr_author="$6"
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
    {
        substitute_placeholders "$common" "$pr_id" "$pr_title" "$pr_url" "$pr_author" "$specialist_name"
        echo ""
        substitute_placeholders "$specialist_file" "$pr_id" "$pr_title" "$pr_url" "$pr_author" "$specialist_name"
    }
}
