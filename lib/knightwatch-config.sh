#!/usr/bin/env bash
# Per-repo config seam. Reads .knightwatch/<file> from the repo's base
# branch via `git show`. Trust model: base branch only — PR head edits
# don't take effect until merged.
#
# Each per-repo concern (sibling allowlist, product context, review
# priority, dead-code command, strict-typing command) gets its own
# file under .knightwatch/ with the natural format for that concern
# (line-oriented, markdown, bash). No central manifest, no parser
# dependency.
#
# The helper reports presence/content/failure; callers decide policy.
# Each call site documents its own PRESENT-empty and ABSENT semantics.
# The one universal rule: every caller MUST treat (2) ERROR as a hard
# abort so transient git failures (broken base ref, corrupt object
# store, etc.) cannot be misread as absence.

# read_knightwatch_file <repo_dir> <base_ref> <relative_path>
#   stdout: file content from <base_ref>:.knightwatch/<rel>
#           (may be empty when the file exists but has no content)
#   exit:   0 — PRESENT: file exists at the base ref (content possibly empty)
#           1 — ABSENT:  file doesn't exist at the base ref
#           2 — ERROR:   git invocation failed for a non-absence reason
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

# Org-default product-context, injected when a repo commits no
# .knightwatch/product-context.md. Most repos here are pre-PMF with a
# handful of users; absent a per-repo override, reviewers assume that and
# optimize for iteration speed rather than silently reviewing for scale
# (the recurring over-engineering failure). Shared by production staging
# (lib/review-one-pr.sh) and operator-bench replay (lib/replay.sh) so the
# two paths can't drift — a renamed/reworded default reaches both at once.
# A repo genuinely at scale overrides this by committing its own file.
default_product_context() {
    cat <<'PRODUCT_CONTEXT_EOF'
# Product context (org default — no per-repo file configured)

No `.knightwatch/product-context.md` is committed for this repo, so assume the org default operating point:

- **Stage:** pre-PMF, early. Shipping and iteration speed matter more than hardening for scale.
- **Userbase:** fewer than 10 users, often a single operator. Abstractions, flags, parallel modes, and defensive edge-case handling sized for thousands of users are over-engineering at this stage, not robustness.
- **Spec rigidity:** treat specs and inferred intent as sketches, not contracts. A handled edge case the intent never asked for is a cost, not a feature.
- **Optimize for developer time:** elegant, DRY code that is easy to build on; every maintained code path taxes iteration speed.

If this repo is genuinely at scale or has a different operating point, commit `.knightwatch/product-context.md` to the base branch to override this default.
PRODUCT_CONTEXT_EOF
}

# Resolve the product-context input for a review: the per-repo
# .knightwatch/product-context.md at base_ref if committed and non-empty,
# else the org default. This is the SINGLE read+classify+default seam — both
# production (lib/review-one-pr.sh) and operator-bench replay (lib/replay.sh)
# call it, so the present/absent/error contract can't drift between them (it
# did, twice, when each open-coded its own tri-state). Echoes the resolved
# content and returns 0 on PRESENT or ABSENT (default substituted); returns 2
# WITHOUT output on a git/ref ERROR so each caller keeps its own abort cleanup
# (production logs + rm -rf the checkout; replay just exits). Mirrors
# read_knightwatch_file's rc contract (0 present, 1 absent, 2 error).
resolve_product_context() {
    local repo_dir="$1" base_ref="$2" content rc
    content=$(read_knightwatch_file "$repo_dir" "$base_ref" "product-context.md") && rc=0 || rc=$?
    [ "$rc" = 2 ] && return 2
    [ -n "$content" ] && printf '%s' "$content" || default_product_context
}
