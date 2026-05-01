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
#           (may be empty when the file exists but has no content)
#   exit:   0 if the file exists on the base branch (PRESENT — even if empty)
#           1 if the file is absent on the base branch (ABSENT — caller falls back)
#
# The PRESENT-vs-ABSENT distinction is load-bearing: a committed empty
# file means "no value for this concern in this repo" (e.g., empty
# .knightwatch/dead-code.sh = "no dead-code static check for this repo,
# please" — NOT "fall back to the legacy DEAD_CODE_CMDS entry"). Callers
# must NOT collapse the two states with `[ -n "$result" ]` checks; the
# exit code is the source of truth.
#
# Existence is checked separately from content via `git cat-file -e` to
# avoid conflating "file absent" with other git-show failures (corrupt
# repo, missing ref, etc.). Those other failures abort the worker via
# `set -u` propagation rather than silently degrading — the operator
# needs to see them.
read_knightwatch_file() {
    local repo_dir="$1" default_branch="$2" rel_path="$3"
    local ref="origin/${default_branch}:.knightwatch/${rel_path}"
    git -C "$repo_dir" cat-file -e "$ref" 2>/dev/null || return 1
    git -C "$repo_dir" show "$ref" 2>/dev/null
}
