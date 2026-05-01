#!/bin/bash
# Diff-build helper for the reviewer worker.
#
# is_clean_incremental_available <repo_dir> <known_sha>
#   exit 0 if a local incremental diff (`git diff $known_sha..HEAD`)
#   would faithfully represent "what's new on the branch since
#   $known_sha":
#     (a) $known_sha is still an ancestor of HEAD — no force-push or
#         rebase has evicted it from the branch's current history
#     (b) no merge commits exist in $known_sha..HEAD — no merge-from-
#         main commits to pollute the incremental scope (the bot's
#         round 2 same-file leak finding)
#   exit 1 otherwise — caller falls back to the full PR diff with a
#   deterministic warning at the top of the review.
#
# This is the only helper from the deleted lib/diff-scope.sh that
# survived. The rest of that machinery — build_pr_diff,
# build_incremental_diff, compute_authored_files, has_traceable_history,
# DIFF_EXCLUDES tracking — was layers of trying to reinvent what
# `gh pr diff` (server-side three-dot) already does correctly. The
# worker now defaults to gh pr diff and only takes the local
# incremental optimization when this predicate confirms it's safe.
is_clean_incremental_available() {
    local repo_dir="$1" known_sha="$2"
    git -C "$repo_dir" merge-base --is-ancestor "$known_sha" HEAD 2>/dev/null \
        && [ -z "$(git -C "$repo_dir" log --merges --pretty=format:%H "$known_sha..HEAD" 2>/dev/null)" ]
}

# extract_touched_files_both_sides
#   Reads a unified-diff text on stdin; emits sorted-unique file paths
#   touched on EITHER side of every file change — additions, deletions,
#   and renames (including similarity-100% pure renames where +++/---
#   headers are absent). Source: `diff --git a/X b/Y` headers, which
#   always appear once per file change regardless of type. Strips the
#   leading `a/` or `b/` prefix.
#
#   Used by the worker's strict-typing scope gate: a PR that DELETES
#   `foo.py` or RENAMES `foo.ts` → `foo.js` touched typed code, but
#   the post-image-only `+++ b/` parse misses both cases (deletion's
#   post-image is `/dev/null`; pure rename has no `+++ b/` line at
#   all). Without both-sides extraction the gate would silently
#   suppress the strict-typing note on those PRs (the Narrow-Fix
#   flagged in PR #31 round-1 review).
#
#   Limitation: paths quoted by git (containing spaces or special
#   chars: `diff --git "a/foo bar.py" "b/foo bar.py"`) are split on
#   whitespace by awk and won't extract cleanly. Repos with such
#   paths fall through to the empty list and the gate skips — same
#   as if no typed files were touched. Acceptable: the strict-typing
#   nag false-negatives on space-in-path repos, which is rare and
#   recoverable (the operator can read repos.conf and infer the
#   gap).
extract_touched_files_both_sides() {
    awk '/^diff --git / { print $3; print $4 }' \
        | sed 's|^[ab]/||' \
        | LC_ALL=C sort -u
}

# classify_gh_pr_diff_failure STDOUT STDERR
#
# Pure function. Maps `gh pr diff`'s (stdout, stderr) into one of three
# outcome tokens — caller switches on the token to pick the right next
# step:
#
#   "ok"            — non-empty stdout; no fallback needed.
#   "cap-exceeded"  — empty stdout + stderr names GitHub's 300-file
#                     diff cap. Caller should retry locally with
#                     `git diff origin/<base>...HEAD` (same three-dot
#                     semantics as `gh pr diff`, no server-side cap).
#                     The cap is reachable on legitimate-but-large
#                     PRs (300-650 files); the prior "auth/network"
#                     abort message was wrong-cause AND lost
#                     reviewable PRs entirely.
#   "error"         — empty stdout + stderr names something else
#                     (auth, network, rate-limit, transient gh
#                     failure). Caller should abort loudly with the
#                     stderr text; no local fallback can recover.
#
# Pattern matched: GitHub returns HTTP 406 on the diff cap, with
# stderr wording that varies — observed forms include
# "exceeded max files (300)" and
# "exceeded the maximum number of files". Match on multiple
# alternatives so a wording wobble on either side doesn't regress
# this back to "auth/network". The HTTP 406 prefix alone is also
# sufficient: the diff endpoint uses 406 only for this cap, so the
# status code is a reliable backstop even if both phrasings change.
classify_gh_pr_diff_failure() {
    local stdout="$1" stderr="$2"
    if [ -n "$stdout" ]; then
        printf 'ok'
        return
    fi
    if printf '%s' "$stderr" | grep -qiE 'HTTP 406|exceeded max files|maximum number of files'; then
        printf 'cap-exceeded'
        return
    fi
    printf 'error'
}
