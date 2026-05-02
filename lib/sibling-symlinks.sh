#!/usr/bin/env bash
# Materialize sibling-repo content under <workdir>/.siblings/<owner>/<repo>.
#
# Why: lib/search-roots.sh used to write absolute host paths (e.g.
# /home/odio/Hacking/plow-content) into .codex-scratch/search-roots.md,
# and specialists cited those paths back when they found a hit — leaking
# the reviewer's filesystem layout into public PR comments. Materializing
# siblings into the workdir gives specialists a workdir-relative grep
# target (.siblings/<owner>/<repo>/...) and a citation form
# (<owner>/<repo>/<rel-path>) that's safe to post.
#
# Three security-relevant design points:
#
# 1. Whitelist-gating happens UPSTREAM, in stage_search_roots. The
#    caller passes the explicit list of `included` slugs (those
#    whitelisted in SOURCE_PATHS AND with checkouts present on disk
#    AND a git repo). This helper does NOT iterate over SOURCE_PATHS
#    itself. Otherwise we'd materialize entries for siblings whose
#    checkouts are absent — confusing specialists.
#
# 2. The PR's own checkout might already contain `.siblings/` with a
#    committed symlink redirecting `.siblings/<owner>` (or any
#    intermediate) outside the workdir, e.g. to ~/.ssh/. If we just
#    `mkdir -p` and write through that, our writes follow the redirect.
#    So we wipe the entire `.siblings/` subtree first and create a
#    fresh empty directory we own.
#
# 3. The materialized tree exposes ONLY committed blobs from a
#    pinned snapshot SHA (resolved once via `git rev-parse HEAD`,
#    then used for both `git ls-tree -r -z $sha` and `git show
#    $sha:<path>`), not the raw checkout root or worktree state. Per-machine artifacts that
#    aren't part of the sibling's source — `.git/`, `.venv/`,
#    `node_modules/`, `__pycache__/`, lockfile byproducts — never
#    appear, and uncommitted edits to tracked files (secrets in
#    progress, debug prints, WIP comments) cannot leak either. Mode
#    filtering excludes tracked symlinks (120000) and gitlinks /
#    submodules (160000). The materialized files are REAL FILES, not
#    symlinks, because `grep -r` skips symlinks during recursive
#    traversal — per-file symlinks would silently produce zero hits
#    on every consumer/dead-code grep, defeating the search-roots
#    contract while reporting "full" coverage. Caught across PR #37
#    review rounds 1-4 (Bug-Class-Recurrence; the structural shape
#    that eliminates the class is "committed git blobs only,
#    materialization either succeeds completely or aborts the review").

# materialize_sibling_symlinks <workdir> <source_paths_var_name> <included_slug>...
#
#   workdir            absolute path to the per-PR workdir
#   source_paths_var   name of the SOURCE_PATHS associative array
#                      (passed by name; bash declare -n)
#   included_slug...   variadic list of "<owner>/<repo>" entries that
#                      stage_search_roots classified as `included`
#                      (whitelisted + checkout-present + git repo).
#                      NOTHING outside this list gets materialized.
#                      Empty list = empty .siblings/.
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

    local entry mode rel list_file snap_sha
    for slug in "$@"; do
        src="${_src_paths[$slug]:-}"
        # No silent skips. By the time we get here, stage_search_roots
        # has already classified this slug `included` (SOURCE_PATHS
        # entry present + dir on disk + git repo), so an empty src or
        # missing dir means a race between classification and now. Fail
        # loud so the review aborts instead of writing search-roots.md
        # with an `included` slug whose .siblings/<slug>/ is empty.
        # PR #37 review 4 finding 2 (BCR — 4th instance of silent-
        # coverage-loss class).
        if [ -z "$src" ]; then
            echo "materialize_sibling_symlinks: no SOURCE_PATHS entry for $slug (raced classification?)" >&2
            return 1
        fi
        if [ ! -d "$src" ]; then
            echo "materialize_sibling_symlinks: $src not a directory for $slug (deleted after classification?)" >&2
            return 1
        fi
        target="$workdir/.siblings/$slug"
        # The owner-level parent (e.g. .siblings/cncorp) was just
        # mkdir-ed inside our freshly-created .siblings/ so there's no
        # symlink to follow.
        mkdir -p "$target"

        # Enumerate committed blobs via `git ls-tree -r -z $snap_sha`
        # and write each blob's bytes via `git show $snap_sha:<path>`.
        # Two reasons to materialize from git, not the worktree:
        #
        # 1. Worktree bytes can include uncommitted edits — secrets in
        #    progress, debug prints, work-in-progress comments — that
        #    a specialist could grep + quote into public review output.
        #    Reading committed bytes confines the boundary to source
        #    code that's already visible to all collaborators.
        #    PR #37 review 4 finding 1 (BCR — 2nd instance of local-
        #    bytes-escape class; review 2 fixed tracked symlinks, this
        #    fixes dirty worktree).
        #
        # 2. ls-tree gives us the mode field, so we can filter
        #    non-blobs structurally: 100644 / 100755 are regular files;
        #    120000 is a symlink (don't materialize, would have copied
        #    the target if cp-based); 160000 is a gitlink (submodule
        #    pointer, not source we should expose).
        #
        # Pin one commit SHA per slug and use it for BOTH enumeration
        # and content reads. Reading via the symbolic ref `HEAD` twice
        # opens a race: `plow-kid-refresh.sh` (or any concurrent
        # operator action) can advance the sibling checkout between
        # the ls-tree and the show, leaving specialists with an old
        # path set + new contents, or silently missing files added in
        # the new commit. Pinning the SHA up front makes the whole
        # materialization a single coherent snapshot. PR #37 review 5
        # finding 1 (BCR — 5th instance of silent-coverage-loss).
        if ! snap_sha=$(git -C "$src" rev-parse HEAD 2>/dev/null); then
            echo "materialize_sibling_symlinks: git rev-parse HEAD failed for $slug ($src)" >&2
            return 1
        fi

        # Capture to tempfile (NUL-safe + status-checkable).
        list_file=$(mktemp -t kw-sib-XXXXXX) || return 1
        if ! git -C "$src" ls-tree -r -z "$snap_sha" > "$list_file" 2>/dev/null; then
            rm -f "$list_file"
            echo "materialize_sibling_symlinks: git ls-tree -r $snap_sha failed for $slug ($src)" >&2
            return 1
        fi

        # Each ls-tree entry: <mode> <SP> <type> <SP> <sha> <TAB> <path>
        # Strip the header (everything before \t) to get the mode + path.
        # Single-owner gate: every committed regular blob writes
        # successfully or the helper returns non-zero.
        while IFS= read -r -d '' entry; do
            mode="${entry%% *}"
            rel="${entry#*$'\t'}"
            case "$mode" in
                100644|100755) ;;            # regular file
                *) continue ;;               # skip symlinks (120000), gitlinks (160000)
            esac
            # Validate the tree path before mkdir / redirect. Git tree
            # paths can technically be anything (`git update-index
            # --cacheinfo` allows arbitrary strings; fast-import lets a
            # tree have `..` components or absolute paths). Without
            # validation, `mkdir -p "$target/$(dirname ../escape.txt)"`
            # walks out of the slug dir, then `> "$target/../escape.txt"`
            # truncates a file outside before `git show` rejects the
            # blob read. PR #37 review 6 finding 1.
            case "$rel" in
                /*|..|../*|*/..|*/../*)
                    rm -f "$list_file"
                    echo "materialize_sibling_symlinks: rejected unsafe tree path '$rel' for $slug" >&2
                    return 1
                    ;;
            esac
            mkdir -p "$target/$(dirname "$rel")"
            if ! git -C "$src" show "$snap_sha:$rel" > "$target/$rel" 2>/dev/null; then
                rm -f "$list_file"
                echo "materialize_sibling_symlinks: git show $snap_sha:$rel failed for $slug" >&2
                return 1
            fi
        done < "$list_file"
        rm -f "$list_file"
    done
    return 0
}
