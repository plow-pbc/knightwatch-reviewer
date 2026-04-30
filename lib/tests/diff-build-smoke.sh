#!/bin/bash
# Smoke for lib/diff-build.sh::is_clean_incremental_available.
#
# Predicate: returns success (exit 0) iff
#   (a) prior reviewed SHA is still an ancestor of HEAD (no force-push
#       evicted it), AND
#   (b) no merge commits exist in known_sha..HEAD (no merge-from-main
#       between then and now to pollute attribution).
# Any other condition → exit 1, caller falls back to full PR diff
# with a deterministic warning at the top of the review.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPDIR=$(mktemp -d -t diff-build-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

. "$SCRIPT_DIR/diff-build.sh"

REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

echo a > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init

git -C "$REPO" remote add origin "$REPO/.git"
git -C "$REPO" fetch -q origin main

git -C "$REPO" checkout -qb feature
echo f > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -qm "B1"
PRIOR=$(git -C "$REPO" rev-parse HEAD)

# --- scenario 1: SHA is ancestor, no merges in range -----------------
echo "  scenario 1: clean incremental (ancestor + no merges)..."
echo f2 > "$REPO/feature2.txt"
git -C "$REPO" add feature2.txt
git -C "$REPO" commit -qm "B2"
if ! is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 1: should be clean (PRIOR is ancestor, no merges in range)"
    exit 1
fi

# --- scenario 2: SHA is ancestor, merge commit in range --------------
echo "  scenario 2: merge commit in range -> not clean..."
git -C "$REPO" checkout -q main
echo m > "$REPO/main-only.txt"
git -C "$REPO" add main-only.txt
git -C "$REPO" commit -qm "M1"
git -C "$REPO" fetch -q origin main
git -C "$REPO" checkout -q feature
git -C "$REPO" merge --no-ff -q -m "merge main" origin/main
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 2: merge commit in range should fail clean check"
    exit 1
fi

# --- scenario 3: rebased-away SHA (not ancestor of HEAD) -------------
# Capture HEAD and reset to a SHA before PRIOR; then PRIOR's branch
# point is no longer an ancestor of (the new) HEAD. Use checkout -B
# to a fresh-rooted history to simulate a force-push.
echo "  scenario 3: rebased-away SHA -> not clean..."
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qB feature main
echo orphaned > "$REPO/orphaned.txt"
git -C "$REPO" add orphaned.txt
git -C "$REPO" commit -qm "post-rebase HEAD"
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 3: orphaned SHA should fail clean check (PRIOR not ancestor of new HEAD)"
    exit 1
fi

# --- scenario 4: SHA doesn't exist at all ----------------------------
echo "  scenario 4: nonexistent SHA -> not clean..."
if is_clean_incremental_available "$REPO" "0000000000000000000000000000000000000000"; then
    echo "FAIL scenario 4: nonexistent SHA should fail clean check"
    exit 1
fi

echo "  PASS (4 scenarios: clean, merges-in-range, rebased-away, nonexistent)"
