#!/usr/bin/env bash
# Shared engagement primitives — given a PR and a probe, answer
# "did the author engage with this probe via code changes?"
# Used today by the bake-off's Applied column. Designed for future
# adoption by the critic's K-decay logic (prompts/critic.md), which
# currently asks the LLM to infer the same signal per review run.
#
# pr_touched_paths REPO PR_NUM
#   Prints one path per line — every file the PR has touched (any commit,
#   base..head). Caller does set-membership lookup against probe-cited paths
#   (see lib/bakeoff-parsers.sh:probe_cited_paths) to determine "applied".
#   Pagination is transparent. Failure exits non-zero with no output —
#   caller decides whether to skip or fail-loud.
pr_touched_paths() {
    local repo="$1" pr="$2"
    gh api --paginate "repos/$repo/pulls/$pr/files" --jq '.[].filename'
}
