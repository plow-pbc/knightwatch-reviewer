#!/bin/bash
# Smoke for lib/search-roots.sh — whitelist-only contract with
# per-repo .knightwatch/siblings as the primary source of truth.
#
# Two paths:
#   1. .knightwatch/siblings exists on base → its content is the allowlist
#   2. .knightwatch/siblings absent → fall back to "all REPOS minus self"
#
# In both cases each sibling is then classified as `included` (slug in
# SOURCE_PATHS AND its checkout exists on disk AND it's a git repo, so
# the materializer can pin a HEAD SHA and enumerate tracked content)
# or `missing` (any of those preconditions absent).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t search-roots-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Provide checkouts for two of three siblings; the third is intentionally absent.
# Sibling sources must be git repos so the included-classification holds —
# stage_search_roots checks `git rev-parse --git-dir` to keep the coverage
# marker in sync with what materialize_sibling_symlinks can actually expose.
init_sibling_dir() {
    local d="$1"
    mkdir -p "$d"
    git init -q "$d"
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    git -C "$d" config commit.gpgsign false
    echo "src" > "$d/file.py"
    git -C "$d" add file.py
    git -C "$d" commit -qm "seed"
}
init_sibling_dir "$TMPDIR/repos/foo"
init_sibling_dir "$TMPDIR/repos/bar"
# (sibling "qux" has no directory — drives the `missing` path.)

REPOS=("acme/self" "acme/foo" "acme/bar" "acme/qux")
declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/repos/self"
    ["acme/foo"]="$TMPDIR/repos/foo"
    ["acme/bar"]="$TMPDIR/repos/bar"
    ["acme/qux"]="$TMPDIR/repos/qux"
)

# Build a fake "self" repo workdir with a real main branch so
# read_knightwatch_file can git-show against origin/main.
make_self_repo() {
    local with_siblings="$1"  # "yes" or "no"
    local sibling_content="${2:-}"

    local source="$TMPDIR/source"
    rm -rf "$source"
    git init -q -b main "$source"
    git -C "$source" config user.email t@t
    git -C "$source" config user.name t
    git -C "$source" config commit.gpgsign false
    echo seed > "$source/seed.txt"
    git -C "$source" add seed.txt
    git -C "$source" commit -qm "seed"

    if [ "$with_siblings" = "yes" ]; then
        mkdir -p "$source/.knightwatch"
        printf '%s\n' "$sibling_content" > "$source/.knightwatch/siblings"
        git -C "$source" add .knightwatch
        git -C "$source" commit -qm "main: .knightwatch/siblings"
    fi

    local work="$TMPDIR/repos/self"
    rm -rf "$work"
    git clone -q "$source" "$work"
    git -C "$work" fetch -q origin main
    printf '%s' "$work"
}

. "$PROJECT_ROOT/lib/knightwatch-config.sh"
. "$PROJECT_ROOT/lib/search-roots.sh"

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $label"
        echo "  did not find: $needle"
        echo "  in: $(printf '%s' "$haystack" | head -c 400)"
        exit 1
    fi
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $label"
        echo "  unexpectedly found: $needle"
        exit 1
    fi
}

# --- scenario 1: .knightwatch/siblings present → uses that allowlist ---
echo "  scenario 1: .knightwatch/siblings as the allowlist..."
SELF_REPO=$(make_self_repo yes "acme/foo")
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 1: header full" "# coverage: full" "$OUT"
assert_contains "scenario 1: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
# bar is in REPOS + SOURCE_PATHS but NOT in .knightwatch/siblings → must NOT appear
assert_not_contains "scenario 1: bar excluded by allowlist" "acme/bar" "$OUT"

# --- scenario 2: .knightwatch/siblings absent → fall back to REPOS ---
echo "  scenario 2: fallback to REPOS when .knightwatch absent..."
SELF_REPO=$(make_self_repo no)
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 2: header full" "# coverage: full" "$OUT"
assert_contains "scenario 2: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 2: bar included" "acme/bar included .siblings/acme/bar" "$OUT"

# --- scenario 3: missing on-disk checkout ---
echo "  scenario 3: missing on-disk checkout..."
SELF_REPO=$(make_self_repo yes "acme/foo
acme/qux")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
assert_contains "scenario 3: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 3: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 3: qux missing" "acme/qux missing" "$OUT"

# --- scenario 4: empty .knightwatch/siblings → no siblings ---
echo "  scenario 4: empty .knightwatch/siblings → no siblings..."
SELF_REPO=$(make_self_repo yes "")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
assert_contains "scenario 4: header same-repo-only" "same-repo-only" "$OUT"

# --- scenario 5: comments + blank lines in .knightwatch/siblings ---
echo "  scenario 5: comments and blank lines ignored..."
SELF_REPO=$(make_self_repo yes "# this is the sibling we use
acme/foo

# acme/bar — disabled while migrating
")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
assert_contains "scenario 5: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_not_contains "scenario 5: bar not included" "acme/bar" "$OUT"

# --- scenario 6: declared sibling without SOURCE_PATHS entry ----------
# Bot Finding 1 PR #29: a declared sibling that the operator hasn't
# wired into SOURCE_PATHS used to be silently dropped (continue), so
# the user couldn't tell the worker had ignored their declaration.
# Now classifies as `missing` so it surfaces in coverage.
echo "  scenario 6: declared sibling without SOURCE_PATHS entry → missing..."
SELF_REPO=$(make_self_repo yes "acme/foo
acme/never-configured")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
assert_contains "scenario 6: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 6: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 6: never-configured missing" "acme/never-configured missing" "$OUT"

# --- scenario 7: knightwatch-config ERROR propagates as non-zero rc ---
# When read_knightwatch_file returns ERROR (rc 2 — bad base ref), the
# caller must NOT silently fall back to legacy REPOS-minus-self —
# that would silently revive policy with no operator signal. Instead
# stage_search_roots returns non-zero so its caller can abort loud.
echo "  scenario 7: ERROR from knightwatch-config propagates → non-zero rc..."
SELF_REPO=$(make_self_repo no)  # workdir exists, but we'll pass a bad branch name
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo")
if stage_search_roots "acme/self" "$SELF_REPO" "nonexistent-branch" >/dev/null 2>&1; then
    echo "FAIL: stage_search_roots should return non-zero on knightwatch-config ERROR"
    exit 1
fi
REPOS=("${saved_repos[@]}")

# --- scenario 8: source dir exists but isn't a git repo → missing -----
# Single-owner search-roots contract: stage_search_roots can't classify
# a source as `included` if materialize_sibling_symlinks couldn't pin a
# HEAD SHA on it. `git rev-parse HEAD` fails on a non-git source, so the
# materializer would abort — but the prior contract said "full" coverage
# anyway, so specialists searched empty content
# while the bot reported the sibling as covered. cncorp/plow#37 review 1
# finding 1 (Bug-Class-Recurrence). Stage it as `missing` instead.
echo "  scenario 8: non-git source dir → missing (search-roots/materialize agreement)..."
mkdir -p "$TMPDIR/repos/notgit"
echo "would-leak" > "$TMPDIR/repos/notgit/file.py"
SOURCE_PATHS["acme/notgit"]="$TMPDIR/repos/notgit"
SELF_REPO=$(make_self_repo yes "acme/foo
acme/notgit")
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/notgit")
OUT=$(stage_search_roots "acme/self" "$SELF_REPO" "origin/main")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 8: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 8: foo included"    "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 8: notgit missing"  "acme/notgit missing" "$OUT"
# Critically — must NOT mark notgit as included. That's the bug.
if printf '%s' "$OUT" | grep -q "acme/notgit included"; then
    echo "FAIL: scenario 8 — non-git source classified as included; coverage will misreport"
    exit 1
fi

echo "  PASS (8 scenarios: knightwatch-allowlist, fallback, missing-on-disk, empty-allowlist, comments, declared-but-unconfigured, error-propagation, non-git-source-missing)"
