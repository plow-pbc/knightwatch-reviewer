#!/bin/bash
# Smoke test for lib/diff-scope.sh. Verifies that compute_pr_authored_files
# returns ONLY files touched by the branch's non-merge commits, and
# specifically excludes files brought in by `git merge origin/<default>`
# (the bug that caused PR 552's reviewer to flag PR #547/#548 changes
# as if plonkus had authored them).

set -euo pipefail

TMPDIR=$(mktemp -d -t diff-scope-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../diff-scope.sh
. "$SCRIPT_DIR/diff-scope.sh"

REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

# Initial commit on main.
echo a > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "init"

# Production-style: an `origin` remote that aliases this same repo so
# `origin/main` is a real remote-tracking ref. We re-fetch after every
# main-side change below.
git -C "$REPO" remote add origin "$REPO/.git"
git -C "$REPO" fetch -q origin main

# Branch off main (mirrors the PR branch's starting state).
git -C "$REPO" checkout -qb feature
echo f > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -qm "add feature.txt"

# Meanwhile main moves: another team adds main-only.txt and edits a.txt.
# These are the analog of PR #547/#548 in the cncorp/plow story.
git -C "$REPO" checkout -q main
echo m > "$REPO/main-only.txt"
git -C "$REPO" add main-only.txt
git -C "$REPO" commit -qm "main: add main-only.txt"
echo a2 >> "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "main: edit a.txt"

# Re-fetch so origin/main reflects the new main commits before the merge.
git -C "$REPO" fetch -q origin main

# Feature merges main into itself (the move that exposes the bug).
git -C "$REPO" checkout -q feature
git -C "$REPO" merge --no-ff -q -m "Merge main into feature" origin/main

# Feature adds one more file after the merge.
echo f2 > "$REPO/feature2.txt"
git -C "$REPO" add feature2.txt
git -C "$REPO" commit -qm "add feature2.txt"

# Authored files (non-merge, branch-only) should be feature.txt + feature2.txt.
# main-only.txt and a.txt's mainline edit must NOT appear — those rode in
# via the merge and were not authored on the branch.
got=$(compute_pr_authored_files "$REPO" "main" | sort)
want=$(printf '%s\n' "feature.txt" "feature2.txt" | sort)

if [ "$got" != "$want" ]; then
    echo "FAIL: compute_pr_authored_files returned wrong list"
    echo "  got:"
    printf '%s\n' "$got" | sed 's/^/    /'
    echo "  want:"
    printf '%s\n' "$want" | sed 's/^/    /'
    exit 1
fi

# Empty-result fallback: when the branch has zero non-merge commits
# (degenerate case), the function should print nothing and exit non-zero
# so callers can detect and fall back.
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qb only-merges
if compute_pr_authored_files "$REPO" "main" 2>/dev/null | grep . > /dev/null; then
    echo "FAIL: expected empty output for branch-equals-main case"
    exit 1
fi
if compute_pr_authored_files "$REPO" "main" 2>/dev/null; then
    echo "FAIL: expected non-zero exit for branch-equals-main case"
    exit 1
fi

echo "  ok: compute_pr_authored_files filters merge-from-main content"
