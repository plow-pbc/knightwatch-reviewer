#!/bin/bash
# Materialize sibling-repo symlinks under <workdir>/.siblings/<owner>/<repo>.
#
# Why: lib/search-roots.sh used to write absolute host paths (e.g.
# /home/odio/Hacking/plow-content) into .codex-scratch/search-roots.md,
# and specialists cited those paths back when they found a hit — leaking
# the reviewer's filesystem layout into public PR comments. Symlinking
# siblings into the workdir gives specialists a workdir-relative grep
# target (.siblings/<owner>/<repo>/...) and a citation form
# (<owner>/<repo>/<rel-path>) that's safe to post.
#
# Caller passes SOURCE_PATHS by name (bash declare -n). The current
# repo's own entry is NEVER symlinked — it'd alias the workdir to
# itself.

# materialize_sibling_symlinks <workdir> <current_repo> <source_paths_var_name>
materialize_sibling_symlinks() {
    local workdir="$1" current_repo="$2"
    local -n _src_paths="$3"
    local slug src target_dir

    mkdir -p "$workdir/.siblings"

    for slug in "${!_src_paths[@]}"; do
        [ "$slug" = "$current_repo" ] && continue
        src="${_src_paths[$slug]}"
        [ -z "$src" ] && continue
        [ -d "$src" ] || continue

        target_dir="$workdir/.siblings/$slug"
        mkdir -p "$(dirname "$target_dir")"
        ln -sfn "$src" "$target_dir"
    done
}
