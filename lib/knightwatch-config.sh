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
#   exit:   0 — PRESENT: file exists on the base branch (content possibly empty)
#           1 — ABSENT:  file doesn't exist on the base branch (caller falls back to legacy)
#           2 — ERROR:   git invocation failed for a non-absence reason (caller aborts loud)
#
# Three states, not two. The PRESENT-vs-ABSENT distinction is load-bearing
# for the "empty file = explicit no value" semantics (an empty
# .knightwatch/dead-code.sh means "no dead-code static check for this
# repo," NOT "fall back to legacy DEAD_CODE_CMDS"). The
# ABSENT-vs-ERROR distinction is the Fail-Fast complement: callers
# fall back to legacy ONLY for true absence, not for transient git
# failures (broken origin/<default-branch> ref, corrupt object store,
# missing remote, etc.) which would otherwise silently revive legacy
# policy with no signal to the operator.
#
# Implementation: rev-parse --verify the base ref first (exit 1 if
# missing → ERROR rc 2). If the ref is fine, cat-file -e the path
# (exit non-zero → ABSENT rc 1). Only on both checks succeeding do we
# read content via git show.
read_knightwatch_file() {
    local repo_dir="$1" default_branch="$2" rel_path="$3"
    local base_ref="origin/${default_branch}"
    local full_ref="${base_ref}:.knightwatch/${rel_path}"
    if ! git -C "$repo_dir" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
        echo "knightwatch-config: base ref $base_ref not found in $repo_dir" >&2
        return 2
    fi
    git -C "$repo_dir" cat-file -e "$full_ref" 2>/dev/null || return 1
    git -C "$repo_dir" show "$full_ref" 2>/dev/null
}
