#!/usr/bin/env bash
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
    local common="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/common-header.md"
    {
        substitute_placeholders "$common" "$pr_id" "$pr_title" "$pr_url" "$pr_author" "$specialist_name"
        echo ""
        substitute_placeholders "$specialist_file" "$pr_id" "$pr_title" "$pr_url" "$pr_author" "$specialist_name"
    }
}

# build_aggregator_prompt PR_ID PR_TITLE PR_URL PR_AUTHOR
#
# Same shape as substitute_placeholders on aggregator.md, but stitches
# in prompts/voice.md (the operator-tunable voice + tone instructions)
# at the `<!-- INSERT_VOICE_HERE -->` marker before substituting
# placeholders. Lets operators reshape the bot's voice without touching
# aggregator.md, which carries the load-bearing review-production logic
# (severity calibration, ranking rules, output structure).
#
# Marker-not-found is a fail-fast condition — silently posting a review
# with no voice block when the operator wired a marker would mean the
# stitch logic regressed and the operator hasn't noticed. voice.md
# missing on disk is also fail-fast: voice.md is part of the install
# (install.sh symlinks the whole prompts/ dir), and a missing one means
# an incomplete deploy, not "operator opted out."
build_aggregator_prompt() {
    local pr_id="$1" pr_title="$2" pr_url="$3" pr_author="$4"
    local prompts_dir="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}"
    local aggregator="$prompts_dir/aggregator.md"
    local voice="$prompts_dir/voice.md"
    if [ ! -f "$voice" ]; then
        printf 'build_aggregator_prompt: voice.md missing at %s — incomplete install\n' "$voice" >&2
        return 1
    fi
    # Permissive marker match: any line containing `INSERT_VOICE_HERE`
    # (e.g. annotated `<!-- INSERT_VOICE_HERE — stitched in from … -->`)
    # is the stitch point. Pinning to the exact close-comment form
    # `<!-- INSERT_VOICE_HERE -->` was brittle — a regression noted by
    # the round-5 bot review where a one-line annotated marker passed
    # human eyes but failed the grep gate, aborting the worker before
    # posting. Single contract: `INSERT_VOICE_HERE` substring marks the
    # spot, no fallback parsing.
    if ! grep -qF 'INSERT_VOICE_HERE' "$aggregator"; then
        printf 'build_aggregator_prompt: aggregator.md missing INSERT_VOICE_HERE marker — stitch contract violated\n' >&2
        return 1
    fi
    # voice.md may begin with an HTML-comment block of operator docs
    # (how to customize, what placeholders are available). Those notes
    # are useful for humans editing the file but are noise for the LLM
    # — strip a leading <!-- … --> block before stitching. Operators
    # who want their docs visible to the LLM can place them after the
    # first markdown content. Conservative: only the FIRST line opening
    # with `<!--` triggers strip mode; the rest of the file flows
    # through verbatim.
    local voice_body
    voice_body=$(awk '
        NR == 1 && /^<!--/ { in_doc = 1 }
        in_doc && /-->/    { in_doc = 0; next }
        in_doc             { next }
                           { print }
    ' "$voice")
    # awk stitches voice_body in place of the marker line. voice.md is
    # the operator's surface — read it as data; awk does no expansion.
    # Substitution of placeholders (including {{OPERATOR_NAME}} which
    # voice.md uses) runs on the combined text afterwards.
    # BSD awk (macOS default) rejects newlines inside -v values; use a
    # tempfile + getline so this works on both BSD awk and gawk without
    # adding a gawk dependency.
    local voice_tmp
    voice_tmp=$(mktemp)
    printf '%s' "$voice_body" > "$voice_tmp"
    local stitched
    stitched=$(awk -v vfile="$voice_tmp" '
        /INSERT_VOICE_HERE/ {
            while ((getline line < vfile) > 0) print line
            close(vfile)
            next
        }
        { print }
    ' "$aggregator")
    rm -f "$voice_tmp"
    substitute_placeholders <(printf '%s' "$stitched") "$pr_id" "$pr_title" "$pr_url" "$pr_author"
}
