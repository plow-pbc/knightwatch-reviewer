#!/usr/bin/env bash
# Path-scrub safety net. Runs over the assembled review comment body
# right before `gh pr comment`. Three substitutions, in order:
#   1. <workdir>/                  -> ""             (current-repo paths become repo-relative)
#   2. <SOURCE_PATHS[slug]>/       -> "<slug>/"      (sibling abs paths become slug-prefixed)
#   3. .siblings/                  -> ""             (workdir-internal sibling form -> slug form)
#
# Why: prompts tell specialists to cite repo-relative + slug-prefixed
# paths, and the workdir-relative `.siblings/<owner>/<repo>/...` layout
# (lib/sibling-symlinks.sh) makes the right thing easy. But models
# occasionally emit the old form (absolute path of cwd) or leak the
# symlink prefix. This pass is the seatbelt — defense-in-depth on top
# of the prompt updates.
#
# scrub_review_paths emits the rewritten body to stdout; the caller
# captures it. Order matters: workdir replacement first (it's the
# longest match in normal config). SOURCE_PATHS replacement is
# order-stable across runs because we sort the keys.

# scrub_review_paths <body> <workdir> <source_paths_var_name>
scrub_review_paths() {
    local body="$1" workdir="$2"
    local -n _src_paths="$3"
    local slug src

    # 1. Workdir abs prefix -> empty.
    body="${body//$workdir\//}"

    # 2. SOURCE_PATHS abs prefix -> slug. Sort for deterministic order
    #    (not strictly required since values shouldn't overlap, but
    #    cheap insurance against future config drift).
    for slug in $(printf '%s\n' "${!_src_paths[@]}" | LC_ALL=C sort); do
        src="${_src_paths[$slug]}"
        [ -z "$src" ] && continue
        body="${body//$src\//$slug/}"
    done

    # 3. .siblings/ prefix -> empty.
    body="${body//.siblings\//}"

    printf '%s' "$body"
}
