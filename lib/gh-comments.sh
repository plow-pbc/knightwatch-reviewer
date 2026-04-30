#!/bin/bash
# Sourceable helper for fetching all issue-level comments on a PR.
#
# fetch_issue_comments REPO PR_NUM
#
# Returns one JSON array on stdout containing every issue-level comment
# on the PR (paginated transparently). Empty array on fetch failure.
#
# Why this exists: `gh api repos/<repo>/issues/<pr>/comments` returns
# only page 1 (default 30 items) without `--paginate`. Three orchestrator-
# level scripts consume this endpoint to scan for /srosro-* slash-command
# triggers (review.sh, approve-from-replies.sh, learn-from-replies.sh) —
# any divergence between them silently drops triggers on long PR threads.
# In the original PR that surfaced this (cncorp/plow-content#1, ~30+ top-
# level comments), review.sh missed a /srosro-update-review trigger that
# was on page 2 and the orchestrator never dispatched a re-review for
# 30+ minutes — the same bug class approve-/learn-from-replies had
# already independently fixed in their own copies. Now there's one
# shared seam: any future caller of this endpoint goes through this
# helper and gets correct pagination by construction.
#
# Hermetic — pure pipeline of `gh api --paginate | jq -s 'add // []'`.
# Caller's pipefail (if set) propagates a non-zero exit when either
# `gh` or `jq` fails; the smoke covers both branches.
fetch_issue_comments() {
    local repo="$1" pr_num="$2"
    gh api --paginate "repos/${repo}/issues/${pr_num}/comments" 2>/dev/null | jq -s 'add // []'
}
