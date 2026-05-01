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
# Implementation: rev-parse --verify the base ref first (exit 1 if
# missing → ERROR rc 2). If the ref is fine, cat-file -e the path
# (exit non-zero → distinguish ABSENT from ERROR via stderr message).
read_knightwatch_file() {
    local repo_dir="$1" base_ref="$2" rel_path="$3"
    local full_ref="${base_ref}:.knightwatch/${rel_path}"
    if ! git -C "$repo_dir" rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1; then
        echo "knightwatch-config: base ref $base_ref not found in $repo_dir" >&2
        return 2
    fi
    # Distinguish "path missing on a healthy base ref" (ABSENT, rc 1)
    # from any other cat-file failure (ERROR, rc 2). cat-file -e exits
    # 128 in both cases, so the discriminator is stderr — git's
    # canonical "path 'X' does not exist in 'REF'" message marks the
    # legitimate-absent case; anything else is a real failure (corrupt
    # object store, malformed path, etc.) and must NOT silently revive
    # legacy fallback policy.
    local cat_err
    cat_err=$(git -C "$repo_dir" cat-file -e "$full_ref" 2>&1)
    case $? in
        0) git -C "$repo_dir" show "$full_ref" 2>/dev/null ;;
        *)
            if printf '%s' "$cat_err" | grep -q "does not exist in"; then
                return 1
            fi
            echo "knightwatch-config: cat-file failed for $full_ref: $cat_err" >&2
            return 2
            ;;
    esac
}
