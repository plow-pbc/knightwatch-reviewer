#!/bin/bash
# Per-repo config seam. Reads .knightwatch/<file> from the repo's base
# branch via `git show`. Trust model: base branch only — PR head edits
# don't take effect until merged.
#
# Each per-repo concern (sibling allowlist, product context, dead-code
# command, strict-typing command) gets its own file under .knightwatch/
# with the natural format for that concern (line-oriented, markdown,
# bash). No central manifest, no parser dependency.
#
# Migration model: each lookup falls back to today's central config
# (repos.conf entries, ~/.pr-reviewer/contexts/<slug>.md) when the
# .knightwatch/<file> is absent — un-onboarded repos keep working
# unchanged. Once all tracked repos have committed .knightwatch/ to
# their base branches, the fallbacks can be removed in a follow-up.

# read_knightwatch_file <repo_dir> <default_branch> <relative_path>
#   stdout: file content from origin/<default_branch>:.knightwatch/<rel>
#   exit:   0 if the file exists and was read (even if content is empty);
#           1 if the file is absent or git-show fails (caller falls back).
read_knightwatch_file() {
    local repo_dir="$1" default_branch="$2" rel_path="$3"
    git -C "$repo_dir" show "origin/${default_branch}:.knightwatch/${rel_path}" 2>/dev/null
}
