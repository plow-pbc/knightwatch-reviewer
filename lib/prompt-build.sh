#!/bin/bash
# Sourceable helpers for assembling specialist prompts.
# `safe_sed`: escape a string for use as a sed replacement.
# `build_specialist_prompt`: concatenate prompts/common-header.md with an
# angle file, substituting {{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
# {{SPECIALIST_NAME}}, and {{PR_AUTHOR}}.

safe_sed() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

build_specialist_prompt() {
    local specialist_name="$1" specialist_file="$2" pr_id="$3" pr_title="$4" pr_url="$5" pr_author="$6"
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
    local esc_id esc_title esc_url esc_name esc_author
    esc_id=$(safe_sed "$pr_id")
    esc_title=$(safe_sed "$pr_title")
    esc_url=$(safe_sed "$pr_url")
    esc_name=$(safe_sed "$specialist_name")
    esc_author=$(safe_sed "$pr_author")
    {
        sed -e "s|{{PR_ID}}|$esc_id|g" \
            -e "s|{{PR_TITLE}}|$esc_title|g" \
            -e "s|{{PR_URL}}|$esc_url|g" \
            -e "s|{{SPECIALIST_NAME}}|$esc_name|g" \
            -e "s|{{PR_AUTHOR}}|$esc_author|g" \
            "$common"
        echo ""
        cat "$specialist_file"
    }
}
