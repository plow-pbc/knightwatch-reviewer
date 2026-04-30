#!/bin/bash
# Coverage-state seam for cross-repo grep — whitelist-only.
#
# stage_search_roots is the single worker-owned helper that classifies
# every sibling repo from the SOURCE_PATHS whitelist into one of two
# explicit statuses, builds the .codex-scratch/search-roots.md content,
# and returns it on stdout. The dead-code-search and consumers prompts
# read this content as the sole source of truth for "which siblings
# did we cover, and why?". No silent coverage loss, no per-prompt
# rediscovery.
#
# Trust model: SOURCE_PATHS in repos.conf IS the whitelist. If the
# operator listed cncorp/plow-content there, that's affirmative
# consent to reference plow-content code in any PR review on a base
# repo whose entry includes it. No runtime gh-api permission check —
# the operator decides out-of-band, in repos.conf, with full context.
#
# Per-sibling status:
#   included      — slug in SOURCE_PATHS AND its checkout exists on
#                   disk. The .siblings/<slug> path is the workdir-
#                   relative symlink materialized by sibling-symlinks.sh
#                   after this helper runs.
#   missing       — slug in SOURCE_PATHS BUT its checkout absent on
#                   this host (operator-config gap, not a security
#                   boundary).
#
# Output format:
#   # coverage: full | partial | same-repo-only
#   <repo-slug> included .siblings/<repo-slug>
#   <repo-slug> missing
#   ...
#
# coverage: full           — every sibling with a SOURCE_PATHS entry has its checkout on disk
# coverage: same-repo-only — zero whitelisted siblings, OR none have their checkouts on disk
# coverage: partial        — at least one included AND at least one missing

stage_search_roots() {
    local repo="$1"
    local sibling_repo sibling_path
    local body=""
    local included=0 missing=0

    for sibling_repo in "${REPOS[@]}"; do
        [ "$sibling_repo" = "$repo" ] && continue
        sibling_path="${SOURCE_PATHS[$sibling_repo]:-}"
        # No SOURCE_PATHS entry = sibling not whitelisted at all (not a
        # coverage gap, just not configured). Skip silently.
        [ -z "$sibling_path" ] && continue
        if [ ! -d "$sibling_path" ]; then
            body+="$sibling_repo missing"$'\n'
            missing=$((missing + 1))
            continue
        fi
        body+="$sibling_repo included .siblings/$sibling_repo"$'\n'
        included=$((included + 1))
    done

    local total=$((included + missing))
    local header
    if [ "$total" -eq 0 ]; then
        header="# coverage: same-repo-only — no sibling SOURCE_PATHS in scope"
    elif [ "$included" -eq "$total" ]; then
        header="# coverage: full"
    elif [ "$included" -eq 0 ]; then
        header="# coverage: same-repo-only — included=0 missing=$missing"
    else
        header="# coverage: partial — included=$included missing=$missing"
    fi
    printf '%s\n%s' "$header" "$body"
}
