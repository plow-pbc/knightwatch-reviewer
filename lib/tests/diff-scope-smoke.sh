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

# Feature ALSO edits a.txt — the same file main just edited. This is the
# same-file case bot finding 1 (PR #28 review 2) caught: a filename-based
# filter passes a.txt through and `git diff origin/main...HEAD -- a.txt`
# still leaks main's hunk along with the branch's. Fix has to scope by
# commit, not by filename.
echo "branch-edit-of-a" >> "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm "feature: edit a.txt (branch-authored, same file as main)"

# Feature adds one more file after the merge.
echo f2 > "$REPO/feature2.txt"
git -C "$REPO" add feature2.txt
git -C "$REPO" commit -qm "add feature2.txt"

# Authored files (non-merge, branch-only) should be feature.txt,
# feature2.txt, AND a.txt (because the branch authored an edit to a.txt
# even though main also touched it). main-only.txt must NOT appear.
want=$(printf '%s\n' "feature.txt" "feature2.txt" "a.txt" | sort)

# Compatibility wrapper still works (full-PR case).
got=$(compute_pr_authored_files "$REPO" "main" | sort)
if [ "$got" != "$want" ]; then
    echo "FAIL: compute_pr_authored_files returned wrong list"
    echo "  got:"
    printf '%s\n' "$got" | sed 's/^/    /'
    echo "  want:"
    printf '%s\n' "$want" | sed 's/^/    /'
    exit 1
fi

# Generalized helper, single exclude (full-PR analog).
got_general=$(compute_authored_files "$REPO" "HEAD" "origin/main" | sort)
if [ "$got_general" != "$want" ]; then
    echo "FAIL: compute_authored_files single-exclude returned wrong list"
    exit 1
fi

# Incremental scenario: prior reviewed SHA = first feature commit. The
# later branch state has the merge of main + feature2.txt. Authored-since-
# prior, EXCLUDING merged-in main content, should be ONLY feature2.txt.
# Bot's finding 1 was that the incremental path didn't have this exclusion
# and bogus findings reappeared from the merged-in commits — verify it
# now does, with both prior-SHA AND origin/main as exclude refs.
PRIOR_SHA=$(git -C "$REPO" rev-parse "feature^{/add feature.txt}")
# After PRIOR_SHA, the branch authored: a.txt edit + feature2.txt.
# main-only.txt should still be excluded (rode in via the merge).
got_incr=$(compute_authored_files "$REPO" "HEAD" "$PRIOR_SHA" "origin/main" | sort)
want_incr=$(printf '%s\n' "a.txt" "feature2.txt" | sort)
if [ "$got_incr" != "$want_incr" ]; then
    echo "FAIL: compute_authored_files(prior + origin/main excludes) wrong"
    echo "  got:"
    printf '%s\n' "$got_incr" | sed 's/^/    /'
    echo "  want: $want_incr"
    exit 1
fi

# Full-PR diff: contains branch's edits (feature.txt, branch-edit-of-a,
# feature2.txt) but NOT main's content (main-only.txt, a2). The full-PR
# scope passes because three-dot `origin/main...HEAD` naturally advances
# merge-base past merged-in main commits — the harder case is incremental
# (below).
diff_out=$(build_authored_diff "$REPO" "HEAD" "origin/main")
if ! printf '%s' "$diff_out" | grep -q '^diff --git a/feature.txt'; then
    echo "FAIL: build_authored_diff missing feature.txt hunk"
    exit 1
fi
if printf '%s' "$diff_out" | grep -q '^diff --git a/main-only.txt'; then
    echo "FAIL: build_authored_diff leaked main-only.txt (merged-in content)"
    exit 1
fi
if ! printf '%s' "$diff_out" | grep -q 'branch-edit-of-a'; then
    echo "FAIL: build_authored_diff missing branch's a.txt edit"
    exit 1
fi
if printf '%s' "$diff_out" | grep -E '^\+a2$' >/dev/null; then
    echo "FAIL: build_authored_diff leaked main's same-file edit (a2 hunk in a.txt)"
    printf '%s' "$diff_out" | sed 's/^/  /' | head -40
    exit 1
fi

# INCREMENTAL same-file case — bot finding 1 PR #28 review 2. The prior
# implementation's three-dot diff with `prior_sha...HEAD` doesn't advance
# merge-base past merged-in main commits (prior_sha is on the branch),
# so any main-side hunk on a file the branch ALSO edited would leak
# through alongside the branch's own edits. The per-commit walk is
# structurally immune.
diff_incr=$(build_authored_diff "$REPO" "HEAD" "$PRIOR_SHA" "origin/main")
if ! printf '%s' "$diff_incr" | grep -q 'branch-edit-of-a'; then
    echo "FAIL: incremental build_authored_diff missing branch's a.txt edit"
    exit 1
fi
if printf '%s' "$diff_incr" | grep -E '^\+a2$' >/dev/null; then
    echo "FAIL: incremental build_authored_diff leaked main's same-file edit (a2)"
    printf '%s' "$diff_incr" | sed 's/^/  /' | head -40
    exit 1
fi
if printf '%s' "$diff_incr" | grep -q 'main-only'; then
    echo "FAIL: incremental build_authored_diff leaked main-only.txt"
    exit 1
fi

# has_traceable_history: succeeds when refs share an ancestor in local
# history (callers use this to distinguish "branch genuinely empty" from
# "shallow clone can't compute"). Should pass for refs in our test repo.
if ! has_traceable_history "$REPO" "origin/main" "HEAD"; then
    echo "FAIL: has_traceable_history false-negatived on real shared ancestor"
    exit 1
fi

# Empty-result fallback: when the branch has zero non-merge commits
# (degenerate case), the helpers should print nothing and exit non-zero
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
if build_authored_diff "$REPO" "HEAD" "origin/main" 2>/dev/null; then
    echo "FAIL: build_authored_diff should exit non-zero for branch-equals-main"
    exit 1
fi

echo "  ok: diff-scope helpers filter merge-from-main content (full + incremental)"
