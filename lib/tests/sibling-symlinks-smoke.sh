#!/bin/bash
# Smoke for lib/sibling-symlinks.sh. Verifies symlinks land at
# <workdir>/.siblings/<owner>/<repo> pointing at SOURCE_PATHS values,
# and that missing siblings (no SOURCE_PATHS dir on disk) are skipped
# silently — the search-roots seam already classifies those.

set -euo pipefail

TMPDIR=$(mktemp -d -t sibling-symlinks-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../sibling-symlinks.sh
. "$SCRIPT_DIR/sibling-symlinks.sh"

WORKDIR="$TMPDIR/work"
mkdir -p "$WORKDIR/.git"  # mimic a real workdir
mkdir -p "$TMPDIR/foo" "$TMPDIR/bar"
# acme/qux is intentionally missing on disk.

declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/self"
    ["acme/foo"]="$TMPDIR/foo"
    ["acme/bar"]="$TMPDIR/bar"
    ["acme/qux"]="$TMPDIR/qux"
)
REPO="acme/self"

# Run.
materialize_sibling_symlinks "$WORKDIR" "$REPO" SOURCE_PATHS

# Self should NEVER be symlinked.
if [ -e "$WORKDIR/.siblings/acme/self" ]; then
    echo "FAIL: self symlink should not exist"
    exit 1
fi

# foo + bar should resolve to their abs paths.
got_foo=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo" != "$TMPDIR/foo" ]; then
    echo "FAIL: foo symlink target wrong (got '$got_foo', want '$TMPDIR/foo')"
    exit 1
fi
got_bar=$(readlink "$WORKDIR/.siblings/acme/bar")
if [ "$got_bar" != "$TMPDIR/bar" ]; then
    echo "FAIL: bar symlink target wrong"
    exit 1
fi

# qux is missing on disk — must NOT be symlinked.
if [ -L "$WORKDIR/.siblings/acme/qux" ]; then
    echo "FAIL: qux symlink should not exist (path missing on disk)"
    exit 1
fi

# Re-running must be idempotent.
materialize_sibling_symlinks "$WORKDIR" "$REPO" SOURCE_PATHS
got_foo2=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo2" != "$TMPDIR/foo" ]; then
    echo "FAIL: re-run changed foo symlink target"
    exit 1
fi

echo "  ok: sibling symlinks materialized correctly"
