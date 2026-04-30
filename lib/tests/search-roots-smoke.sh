#!/bin/bash
# Smoke for lib/search-roots.sh — whitelist-only contract.
#
# Whitelist = SOURCE_PATHS in repos.conf. If a sibling slug has an
# entry there, the operator has affirmed it's safe to reference in
# this base repo's PR comments. No runtime auth check, no per-sibling
# permission lookup. Two statuses:
#   included .siblings/<slug>   — slug in SOURCE_PATHS AND its
#                                  checkout exists on disk
#   missing                     — slug in SOURCE_PATHS BUT its
#                                  checkout absent on disk

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t search-roots-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Provide checkouts for two of three siblings; the third is intentionally absent.
mkdir -p "$TMPDIR/repos/foo" "$TMPDIR/repos/bar"
# (sibling "qux" has no directory — drives the `missing` path.)

REPOS=("acme/self" "acme/foo" "acme/bar" "acme/qux")
declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/repos/self"
    ["acme/foo"]="$TMPDIR/repos/foo"
    ["acme/bar"]="$TMPDIR/repos/bar"
    ["acme/qux"]="$TMPDIR/repos/qux"
)

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

# --- scenario 1: all whitelisted siblings have checkouts on disk -----
echo "  scenario 1: all whitelisted siblings present..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
OUT=$(stage_search_roots "acme/self")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 1: header full" "# coverage: full" "$OUT"
assert_contains "scenario 1: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 1: bar included" "acme/bar included .siblings/acme/bar" "$OUT"

# --- scenario 2: one whitelisted sibling missing on disk -------------
echo "  scenario 2: one whitelisted sibling missing on disk..."
OUT=$(stage_search_roots "acme/self")
assert_contains "scenario 2: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 2: included=2" "included=2" "$OUT"
assert_contains "scenario 2: missing=1" "missing=1" "$OUT"
assert_contains "scenario 2: foo included" "acme/foo included .siblings/acme/foo" "$OUT"
assert_contains "scenario 2: bar included" "acme/bar included .siblings/acme/bar" "$OUT"
assert_contains "scenario 2: qux missing" "acme/qux missing" "$OUT"

# --- scenario 3: zero whitelisted siblings -> same-repo-only ---------
echo "  scenario 3: zero whitelisted siblings (just the base repo)..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self")
OUT=$(stage_search_roots "acme/self")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 3: header same-repo-only" "no sibling SOURCE_PATHS in scope" "$OUT"

# --- scenario 4: every whitelisted sibling missing on disk -----------
echo "  scenario 4: every whitelisted sibling missing on disk..."
rm -rf "$TMPDIR/repos/foo" "$TMPDIR/repos/bar"
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
OUT=$(stage_search_roots "acme/self")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 4: header same-repo-only" "same-repo-only — included=0 missing=2" "$OUT"
assert_contains "scenario 4: foo missing" "acme/foo missing" "$OUT"
assert_contains "scenario 4: bar missing" "acme/bar missing" "$OUT"

echo "  PASS (4 scenarios: full-coverage, missing-on-disk, no-siblings, all-missing)"
