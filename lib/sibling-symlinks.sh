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
# Two security-relevant design points:
#
# 1. Whitelist-gating happens UPSTREAM, in stage_search_roots. The
#    caller passes the explicit list of `included` slugs (those
#    whitelisted in SOURCE_PATHS AND with checkouts present on disk)
#    — this helper does NOT iterate over SOURCE_PATHS itself.
#    Otherwise we'd materialize symlinks for siblings whose checkouts
#    are absent — symlinks would dangle and specialists would get
#    confused.
#
# 2. The PR's own checkout might already contain `.siblings/` with a
#    committed symlink redirecting `.siblings/<owner>` (or any
#    intermediate) outside the workdir, e.g. to ~/.ssh/. If we just
#    `mkdir -p` and `ln -sfn` through that, our writes follow the
#    redirect. So we wipe the entire `.siblings/` subtree first and
#    create a fresh empty directory we own.

# materialize_sibling_symlinks <workdir> <source_paths_var_name> <included_slug>...
#
#   workdir            absolute path to the per-PR workdir
#   source_paths_var   name of the SOURCE_PATHS associative array
#                      (passed by name; bash declare -n)
#   included_slug...   variadic list of "<owner>/<repo>" entries that
#                      stage_search_roots classified as `included`
#                      (whitelisted + checkout-present). NOTHING
#                      outside this list gets symlinked. Empty list =
#                      empty .siblings/.
#
# Idempotent: safe to call multiple times in the same workdir.
materialize_sibling_symlinks() {
    local workdir="$1"
    local -n _src_paths="$2"
    shift 2
    local slug src target

    # Wipe whatever .siblings/ shipped in the PR checkout. `rm -rf`
    # removes symlinks as symlinks (it does not follow them as long as
    # the path doesn't end with a trailing slash), so a committed
    # `.siblings -> /etc/` redirect is unlinked rather than recursed
    # into. After this, the parent directory is one we just created.
    rm -rf "$workdir/.siblings"
    mkdir -p "$workdir/.siblings"

    for slug in "$@"; do
        src="${_src_paths[$slug]:-}"
        [ -z "$src" ] && continue
        [ -d "$src" ] || continue
        target="$workdir/.siblings/$slug"
        # The owner-level parent (e.g. .siblings/cncorp) was just
        # mkdir-ed inside our freshly-created .siblings/ so there's no
        # symlink to follow.
        mkdir -p "$(dirname "$target")"
        ln -sfn "$src" "$target"
    done
}
