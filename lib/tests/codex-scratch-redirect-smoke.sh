#!/usr/bin/env bash
# Smoke for the .codex-scratch redirect-safe staging in lib/review-one-pr.sh.
#
# Mirrors lib/tests/sibling-symlinks-smoke.sh's scenario 3 in shape: a PR
# checkout could commit `.codex-scratch` as a symlink pointing at a writable
# service path (e.g. ~/.pr-reviewer/runs/...) so that subsequent writes via
# write_scratch + the per-specialist symlinks would redirect critic /
# momentum / dead-code outputs into our own state dir. The fence in
# review-one-pr.sh:
#
#     rm -rf "$REPO_DIR/.codex-scratch"
#     mkdir -p "$REPO_DIR/.codex-scratch"
#
# unconditionally wipes whatever's there before any write — replacing a
# pre-existing symlink with a real directory the worker owns. A regression
# that drops the `rm -rf` (or replaces it with `mkdir -p` alone, which is a
# no-op on an existing symlink-to-dir) silently re-opens the redirect.
#
# Three sub-scenarios cover the attack shapes:
#   3a. `.codex-scratch` itself is a symlink to an attacker-writable dir.
#   3b. `.codex-scratch` is a regular dir but contains a pre-existing
#       leaf symlink (e.g. `.codex-scratch/diff.patch` -> attacker dir/file).
#   3c. `.codex-scratch` is a symlink to a non-existent target (dangling)
#       — `mkdir -p` would NOT recreate it as a dir; a `mkdir`-only fix
#       would error with EEXIST and leave the symlink in place.
#
# We exercise the actual code path lib/review-one-pr.sh runs (the two-line
# wipe + recreate) by extracting it via grep so a regression has to defeat
# both the smoke AND the production code in one place. Behavioral asserts
# (sentinel untouched, .codex-scratch is a real dir, write_scratch's writes
# land under REPO_DIR) make a silent removal of the rm fail loud.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

TMPDIR=$(mktemp -d -t codex-scratch-redirect-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Static fence: the wipe-then-recreate sequence must remain in
# review-one-pr.sh. A future refactor that drops the `rm -rf` (and keeps
# only `mkdir -p`) would be a no-op against an existing symlink, silently
# re-opening the redirect. Catch the structural regression at the suite
# gate before any scenario runs.
WORKER="$PROJECT_ROOT/lib/review-one-pr.sh"
rm_present=$(grep -cE '^[[:space:]]*rm -rf "\$REPO_DIR/\.codex-scratch"[[:space:]]*$' "$WORKER" || echo 0)
assert_eq "$rm_present" "1" "setup: lib/review-one-pr.sh is missing 'rm -rf \"\$REPO_DIR/.codex-scratch\"' — the redirect-defeating wipe is gone, mkdir -p alone is a no-op on a symlink-to-dir"
mkdir_present=$(grep -cE '^[[:space:]]*mkdir -p "\$REPO_DIR/\.codex-scratch"[[:space:]]*$' "$WORKER" || echo 0)
assert_eq "$mkdir_present" "1" "setup: lib/review-one-pr.sh is missing 'mkdir -p \"\$REPO_DIR/.codex-scratch\"' after the wipe"
# Adjacency: the mkdir must immediately follow the rm (no intervening
# code that would race with the wipe or write to .codex-scratch first).
RM_LINE=$(grep -nE '^[[:space:]]*rm -rf "\$REPO_DIR/\.codex-scratch"[[:space:]]*$' "$WORKER" | head -1 | cut -d: -f1)
MKDIR_LINE=$(grep -nE '^[[:space:]]*mkdir -p "\$REPO_DIR/\.codex-scratch"[[:space:]]*$' "$WORKER" | head -1 | cut -d: -f1)
adjacency=$((MKDIR_LINE - RM_LINE))
assert_eq "$adjacency" "1" "setup: rm -rf and mkdir -p for .codex-scratch must be adjacent in lib/review-one-pr.sh (rm@$RM_LINE, mkdir@$MKDIR_LINE)"

# Function under test: the exact two-line sequence the worker runs at the
# redirect-fence point. Sourcing review-one-pr.sh end-to-end would pull in
# a production-shaped pipeline (gh, codex, git fetch); this localizes the
# fence to the two lines that defeat the attack so the smoke stays a unit
# test.
codex_scratch_stage() {
    local REPO_DIR="$1"
    rm -rf "$REPO_DIR/.codex-scratch"
    mkdir -p "$REPO_DIR/.codex-scratch"
}

REPO_DIR="$TMPDIR/repo"
ATTACK_TARGET="$TMPDIR/SHOULD_NOT_BE_TOUCHED"

assert_redirect_defeated() {
    local label="$1"
    codex_scratch_stage "$REPO_DIR"

    if [ -L "$REPO_DIR/.codex-scratch" ]; then
        echo "FAIL ($label): .codex-scratch is still a symlink — wipe didn't happen, mkdir -p alone is a no-op"
        ls -la "$REPO_DIR/"
        exit 1
    fi
    if [ ! -d "$REPO_DIR/.codex-scratch" ]; then
        echo "FAIL ($label): .codex-scratch is not a real directory after stage"
        ls -la "$REPO_DIR/"
        exit 1
    fi

    # Behavioral: write into .codex-scratch, then verify the bytes
    # landed under REPO_DIR (not under the attacker's target).
    printf 'review payload\n' > "$REPO_DIR/.codex-scratch/diff.patch"
    patch_missing=$([ ! -f "$REPO_DIR/.codex-scratch/diff.patch" ] && echo "missing" || echo "")
    assert_empty "$patch_missing" "($label): write into .codex-scratch did not land at the expected path"
    if [ -e "$ATTACK_TARGET/diff.patch" ] || [ -L "$ATTACK_TARGET/diff.patch" ]; then
        echo "FAIL ($label): attacker target gained a 'diff.patch' entry — write escaped REPO_DIR"
        ls -la "$ATTACK_TARGET/"
        exit 1
    fi
    sentinel_missing=$([ ! -e "$ATTACK_TARGET/sentinel" ] && echo "missing" || echo "")
    assert_empty "$sentinel_missing" "($label): attacker target sentinel was modified — write escaped REPO_DIR"
}

# --- scenario 1: .codex-scratch is itself a symlink to attacker dir ---
echo "  scenario 1: .codex-scratch is a symlink to attacker-writable dir..."
rm -rf "$REPO_DIR" "$ATTACK_TARGET"
mkdir -p "$REPO_DIR" "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"
ln -sfn "$ATTACK_TARGET" "$REPO_DIR/.codex-scratch"
[ -L "$REPO_DIR/.codex-scratch" ] || { echo "  pre-check: .codex-scratch should be a symlink"; exit 1; }
assert_redirect_defeated "1 (symlink-to-attacker-dir)"

# --- scenario 2: .codex-scratch is a real dir but with a pre-existing
# leaf symlink redirecting an inner artifact path. The wipe takes the
# whole dir + its contents (so the leaf symlink dies with it).
echo "  scenario 2: .codex-scratch contains a pre-existing leaf symlink to attacker dir..."
rm -rf "$REPO_DIR" "$ATTACK_TARGET"
mkdir -p "$REPO_DIR/.codex-scratch" "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"
# Leaf: .codex-scratch/diff.patch redirects to a file inside attacker dir.
touch "$ATTACK_TARGET/diff.patch.intercept"
ln -sfn "$ATTACK_TARGET/diff.patch.intercept" "$REPO_DIR/.codex-scratch/diff.patch"
[ -L "$REPO_DIR/.codex-scratch/diff.patch" ] || { echo "  pre-check: leaf should be a symlink"; exit 1; }
assert_redirect_defeated "2 (leaf-symlink-redirect)"
# Intercept file in attacker dir must remain unmodified (the wipe took
# the LEAF symlink, not its target — exactly what we want).
intercept_missing=$([ ! -f "$ATTACK_TARGET/diff.patch.intercept" ] && echo "missing" || echo "")
assert_empty "$intercept_missing" "scenario 2: wipe followed the leaf symlink and deleted the attacker target file — rm without -L isn't symlink-traversing, this should not happen"

# --- scenario 3: .codex-scratch is a dangling symlink. mkdir -p alone
# would error (EEXIST on the symlink) and leave the symlink in place; the
# rm -rf removes the symlink so mkdir -p can create the real dir.
echo "  scenario 3: .codex-scratch is a dangling symlink (mkdir -p alone would EEXIST)..."
rm -rf "$REPO_DIR" "$ATTACK_TARGET"
mkdir -p "$REPO_DIR" "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"
ln -sfn "$TMPDIR/does-not-exist" "$REPO_DIR/.codex-scratch"
[ -L "$REPO_DIR/.codex-scratch" ] || { echo "  pre-check: .codex-scratch should be a symlink"; exit 1; }
[ ! -e "$REPO_DIR/.codex-scratch" ] || { echo "  pre-check: dangling symlink should not resolve"; exit 1; }
assert_redirect_defeated "3 (dangling-symlink)"

# --- scenario 4: idempotent re-run on a real .codex-scratch dir already
# in place (the production hot-path: a previous tick or the same worker's
# earlier phase already created the dir). The wipe must NOT touch
# REPO_DIR's other contents — only .codex-scratch itself.
echo "  scenario 4: pre-existing real .codex-scratch + sibling files in REPO_DIR — only .codex-scratch wiped..."
rm -rf "$REPO_DIR" "$ATTACK_TARGET"
mkdir -p "$REPO_DIR/.codex-scratch" "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"
echo "kept" > "$REPO_DIR/README.md"
echo "stale" > "$REPO_DIR/.codex-scratch/leftover.txt"
codex_scratch_stage "$REPO_DIR"
if [ ! -f "$REPO_DIR/README.md" ] || [ "$(cat "$REPO_DIR/README.md")" != "kept" ]; then
    echo "FAIL scenario 4: REPO_DIR/README.md was disturbed — wipe over-reached beyond .codex-scratch"
    ls -la "$REPO_DIR/"
    exit 1
fi
leftover=$([ -e "$REPO_DIR/.codex-scratch/leftover.txt" ] && echo "exists" || echo "")
assert_empty "$leftover" "scenario 4: stale .codex-scratch/leftover.txt survived — wipe didn't take prior contents"
not_fresh_dir=$({ [ ! -d "$REPO_DIR/.codex-scratch" ] || [ -L "$REPO_DIR/.codex-scratch" ]; } && echo "not-fresh" || echo "")
assert_empty "$not_fresh_dir" "scenario 4: .codex-scratch is not a fresh real dir after stage"

echo "  ok: .codex-scratch staging is redirect-safe (symlink-to-dir, leaf-symlink, dangling, and idempotent on real-dir all defeated)"
