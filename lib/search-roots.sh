#!/bin/bash
# Coverage-state seam for cross-repo grep.
#
# stage_search_roots is the single worker-owned helper that classifies
# every sibling repo into one of four explicit statuses, builds the
# .codex-scratch/search-roots.md content, and returns it on stdout. The
# dead-code-search and consumers prompts read this content as the sole
# source of truth for "which siblings did we cover, and why?". No
# silent coverage loss, no per-prompt rediscovery.
#
# Per-sibling status:
#   included      — author has push (admin/write/maintain) on the
#                   sibling repo AND its SOURCE_PATHS checkout exists.
#   excluded      — author lacks push access on the sibling.
#   missing       — sibling has a SOURCE_PATHS entry but its checkout
#                   directory is absent on this host (operator config
#                   issue, not a security boundary).
#   lookup-error  — gh api call to check collaborator status failed
#                   (network, rate limit). Distinct from "excluded"
#                   because we don't actually know if the author has
#                   access; the prompts must qualify their verdicts.
#
# Output format:
#   # coverage: full | partial | same-repo-only
#   <repo-slug> <status> [<absolute-path>]    (path only when status=included)
#   ...
#
# coverage: full        — every sibling that has a SOURCE_PATHS entry is `included`.
# coverage: same-repo-only — zero siblings with status=included.
# coverage: partial     — at least one included AND at least one not-included.
#
# Callers can stub the `gh` binary to test (the smoke does exactly that).

stage_search_roots() {
    local repo="$1" pr_author="$2"
    local sibling_repo sibling_path perm perm_exit
    local body=""
    local included=0 excluded=0 missing=0 lookup_error=0

    for sibling_repo in "${REPOS[@]}"; do
        [ "$sibling_repo" = "$repo" ] && continue
        sibling_path="${SOURCE_PATHS[$sibling_repo]:-}"
        # No SOURCE_PATHS entry = sibling not in scope at all (not a
        # coverage gap, just not configured). Skip silently.
        [ -z "$sibling_path" ] && continue
        if [ ! -d "$sibling_path" ]; then
            body+="$sibling_repo missing"$'\n'
            missing=$((missing + 1))
            continue
        fi
        # Direct gh api call so we can distinguish lookup-error from
        # excluded — is_trusted_repo_author collapses both into false,
        # which loses provenance. perm_exit=0 with empty perm shouldn't
        # happen on a successful call (gh always emits a permission
        # value for a 200), but treat it as lookup-error too to be safe.
        perm=$(gh api "repos/$sibling_repo/collaborators/$pr_author/permission" --jq '.permission' 2>/dev/null)
        perm_exit=$?
        if [ "$perm_exit" -ne 0 ] || [ -z "$perm" ]; then
            body+="$sibling_repo lookup-error"$'\n'
            lookup_error=$((lookup_error + 1))
            continue
        fi
        case "$perm" in
            admin|write|maintain)
                body+="$sibling_repo included $sibling_path"$'\n'
                included=$((included + 1))
                ;;
            *)
                body+="$sibling_repo excluded"$'\n'
                excluded=$((excluded + 1))
                ;;
        esac
    done

    local total=$((included + excluded + missing + lookup_error))
    local header
    if [ "$total" -eq 0 ]; then
        header="# coverage: same-repo-only — no sibling SOURCE_PATHS in scope"
    elif [ "$included" -eq "$total" ]; then
        header="# coverage: full"
    elif [ "$included" -eq 0 ]; then
        header="# coverage: same-repo-only — included=0 excluded=$excluded missing=$missing lookup-error=$lookup_error"
    else
        header="# coverage: partial — included=$included excluded=$excluded missing=$missing lookup-error=$lookup_error"
    fi
    printf '%s\n%s' "$header" "$body"
}
