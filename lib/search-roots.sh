#!/usr/bin/env bash
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
#                   disk AND the checkout is a git repo (the
#                   materializer needs an enumerable HEAD). The
#                   .siblings/<slug> path is the workdir-relative
#                   directory the materializer (sibling-symlinks.sh)
#                   populates after this helper runs.
#   missing       — slug in SOURCE_PATHS BUT either (a) the checkout
#                   directory is absent on this host or (b) the
#                   checkout exists but isn't a git repo (so the
#                   materializer can't enumerate it). All operator-
#                   config gaps (not a security boundary).
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
    local repo="$1" repo_dir="$2" base_ref="$3"
    local sibling_repo sibling_path
    local body=""
    local included=0 missing=0
    local sibling_list

    # Source of truth for the sibling allowlist:
    #   1. .knightwatch/siblings at <base_ref> (per-repo, future)
    #   2. "all REPOS slugs except self" (legacy fallback)
    #
    # <base_ref> is normally a SHA pinned upstream BEFORE `just test`
    # ran (so PR-controlled mid-test ref-rewrites can't redirect this
    # read). The fallback path preserves un-onboarded repos' current
    # behavior. Once every tracked repo has .knightwatch/siblings
    # committed, the fallback can be removed.
    local siblings=()
    sibling_list=$(read_knightwatch_file "$repo_dir" "$base_ref" "siblings")
    case $? in
        0)
            # PRESENT: per-repo allowlist. Parse line-by-line, ignore blanks + # comments.
            while IFS= read -r line; do
                line="${line%%#*}"           # strip inline comments
                line="${line//[[:space:]]/}" # strip whitespace
                [ -z "$line" ] && continue
                siblings+=("$line")
            done <<< "$sibling_list"
            ;;
        1)
            # ABSENT: default to all tracked REPOS minus self
            for sibling_repo in "${REPOS[@]}"; do
                [ "$sibling_repo" = "$repo" ] && continue
                siblings+=("$sibling_repo")
            done
            ;;
        *)
            # ERROR: knightwatch-config helper had a real failure (missing
            # base ref, corrupt object store, etc.). Fail loud rather than
            # misread as ABSENT — wrong sibling set silently broadens the
            # cross-repo grep surface.
            echo "search-roots: knightwatch-config error reading siblings for $repo" >&2
            return 2
            ;;
    esac

    for sibling_repo in "${siblings[@]}"; do
        [ "$sibling_repo" = "$repo" ] && continue
        sibling_path="${SOURCE_PATHS[$sibling_repo]:-}"
        # Three ways a declared sibling can be unavailable, all classified
        # as `missing` so the user sees them in coverage instead of as
        # silent drops:
        #   (a) operator has no SOURCE_PATHS entry — they haven't told us
        #       where to find it on this host
        #   (b) entry exists but the checkout directory is absent on disk
        #   (c) entry + dir exist but it isn't a git repo (corrupt clone,
        #       raw download, operator misconfig) — the materializer
        #       requires a git repo to pin a HEAD snapshot, so without
        #       this gate the coverage marker would say "full" while
        #       specialists searched a tree the materializer couldn't
        #       even enumerate. (Mechanism details belong in
        #       lib/sibling-symlinks.sh; this comment just notes what
        #       this gate is preventing.)
        # Cases (a)+(b) are operator-config gaps (NOT a security boundary).
        # Case (c) is what cncorp/plow#37 review 1 caught — the second
        # half of the BCR finding. Single-owner contract: if it can't
        # be searched, it isn't included.
        if [ -z "$sibling_path" ] || [ ! -d "$sibling_path" ]; then
            body+="$sibling_repo missing"$'\n'
            missing=$((missing + 1))
            continue
        fi
        if ! git -C "$sibling_path" rev-parse --git-dir >/dev/null 2>&1; then
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
