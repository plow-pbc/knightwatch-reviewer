#!/usr/bin/env bash
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

# read_knightwatch_file <repo_dir> <base_ref> <relative_path>
#   stdout: file content from <base_ref>:.knightwatch/<rel>
#           (may be empty when the file exists but has no content)
#   exit:   0 — PRESENT: file exists at the base ref (content possibly empty)
#           1 — ABSENT:  file doesn't exist at the base ref (caller falls back to legacy)
#           2 — ERROR:   git invocation failed for a non-absence reason (caller aborts loud)
#
# Three states, not two. The PRESENT-vs-ABSENT distinction is load-bearing
# for the "empty file = explicit no value" semantics (an empty
# .knightwatch/dead-code.sh means "no dead-code static check for this
# repo," NOT "fall back to legacy DEAD_CODE_CMDS"). The
# ABSENT-vs-ERROR distinction is the Fail-Fast complement: callers
# fall back to legacy ONLY for true absence, not for transient git
# failures (broken base ref, corrupt object store, etc.) which would
# otherwise silently revive legacy policy with no signal to the operator.
#
# <base_ref> is the caller's responsibility — typically a SHA snapshotted
# BEFORE any PR-controlled code (e.g. `just test`) has had a chance to
# rewrite local refs. Passing a SHA (immutable) instead of a branch
# name (mutable via `git update-ref`) is the trust model: PR-head
# edits to local refs cannot redirect the read after the SHA is
# captured. The caller in review-one-pr.sh snapshots
# `git rev-parse origin/$DEFAULT_BRANCH` once, before tests run.
#
# Implementation: `git ls-tree <base_ref> -- <path>` gives a clean
# tri-state via stdout + exit-code, no stderr-message parsing:
#   exit 0 + non-empty stdout → path exists at base ref → PRESENT
#   exit 0 + empty stdout     → path doesn't exist at base ref → ABSENT
#   exit non-zero             → ref/tree problem → ERROR
# This handles every "file absent from base ref" case identically —
# including the onboarding scenario where `.knightwatch/<file>` exists
# on the PR branch only (the working tree). cat-file's stderr-message
# discriminator failed there because git emits a different message
# ("exists on disk, but not in 'REF'") rather than the canonical
# "does not exist in 'REF'", so the prior implementation classified
# onboarding PRs as ERROR and aborted reviews. ls-tree only inspects
# the ref's tree and never produces that confusion.
read_knightwatch_file() {
    local repo_dir="$1" base_ref="$2" rel_path="$3"
    local target=".knightwatch/${rel_path}"
    local listing
    if ! listing=$(git -C "$repo_dir" ls-tree "$base_ref" -- "$target" 2>/dev/null); then
        echo "knightwatch-config: ls-tree failed for $base_ref ($target)" >&2
        return 2
    fi
    [ -z "$listing" ] && return 1
    git -C "$repo_dir" show "${base_ref}:${target}" 2>/dev/null
}
