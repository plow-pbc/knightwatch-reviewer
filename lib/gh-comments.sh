#!/usr/bin/env bash
# Sourceable helper for fetching all issue-level comments on a PR.
#
# fetch_issue_comments REPO PR_NUM
#
# On success: prints one JSON array on stdout containing every issue-
# level comment on the PR (paginated transparently) and exits 0.
# On `gh` failure (auth lapse, network outage, rate limit): exits
# non-zero and prints nothing. The non-zero exit is independent of
# the caller's pipefail setting — checked inline via command
# substitution, not the pipe — so every caller can wrap the call
# with `|| { log; continue; }` and get fail-loud behavior without
# needing `set -o pipefail` themselves.
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
# helper and gets correct pagination — and a uniform failure contract —
# by construction.
fetch_issue_comments() {
    local repo="$1" pr_num="$2" raw
    raw=$(gh api --paginate "repos/${repo}/issues/${pr_num}/comments" 2>/dev/null) || return 1
    printf '%s' "$raw" | jq -s 'add // []'
}
