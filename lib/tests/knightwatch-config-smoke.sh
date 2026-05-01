#!/bin/bash
# Smoke for lib/knightwatch-config.sh::read_knightwatch_file.
#
# Three invariants:
#   1. File exists on the base branch → returns content + exit 0
#   2. File absent → returns empty + exit 1 (caller falls back)
#   3. File exists ONLY on a non-base branch (PR head) → still falls
#      back. Trust model: base branch is the source of truth; PR head
#      edits don't take effect until merged.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPDIR=$(mktemp -d -t knightwatch-config-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

. "$SCRIPT_DIR/knightwatch-config.sh"

# Build a fake bare-clone-style repo with a "main" branch and a
# "feature" branch where only feature has the .knightwatch/ files.
SOURCE="$TMPDIR/source"
git init -q -b main "$SOURCE"
git -C "$SOURCE" config user.email t@t
git -C "$SOURCE" config user.name t
git -C "$SOURCE" config commit.gpgsign false

echo seed > "$SOURCE/seed.txt"
git -C "$SOURCE" add seed.txt
git -C "$SOURCE" commit -qm "seed"

# Add .knightwatch/ files on main
mkdir -p "$SOURCE/.knightwatch"
echo "cncorp/plow-content" > "$SOURCE/.knightwatch/siblings"
printf '# Product context\n\nThe thing does the thing.\n' > "$SOURCE/.knightwatch/product-context.md"
git -C "$SOURCE" add .knightwatch
git -C "$SOURCE" commit -qm "main: add .knightwatch/"

# Branch off, add a SECRET sibling on the feature branch only — to
# verify the helper does NOT pick it up (base-branch-only trust)
git -C "$SOURCE" checkout -qb feature
echo "evil/private-repo" >> "$SOURCE/.knightwatch/siblings"
git -C "$SOURCE" commit -qam "feature: add evil sibling"
git -C "$SOURCE" checkout -q main

# Workdir is a clone where origin/main reflects the source's main.
WORK="$TMPDIR/work"
git clone -q "$SOURCE" "$WORK"
git -C "$WORK" fetch -q origin main
git -C "$WORK" fetch -q origin feature

# Check out the feature branch (simulates a PR head with the SECRET
# addition). The helper must read from origin/main, not HEAD.
git -C "$WORK" checkout -q -B feature origin/feature

# --- scenario 1: file exists on main → returns content -------------
echo "  scenario 1: existing file → content + exit 0..."
read_knightwatch_file "$WORK" "main" "siblings" > "$TMPDIR/out.txt" 2>/dev/null
exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: expected exit 0, got $exit_code"
    exit 1
fi
got=$(cat "$TMPDIR/out.txt")
if ! printf '%s' "$got" | grep -q '^cncorp/plow-content$'; then
    echo "FAIL: expected to find cncorp/plow-content"
    echo "  got: $got"
    exit 1
fi
# Crucial: the SECRET sibling from PR head must NOT appear
if printf '%s' "$got" | grep -q 'evil/private-repo'; then
    echo "FAIL: trust violation — read PR-head content, should be base-branch only"
    exit 1
fi

# --- scenario 2: missing file → empty + exit 1 ---------------------
echo "  scenario 2: missing file → empty + exit 1..."
read_knightwatch_file "$WORK" "main" "does-not-exist.sh" > "$TMPDIR/out.txt" 2>/dev/null
exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "FAIL: expected exit non-zero for missing file, got 0"
    exit 1
fi
got=$(cat "$TMPDIR/out.txt")
if [ -n "$got" ]; then
    echo "FAIL: expected empty output for missing file, got: $got"
    exit 1
fi

# --- scenario 3: read product-context.md → markdown content --------
echo "  scenario 3: product-context.md → markdown content..."
got=$(read_knightwatch_file "$WORK" "main" "product-context.md")
if ! printf '%s' "$got" | grep -q '^# Product context$'; then
    echo "FAIL: expected markdown header"
    echo "  got: $got"
    exit 1
fi

echo "  PASS (3 scenarios: existing, missing, base-branch-only trust)"
