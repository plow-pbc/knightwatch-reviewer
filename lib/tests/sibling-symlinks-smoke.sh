#!/bin/bash
# Smoke for lib/sibling-symlinks.sh. Four invariants:
#
#   1. Only materialize siblings the caller explicitly classified as
#      `included` — whitelist-gated upstream by stage_search_roots,
#      not by this helper's own iteration over SOURCE_PATHS. (Otherwise
#      we'd copy content from siblings whose checkouts are absent —
#      empty .siblings/<slug>/ trees, confused specialists.)
#
#   2. Defeat committed-symlink path-redirect attacks. The PR's
#      checkout might already contain `.siblings/` (e.g. an attacker
#      committed `.siblings/cncorp/plow-content` as a symlink to
#      ~/.ssh/). Wipe whatever's there before materializing.
#
#   3. Missing siblings (no SOURCE_PATHS dir on disk) are skipped
#      silently — the search-roots seam already classifies those.
#
#   4. ONLY tracked files appear in the materialized tree. Untracked /
#      gitignored content (`.git/`, `.venv/`, `node_modules/`, etc.)
#      stays out so a specialist grep cannot pull bytes from it and
#      quote them in public review output. Caught on cncorp/plow#567
#      review rounds 1-4 (the bot kept re-flagging the raw-checkout
#      symlink shape until the worker layer was fixed).

set -euo pipefail

TMPDIR=$(mktemp -d -t sibling-symlinks-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../sibling-symlinks.sh
. "$SCRIPT_DIR/sibling-symlinks.sh"

WORKDIR="$TMPDIR/work"
mkdir -p "$WORKDIR/.git"  # mimic a real workdir

# Build sibling sources as REAL git repos so `git ls-files` enumerates
# tracked content. Each gets a tracked file (`main.py`, `pkg/util.py`)
# and a gitignored secret in the kind of subdirs that commonly hold
# local artifacts (`.venv/`, `node_modules/`, `__pycache__/`).
# Scenario 6 below asserts none of the gitignored secrets leak through.
init_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git init -q "$dir"
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    git -C "$dir" config commit.gpgsign false
}
init_sibling_repo() {
    local dir="$1"
    init_git_repo "$dir"
    echo "src" > "$dir/main.py"
    mkdir -p "$dir/pkg"
    echo "pkg-src" > "$dir/pkg/util.py"
    cat > "$dir/.gitignore" <<'EOF'
.venv/
node_modules/
__pycache__/
EOF
    # Tracked hidden file fixture: covers the user's intentional case
    # of committing `.knightwatch/` and `.keepitdry/` (per cncorp/plow#37
    # review 1 finding 2). Tracked dotdir content MUST appear in the
    # materialized tree — only gitignored content is filtered out.
    mkdir -p "$dir/.knightwatch"
    echo "tracked-hidden" > "$dir/.knightwatch/product-context.md"
    git -C "$dir" add main.py pkg/util.py .gitignore .knightwatch/product-context.md
    git -C "$dir" commit -qm "seed"
    # Plant local-only artifacts AFTER commit. None should appear in
    # the materialized tree.
    mkdir -p "$dir/.venv" "$dir/node_modules" "$dir/pkg/__pycache__"
    echo "VENV_SECRET" > "$dir/.venv/secret"
    echo "NODE_LEAK"   > "$dir/node_modules/leaked.json"
    echo "CACHE_BYTES" > "$dir/pkg/__pycache__/util.cpython-312.pyc"
}
init_sibling_repo "$TMPDIR/foo"
init_sibling_repo "$TMPDIR/bar"
init_sibling_repo "$TMPDIR/baz"
# acme/qux is intentionally missing on disk.

declare -A SOURCE_PATHS=(
    ["acme/foo"]="$TMPDIR/foo"
    ["acme/bar"]="$TMPDIR/bar"
    ["acme/baz"]="$TMPDIR/baz"   # deliberately NOT included
    ["acme/qux"]="$TMPDIR/qux"   # deliberately missing on disk
)

# Returns 0 iff the materialized file at <slug>/<rel> is a REGULAR FILE
# (not a symlink) with the same content as the tracked source file.
# Regular files matter: `grep -r` skips symlinks during recursive
# traversal, so a symlinked materialization would silently zero out
# every consumer/dead-code grep across siblings while reporting "full"
# coverage. cncorp/plow#37 review 1 finding 1 (BCR).
assert_tracked_file_copy() {
    local label="$1" slug="$2" rel="$3" expected_source="$4"
    local f="$WORKDIR/.siblings/$slug/$rel"
    if [ ! -f "$f" ]; then
        echo "FAIL ($label): expected $f to exist"
        ls -la "$WORKDIR/.siblings/$slug/" 2>/dev/null || true
        exit 1
    fi
    if [ -L "$f" ]; then
        echo "FAIL ($label): $f is a symlink — must be a real file so 'grep -r' finds it"
        exit 1
    fi
    if ! cmp -s "$f" "$expected_source"; then
        echo "FAIL ($label): $f content differs from $expected_source"
        exit 1
    fi
}

# --- scenario 1: only `included` siblings get materialized ------------
echo "  scenario 1: whitelist-gated to included slugs..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"

assert_tracked_file_copy "scenario 1: foo/main.py" "acme/foo" "main.py"     "$TMPDIR/foo/main.py"
assert_tracked_file_copy "scenario 1: foo/pkg"     "acme/foo" "pkg/util.py" "$TMPDIR/foo/pkg/util.py"
assert_tracked_file_copy "scenario 1: bar/main.py" "acme/bar" "main.py"     "$TMPDIR/bar/main.py"
# baz is in SOURCE_PATHS but was NOT in the included list — must NOT exist.
if [ -e "$WORKDIR/.siblings/acme/baz" ]; then
    echo "FAIL: baz symlink should not exist (not in included list)"
    exit 1
fi

# --- scenario 2: missing checkout → fail-loud (no silent skip) --------
# The materializer used to silently `continue` past missing-dir slugs.
# Now it fails loud — by the time we get here, stage_search_roots has
# already filtered missing slugs to `missing` upstream, so a missing
# dir means a race between classification and materialization.
echo "  scenario 2: missing on-disk checkout → non-zero rc..."
rc=0
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/qux" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: missing on-disk checkout should have returned non-zero"
    exit 1
fi

# --- scenario 3: defeat committed-symlink path-redirect attack --------
# Three sub-scenarios — all stage `.siblings/<owner>` AS THE SYMLINK
# directly (no intervening mkdir), which is the actual committed-symlink
# attack shape. The previous version of this test did `mkdir -p
# .siblings/acme` first, then `ln -sfn TARGET .siblings/acme`, which (per
# `ln`'s behavior on an existing directory) creates the symlink INSIDE
# .siblings/acme rather than as it — so the attack vector was never
# really exercised. Bot finding 2 PR #28 review 2 caught this.
ATTACK_TARGET="$TMPDIR/SHOULD_NOT_BE_TOUCHED"
mkdir -p "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"

assert_redirect_defeated() {
    local label="$1"
    materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo"
    if [ -L "$WORKDIR/.siblings/acme" ]; then
        echo "FAIL ($label): .siblings/acme is still a symlink — wipe didn't happen"
        ls -la "$WORKDIR/.siblings/"
        exit 1
    fi
    assert_tracked_file_copy "$label: post-attack foo/main.py" \
        "acme/foo" "main.py" "$TMPDIR/foo/main.py"
    if [ ! -e "$ATTACK_TARGET/sentinel" ]; then
        echo "FAIL ($label): attacker target sentinel was modified — write escaped workdir"
        exit 1
    fi
    if [ -e "$ATTACK_TARGET/foo" ] || [ -L "$ATTACK_TARGET/foo" ]; then
        echo "FAIL ($label): attacker target gained a 'foo' entry — write escaped workdir"
        ls -la "$ATTACK_TARGET/"
        exit 1
    fi
}

echo "  scenario 3a: .siblings/<owner> is a symlink to attacker dir..."
rm -rf "$WORKDIR/.siblings"
mkdir "$WORKDIR/.siblings"
# acme is itself a symlink, NOT a directory containing one.
ln -sfn "$ATTACK_TARGET" "$WORKDIR/.siblings/acme"
[ -L "$WORKDIR/.siblings/acme" ] || { echo "  pre-check: acme should be a symlink"; exit 1; }
assert_redirect_defeated "3a (intermediate symlink)"

echo "  scenario 3b: .siblings itself is a symlink to attacker dir..."
rm -rf "$WORKDIR/.siblings"
ln -sfn "$ATTACK_TARGET" "$WORKDIR/.siblings"
[ -L "$WORKDIR/.siblings" ] || { echo "  pre-check: .siblings should be a symlink"; exit 1; }
assert_redirect_defeated "3b (root symlink)"

echo "  scenario 3c: .siblings/<owner>/<repo> is the symlink (leaf)..."
rm -rf "$WORKDIR/.siblings"
mkdir -p "$WORKDIR/.siblings/acme"
# Leaf is a pre-existing symlink to attacker target — gets overwritten
# when materialize wipes .siblings/.
ln -sfn "$ATTACK_TARGET" "$WORKDIR/.siblings/acme/foo"
[ -L "$WORKDIR/.siblings/acme/foo" ] || { echo "  pre-check: foo should be a symlink"; exit 1; }
assert_redirect_defeated "3c (leaf symlink)"

# --- scenario 4: re-runs are idempotent --------------------------------
echo "  scenario 4: idempotent re-run..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"
assert_tracked_file_copy "scenario 4: post-rerun foo/main.py" \
    "acme/foo" "main.py" "$TMPDIR/foo/main.py"

# --- scenario 5: empty included list = empty .siblings/ ---------------
echo "  scenario 5: empty included list produces empty .siblings/..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS
if [ -d "$WORKDIR/.siblings" ] && [ -n "$(ls -A "$WORKDIR/.siblings" 2>/dev/null)" ]; then
    echo "FAIL: .siblings/ should be empty when nothing included"
    ls -la "$WORKDIR/.siblings"
    exit 1
fi

# --- scenario 6: tracked-only — gitignored / .git / untracked excluded -
# Load-bearing: the prior raw-checkout `ln -sfn "$src" "$target"` shape
# exposed the entire sibling tree (.git/, .venv/, node_modules/, etc.)
# to specialist greps. cncorp/plow#567 review rounds 1-4 kept flagging
# this. The fix is to materialize ONLY tracked files via `git ls-files`
# so the worker mirrors the sibling's source contract, not whatever
# happens to be on disk.
echo "  scenario 6: only tracked files — .git / gitignored / untracked excluded..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"

# Tracked content present — including tracked HIDDEN content like
# `.knightwatch/` (the user's per-repo bot config). The "tracked-only"
# rule must not bleed into a "no dotfiles" rule; only gitignored content
# gets filtered. cncorp/plow#37 review 1 finding 2 (low).
assert_tracked_file_copy "scenario 6: tracked main.py"     "acme/foo" "main.py"     "$TMPDIR/foo/main.py"
assert_tracked_file_copy "scenario 6: tracked pkg/util.py" "acme/foo" "pkg/util.py" "$TMPDIR/foo/pkg/util.py"
assert_tracked_file_copy "scenario 6: tracked .knightwatch/" "acme/foo" ".knightwatch/product-context.md" "$TMPDIR/foo/.knightwatch/product-context.md"

# Gitignored / untracked content absent. Each path was planted in
# `init_sibling_repo` AFTER the commit, with `.venv/`, `node_modules/`,
# `__pycache__/` matching the .gitignore. None should be reachable via
# the materialized tree.
for forbidden in \
    .git \
    .git/HEAD \
    .git/config \
    .venv \
    .venv/secret \
    node_modules \
    node_modules/leaked.json \
    pkg/__pycache__ \
    pkg/__pycache__/util.cpython-312.pyc; do
    if [ -e "$WORKDIR/.siblings/acme/foo/$forbidden" ] || [ -L "$WORKDIR/.siblings/acme/foo/$forbidden" ]; then
        echo "FAIL: $forbidden leaked into materialized tree"
        ls -laR "$WORKDIR/.siblings/acme/foo/" | head -40
        exit 1
    fi
done

# Bonus: a `grep -rn` over the materialized slug must not surface the
# secret strings. This is the actual public-output exposure vector.
if grep -rn "VENV_SECRET\|NODE_LEAK\|CACHE_BYTES" "$WORKDIR/.siblings/acme/foo/" 2>/dev/null; then
    echo "FAIL: specialist-style grep surfaced gitignored secrets"
    exit 1
fi

# Load-bearing: `grep -rn` MUST find tracked content. Earlier this PR
# materialized as per-file symlinks, which `grep -r` skips during
# recursive traversal — silently zero-ing every consumer/dead-code grep
# while reporting "full" coverage. The fix uses real files (cp); this
# assertion is the regression fence so the next "let's go back to
# symlinks for the disk savings" change can't quietly break the search
# contract again. cncorp/plow#37 review 1 finding 1 (BCR).
if ! grep -rn "pkg-src" "$WORKDIR/.siblings/acme/foo/" >/dev/null; then
    echo "FAIL: 'grep -rn' did not find tracked content — materialized files must be real, not symlinks"
    ls -la "$WORKDIR/.siblings/acme/foo/pkg/util.py"
    exit 1
fi

# --- scenario 7: non-git source returns non-zero (fail-fast) ----------
# stage_search_roots filters non-git sources to `missing` upstream, so
# the materializer should never see one for an `included` slug. But if
# it does (defense in depth, future caller bug), the helper must
# return non-zero rather than silently produce an empty slug while
# the review pipeline reports `included` coverage. cncorp/plow#37
# review 3 finding 1 (BCR — the third instance of silent-coverage-
# loss class).
echo "  scenario 7: non-git source → non-zero rc (fail-fast, defense in depth)..."
mkdir -p "$TMPDIR/not-a-repo"
echo "would-leak" > "$TMPDIR/not-a-repo/leak.txt"
SOURCE_PATHS["acme/notgit"]="$TMPDIR/not-a-repo"
rc=0
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/notgit" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: non-git source should have returned non-zero (got rc=0)"
    exit 1
fi
# Whatever state the slug ended up in, the raw-root content must NOT
# be reachable through it.
if [ -e "$WORKDIR/.siblings/acme/notgit/leak.txt" ]; then
    echo "FAIL: non-git source leaked raw-root content into materialized tree"
    exit 1
fi

# --- scenario 8: tracked symlink in source = excluded (no deref leak) -
# Load-bearing: `cp` follows symlinks by default, so a sibling tracking
# `leak -> ~/.ssh/id_rsa` (or any path outside the source tree) would
# copy the *target bytes* into .siblings/<slug>/leak where specialists
# could quote them as if they were tracked source. Tracked symlinks
# must be skipped at the materialize step. cncorp/plow#37 review 2
# finding 1 (blocking).
echo "  scenario 8: tracked symlink excluded (no deref leak)..."
SECRET_FILE="$TMPDIR/EXTERNAL_SECRET"
echo "EXTERNAL_BYTES" > "$SECRET_FILE"
init_git_repo "$TMPDIR/symrepo"
echo "real" > "$TMPDIR/symrepo/real.py"
ln -s "$SECRET_FILE" "$TMPDIR/symrepo/leak"
git -C "$TMPDIR/symrepo" add real.py leak
git -C "$TMPDIR/symrepo" commit -qm "seed with a tracked symlink to external file"
SOURCE_PATHS["acme/sym"]="$TMPDIR/symrepo"
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/sym"
# Tracked regular file survives.
assert_tracked_file_copy "scenario 8: tracked real.py" "acme/sym" "real.py" "$TMPDIR/symrepo/real.py"
# Tracked symlink and its dereferenced target must NOT appear.
if [ -e "$WORKDIR/.siblings/acme/sym/leak" ] || [ -L "$WORKDIR/.siblings/acme/sym/leak" ]; then
    echo "FAIL: tracked symlink 'leak' was materialized — would dereference to external bytes"
    ls -la "$WORKDIR/.siblings/acme/sym/"
    exit 1
fi
if grep -rn "EXTERNAL_BYTES" "$WORKDIR/.siblings/acme/sym/" >/dev/null 2>&1; then
    echo "FAIL: external symlink target bytes leaked into materialized tree"
    exit 1
fi

# --- scenario 9: cp failure (worktree race) returns non-zero ----------
# Single-owner gate: if any tracked file fails to copy (worktree race
# deleted it between `git ls-files` and `cp`, permission, disk full),
# materialize_sibling_symlinks returns non-zero so the caller can abort
# the review instead of serving partial sibling content while reporting
# `included` coverage. cncorp/plow#37 review 3 finding 1 (BCR — third
# instance of silent-coverage-loss class).
echo "  scenario 9: corrupt git object → non-zero rc..."
# Real-world analog: object DB corruption between classification and
# materialize. With ls-tree+cat-file (HEAD reads), a deleted-from-
# worktree file is no longer relevant — `git show HEAD:<path>` reads
# from the object DB, not from disk. So the failure shape we need to
# test is git itself failing to read its own object: corrupt the loose
# object for our tracked blob. The helper must return non-zero rather
# than serve a partially-materialized slug while reporting `included`.
init_git_repo "$TMPDIR/corruptrepo"
echo "real" > "$TMPDIR/corruptrepo/keeper.py"
echo "doomed" > "$TMPDIR/corruptrepo/doomed.py"
git -C "$TMPDIR/corruptrepo" add keeper.py doomed.py
git -C "$TMPDIR/corruptrepo" commit -qm "seed"
# Find the blob SHA for doomed.py and clobber the loose object so
# `git show HEAD:doomed.py` fails. Works for a fresh repo where the
# blob is loose (not yet packed). Loose objects are written 0444, so
# chmod first.
DOOMED_SHA=$(git -C "$TMPDIR/corruptrepo" ls-tree HEAD doomed.py | awk '{print $3}')
DOOMED_PATH="$TMPDIR/corruptrepo/.git/objects/${DOOMED_SHA:0:2}/${DOOMED_SHA:2}"
chmod u+w "$DOOMED_PATH"
echo "garbage" > "$DOOMED_PATH"
SOURCE_PATHS["acme/corrupt"]="$TMPDIR/corruptrepo"
rc=0
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/corrupt" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: materialize_sibling_symlinks should have returned non-zero on git show failure"
    exit 1
fi

# --- scenario 10: uncommitted worktree edits don't leak --------------
# Bot review 4 finding 1 (BCR — 2nd instance of local-bytes-escape):
# previously the helper read worktree bytes, so a sibling with an
# uncommitted edit to a tracked file would surface the dirty version
# (potentially containing secrets in progress, debug prints,
# work-in-progress comments) to specialists. The fix reads committed
# blobs from HEAD via `git show`, which is invariant to worktree state.
echo "  scenario 10: uncommitted worktree edits don't leak..."
init_git_repo "$TMPDIR/dirtyrepo"
echo "committed-source" > "$TMPDIR/dirtyrepo/file.py"
git -C "$TMPDIR/dirtyrepo" add file.py
git -C "$TMPDIR/dirtyrepo" commit -qm "seed"
# Edit the worktree AFTER commit. The materialize must NOT pick this up.
echo "DIRTY_SECRET" > "$TMPDIR/dirtyrepo/file.py"
SOURCE_PATHS["acme/dirty"]="$TMPDIR/dirtyrepo"
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/dirty"
got=$(cat "$WORKDIR/.siblings/acme/dirty/file.py" 2>/dev/null)
if [ "$got" != "committed-source" ]; then
    echo "FAIL: expected committed content 'committed-source', got '$got'"
    exit 1
fi
if grep -rn "DIRTY_SECRET" "$WORKDIR/.siblings/acme/dirty/" >/dev/null 2>&1; then
    echo "FAIL: uncommitted worktree bytes leaked into materialized tree"
    exit 1
fi

# --- scenario 11: missing src → fail-loud (no silent skip) -----------
# The materializer used to `continue` past empty-src or non-dir-src
# slugs, leaving an empty .siblings/<slug>/ while the caller still
# reported `included` coverage. Bot review 4 finding 2 (BCR — 4th
# instance of silent-coverage-loss). Now it returns non-zero so the
# review aborts.
echo "  scenario 11: empty src in SOURCE_PATHS → fail-loud..."
SOURCE_PATHS["acme/emptyentry"]=""
rc=0
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/emptyentry" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: empty src should have returned non-zero"
    exit 1
fi
echo "  scenario 11: src dir vanished after classification → fail-loud..."
SOURCE_PATHS["acme/vanished"]="$TMPDIR/vanished-no-such-dir"
rc=0
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/vanished" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: missing src dir should have returned non-zero"
    exit 1
fi

echo "  ok: sibling materialization whitelist-gated, redirect-safe, idempotent, committed-blobs-only, symlink-safe, fail-fast"
