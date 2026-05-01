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
# Trust model: SOURCE_PATHS in repos.conf is the operator's checkout
# layout (which slugs map to which on-disk paths). The PER-REPO sibling
# allowlist now lives in each repo's .knightwatch/siblings file, read
# from the base branch only via lib/knightwatch-config.sh. PR-head
# edits to .knightwatch/siblings don't take effect until merged. When
# the file is absent, falls back to "all REPOS slugs minus self" — the
# legacy behavior — so un-onboarded repos keep working.
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
    local repo="$1" repo_dir="$2" default_branch="$3"
    local sibling_repo sibling_path
    local body=""
    local included=0 missing=0
    local sibling_list

    # Source of truth for the sibling allowlist:
    #   1. .knightwatch/siblings on the base branch (per-repo, future)
    #   2. "all REPOS slugs except self" (legacy fallback)
    #
    # The fallback path preserves un-onboarded repos' current behavior.
    # Once every tracked repo has .knightwatch/siblings committed, the
    # fallback can be removed.
    local siblings=()
    if sibling_list=$(read_knightwatch_file "$repo_dir" "$default_branch" "siblings"); then
        # Per-repo allowlist: parse line-by-line, ignore blanks + # comments.
        while IFS= read -r line; do
            line="${line%%#*}"           # strip inline comments
            line="${line//[[:space:]]/}" # strip whitespace
            [ -z "$line" ] && continue
            siblings+=("$line")
        done <<< "$sibling_list"
    else
        # Fallback: all REPOS minus self
        for sibling_repo in "${REPOS[@]}"; do
            [ "$sibling_repo" = "$repo" ] && continue
            siblings+=("$sibling_repo")
        done
    fi

    for sibling_repo in "${siblings[@]}"; do
        [ "$sibling_repo" = "$repo" ] && continue
        sibling_path="${SOURCE_PATHS[$sibling_repo]:-}"
        # Two ways a declared sibling can be unavailable: (a) operator
        # has no SOURCE_PATHS entry for the slug — they haven't told us
        # where to find it on this host; (b) entry exists but the
        # checkout directory is absent on disk. Both are operator-config
        # gaps (NOT a security boundary) and both classify as `missing`
        # so the user sees them in coverage rather than silent drops.
        if [ -z "$sibling_path" ] || [ ! -d "$sibling_path" ]; then
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
        header="# coverage: same-repo-only — no siblings in scope"
    elif [ "$included" -eq "$total" ]; then
        header="# coverage: full"
    elif [ "$included" -eq 0 ]; then
        header="# coverage: same-repo-only — included=0 missing=$missing"
    else
        header="# coverage: partial — included=$included missing=$missing"
    fi
    printf '%s\n%s' "$header" "$body"
}
