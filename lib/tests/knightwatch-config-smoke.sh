#!/usr/bin/env bash
# Smoke for lib/knightwatch-config.sh::read_knightwatch_file.
#
# Three invariants:
#   1. File exists on the base branch → returns content + exit 0
#   2. File absent → returns empty + exit 1
#   3. File exists ONLY on a non-base branch (PR head) → still classified
#      as ABSENT against the base ref. Trust model: base branch is the
#      source of truth; PR head edits don't take effect until merged.

set -euo pipefail

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
exit_code=0
read_knightwatch_file "$WORK" "origin/main" "siblings" > "$TMPDIR/out.txt" 2>/dev/null || exit_code=$?
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

# --- scenario 2: missing file → empty + EXACTLY exit 1 (ABSENT) ----
# Expect rc=1 (ABSENT), not just "non-zero." Callers act on rc=1 vs
# rc=2 differently, so a test that accepts any non-zero would let an
# ERROR-as-ABSENT regression slip through (bot finding 1 PR #29 round 2).
echo "  scenario 2: missing file → empty + exit 1 (ABSENT)..."
exit_code=0
read_knightwatch_file "$WORK" "origin/main" "does-not-exist.sh" > "$TMPDIR/out.txt" 2>/dev/null || exit_code=$?
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected exit 1 (ABSENT) for missing file, got $exit_code"
    exit 1
fi
got=$(cat "$TMPDIR/out.txt")
if [ -n "$got" ]; then
    echo "FAIL: expected empty output for missing file, got: $got"
    exit 1
fi

# --- scenario 3: read product-context.md → markdown content --------
echo "  scenario 3: product-context.md → markdown content..."
got=$(read_knightwatch_file "$WORK" "origin/main" "product-context.md")
if ! printf '%s' "$got" | grep -q '^# Product context$'; then
    echo "FAIL: expected markdown header"
    echo "  got: $got"
    exit 1
fi

# --- scenario 3b: review-priority.md round-trips with same trust model.
# Parallel to scenario 3 (product-context). Adds a review-priority.md
# on main, asserts PRESENT (rc 0 + content match) when reading against
# main's SHA, and asserts ABSENT (rc 1) when the file exists ONLY on a
# feature branch — same base-branch-source-of-truth invariant.
echo "  scenario 3b: review-priority.md round-trip + base-branch trust..."
git -C "$SOURCE" checkout -q main
printf '# Review priority\n\nreview-priority test content\n' > "$SOURCE/.knightwatch/review-priority.md"
git -C "$SOURCE" add .knightwatch/review-priority.md
git -C "$SOURCE" commit -qm "main: add review-priority.md"
git -C "$WORK" fetch -q origin main
git -C "$WORK" checkout -q -B main origin/main
MAIN_SHA=$(git -C "$WORK" rev-parse origin/main)
exit_code=0
got=$(read_knightwatch_file "$WORK" "$MAIN_SHA" "review-priority.md") || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: review-priority.md from main expected exit 0, got $exit_code"
    exit 1
fi
if ! printf '%s' "$got" | grep -q '^# Review priority$'; then
    echo "FAIL: expected review-priority markdown header"
    echo "  got: $got"
    exit 1
fi
if ! printf '%s' "$got" | grep -q 'review-priority test content'; then
    echo "FAIL: review-priority.md content mismatch"
    echo "  got: $got"
    exit 1
fi

# Feature-branch-only addition must NOT take effect when reading
# against the base SHA (locks down the same invariant the bot enforces:
# PR-head edits to .knightwatch/<file> don't take effect until merged).
git -C "$SOURCE" checkout -q feature
printf '# Review priority\n\nfeature-branch-only override\n' > "$SOURCE/.knightwatch/review-priority-feat.md"
git -C "$SOURCE" add .knightwatch/review-priority-feat.md
git -C "$SOURCE" commit -qm "feature: add review-priority-feat.md (PR-only)"
git -C "$WORK" fetch -q origin feature
exit_code=0
read_knightwatch_file "$WORK" "$MAIN_SHA" "review-priority-feat.md" > "$TMPDIR/out.txt" 2>/dev/null || exit_code=$?
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: review-priority-feat.md (feature-only) expected rc 1 (ABSENT) against main SHA, got $exit_code"
    exit 1
fi

# --- scenario 4: PRESENT but empty → exit 0 + empty content ---------
# Helper-mechanism scenario: a committed empty file at a tracked path
# returns rc=0 with empty stdout — distinct from rc=1 (ABSENT) and
# rc=2 (ERROR). What PRESENT-empty MEANS is a per-caller decision
# documented at each call site (e.g. search-roots.sh treats it as
# "no siblings"; review-one-pr.sh's product-context block substitutes
# the placeholder); this scenario only fences the helper's
# mechanism, not caller policy.
echo "  scenario 4: present but empty → exit 0 + empty content..."
git -C "$SOURCE" checkout -q main
echo > "$SOURCE/.knightwatch/empty-file.sh"
git -C "$SOURCE" add .knightwatch/empty-file.sh
git -C "$SOURCE" commit -qm "main: add empty .knightwatch/empty-file.sh"
git -C "$WORK" fetch -q origin main
git -C "$WORK" checkout -q -B main origin/main
exit_code=0
got=$(read_knightwatch_file "$WORK" "origin/main" "empty-file.sh") || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    echo "FAIL: expected exit 0 for present-but-empty file, got $exit_code"
    exit 1
fi
if [ -n "$got" ]; then
    echo "FAIL: expected empty stdout for present-but-empty file, got: $got"
    exit 1
fi

# --- scenario 5: bad base ref → exit 2 (ERROR, NOT ABSENT) ---------
# A non-existent default branch (e.g., the operator forgot to fetch
# origin/main, or the workdir is corrupt) must NOT collapse onto the
# ABSENT exit code — that would silently route callers down their
# absence path with no operator signal. The helper distinguishes via
# `git ls-tree` returning non-zero on a bad ref.
echo "  scenario 5: bad base ref → exit 2 (ERROR)..."
exit_code=0
read_knightwatch_file "$WORK" "nonexistent-branch" "siblings" > "$TMPDIR/out.txt" 2>/dev/null || exit_code=$?
if [ "$exit_code" -ne 2 ]; then
    echo "FAIL: expected exit 2 (ERROR) for bad base ref, got $exit_code"
    exit 1
fi

# --- scenario 6: SHA-pin resists mid-run ref rewriting --------------
# The actual attack the trust model has to defend against: a PR's
# `just test` recipe rewrites refs/remotes/origin/<default-branch>
# to point at the PR head, then subsequent reads pick up PR-authored
# .knightwatch/* policy as if it were base-branch policy. SHA-pinning
# defeats this — the snapshotted SHA points at the original commit
# regardless of how the local ref is later rewritten.
echo "  scenario 6: SHA-pin resists mid-run ref rewriting..."
git -C "$WORK" fetch -q origin main
git -C "$WORK" checkout -q -B main origin/main
BASE_SHA=$(git -C "$WORK" rev-parse "origin/main")
# Simulate the attack: rewrite origin/main to point at the feature
# branch (which has `evil/private-repo` in .knightwatch/siblings).
git -C "$WORK" update-ref refs/remotes/origin/main "$(git -C "$WORK" rev-parse origin/feature)"
# Helper called with the SHA still gets base-branch content
got_pinned=$(read_knightwatch_file "$WORK" "$BASE_SHA" "siblings")
if printf '%s' "$got_pinned" | grep -q 'evil/private-repo'; then
    echo "FAIL: SHA-pin failed — read PR-head policy after ref rewrite"
    exit 1
fi
if ! printf '%s' "$got_pinned" | grep -q '^cncorp/plow-content$'; then
    echo "FAIL: SHA-pin should have returned base-branch content"
    echo "  got: $got_pinned"
    exit 1
fi
# Sanity-check the attack actually works against the unsafe ref form
got_ref=$(read_knightwatch_file "$WORK" "origin/main" "siblings")
if ! printf '%s' "$got_ref" | grep -q 'evil/private-repo'; then
    echo "FAIL: ref-rewrite simulation didn't actually take effect — test is meaningless"
    echo "  got: $got_ref"
    exit 1
fi

# --- scenario 7: onboarding case — file exists ONLY on PR branch ---
# A first-time `.knightwatch/*` PR has the file on the PR branch but
# NOT on the base branch yet. The helper must classify this as ABSENT
# (rc 1) rather than ERROR (rc 2). The prior stderr-parse
# implementation got this wrong because git's "exists on disk, but
# not in" message for a working-tree path missing from the ref doesn't
# match the canonical "does not exist in" pattern. ls-tree avoids the
# ambiguity entirely.
echo "  scenario 7: onboarding — file on PR branch only → ABSENT..."
git -C "$SOURCE" checkout -q feature
echo "pr-only" > "$SOURCE/.knightwatch/pr-only-file.sh"
git -C "$SOURCE" add .knightwatch/pr-only-file.sh
git -C "$SOURCE" commit -qm "feature: add pr-only-file"
git -C "$WORK" fetch -q origin feature
git -C "$WORK" checkout -q -B feature origin/feature
# .knightwatch/pr-only-file.sh exists in workdir + on origin/feature,
# but NOT on origin/main. Helper called against origin/main must
# return ABSENT (rc 1), not ERROR (rc 2).
exit_code=0
read_knightwatch_file "$WORK" "origin/main" "pr-only-file.sh" > "$TMPDIR/out.txt" 2>/dev/null || exit_code=$?
if [ "$exit_code" -ne 1 ]; then
    echo "FAIL: expected rc 1 (ABSENT) for onboarding case, got $exit_code"
    exit 1
fi

echo "  PASS (8 scenarios: existing, missing-ABSENT, base-branch-only trust, review-priority round-trip + ABSENT, present-but-empty, bad-ref-ERROR, SHA-pin-bypass-resistance, onboarding-ABSENT)"
