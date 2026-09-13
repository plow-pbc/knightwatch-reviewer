#!/usr/bin/env bash
# git_safe_root — the repository root at or above a path, for `-c safe.directory`.
#
# Why this exists: git's dubious-ownership check is against the REPOSITORY ROOT,
# not the path handed to `-C`. A whole-repo sibling is its own root, so scoping
# the exemption to the configured path worked. A SUBTREE sibling is not: with
# SOURCE_PATHS pointing at <repo>/gateway/platforms, `-c safe.directory=<that>`
# leaves the root unexempted and EVERY git call fails with "detected dubious
# ownership", which is why the reviewer (root, reading a uid-1000 mount)
# classified every upstream subtree `missing` while the same paths worked on the
# host as their owner.
#
# Walked in shell rather than `git rev-parse --show-toplevel` deliberately: every
# git call that could report the root is blocked by the very check we are trying
# to satisfy.
#
# Still scoped to one path — never global, never '*', which would also exempt
# PR clones (lib/search-roots.sh's standing rule).

git_safe_root() {
    local d="$1"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -e "$d/.git" ] && { printf '%s\n' "$d"; return 0; }
        # `${d%/*}` cannot shorten a path with no separator left, so a relative
        # SOURCE_PATHS entry ("somedir") would spin here forever — a hang the
        # worker only reaps at its outer timeout, burning the PR's whole budget.
        # Break on no progress rather than special-casing relative input: it
        # covers every non-shortening shape, and falls through to the loud
        # fallback below.
        [ "$d" = "${d%/*}" ] && break
        d="${d%/*}"
    done
    # No .git above it: not a checkout. Echo the input so the caller's own git
    # call fails loudly on a real repo error rather than on an empty -c value.
    printf '%s\n' "$1"
}
