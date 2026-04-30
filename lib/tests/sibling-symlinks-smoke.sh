#!/bin/bash
# Smoke for lib/sibling-symlinks.sh. Three invariants:
#
#   1. Only symlink siblings the caller explicitly classified as
#      `included` — auth-gated upstream by stage_search_roots, not by
#      this helper's own iteration over SOURCE_PATHS. (Bot Finding 2:
#      the original ordering exposed every configured checkout to
#      Codex even when the auth seam would have excluded it.)
#
#   2. Defeat committed-symlink path-redirect attacks. The PR's
#      checkout might already contain `.siblings/` (e.g. an attacker
#      committed `.siblings/cncorp/plow-content` as a symlink to
#      ~/.ssh/). Wipe whatever's there before materializing.
#
#   3. Missing siblings (no SOURCE_PATHS dir on disk) are skipped
#      silently — the search-roots seam already classifies those.

set -euo pipefail

TMPDIR=$(mktemp -d -t sibling-symlinks-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../sibling-symlinks.sh
. "$SCRIPT_DIR/sibling-symlinks.sh"

WORKDIR="$TMPDIR/work"
mkdir -p "$WORKDIR/.git"  # mimic a real workdir
mkdir -p "$TMPDIR/foo" "$TMPDIR/bar" "$TMPDIR/baz"
# acme/qux is intentionally missing on disk.

declare -A SOURCE_PATHS=(
    ["acme/foo"]="$TMPDIR/foo"
    ["acme/bar"]="$TMPDIR/bar"
    ["acme/baz"]="$TMPDIR/baz"   # deliberately NOT included
    ["acme/qux"]="$TMPDIR/qux"   # deliberately missing on disk
)

# --- scenario 1: only `included` siblings get symlinked ---------------
echo "  scenario 1: auth-gated to included slugs..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"

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
# baz is in SOURCE_PATHS but was NOT in the included list — must NOT exist.
if [ -e "$WORKDIR/.siblings/acme/baz" ]; then
    echo "FAIL: baz symlink should not exist (auth-excluded by caller)"
    exit 1
fi

# --- scenario 2: missing checkout silently skipped ---------------------
echo "  scenario 2: missing on-disk checkout silently skipped..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/qux"
if [ -L "$WORKDIR/.siblings/acme/qux" ]; then
    echo "FAIL: qux symlink should not exist (path missing on disk)"
    exit 1
fi

# --- scenario 3: defeat committed-symlink path-redirect attack --------
echo "  scenario 3: pre-existing malicious .siblings/ wiped..."
ATTACK_TARGET="$TMPDIR/SHOULD_NOT_BE_TOUCHED"
mkdir -p "$ATTACK_TARGET"
touch "$ATTACK_TARGET/sentinel"
# Simulate the PR committing `.siblings/acme` as a symlink to a
# directory outside the workdir. Without a wipe, mkdir/ln would write
# through the symlink.
rm -rf "$WORKDIR/.siblings"
mkdir -p "$WORKDIR/.siblings/acme"
ln -sfn "$ATTACK_TARGET" "$WORKDIR/.siblings/acme"   # acme is now a symlink

materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo"

# .siblings/acme should now be a real directory, not the attacker's symlink.
if [ -L "$WORKDIR/.siblings/acme" ]; then
    echo "FAIL: .siblings/acme is still a symlink — wipe didn't happen"
    exit 1
fi
# foo should resolve to the real source, not under ATTACK_TARGET.
got_foo=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo" != "$TMPDIR/foo" ]; then
    echo "FAIL: foo symlink not pointing at real source after redirect attack"
    exit 1
fi
# Attacker target must be untouched.
if [ ! -e "$ATTACK_TARGET/sentinel" ]; then
    echo "FAIL: attacker target sentinel was modified — write escaped workdir"
    exit 1
fi
if [ -e "$ATTACK_TARGET/foo" ] || [ -L "$ATTACK_TARGET/foo" ]; then
    echo "FAIL: attacker target gained a 'foo' entry — write escaped workdir"
    exit 1
fi

# --- scenario 4: re-runs are idempotent --------------------------------
echo "  scenario 4: idempotent re-run..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS "acme/foo" "acme/bar"
got_foo2=$(readlink "$WORKDIR/.siblings/acme/foo")
if [ "$got_foo2" != "$TMPDIR/foo" ]; then
    echo "FAIL: re-run changed foo symlink target"
    exit 1
fi

# --- scenario 5: empty included list = empty .siblings/ ---------------
echo "  scenario 5: empty included list produces empty .siblings/..."
materialize_sibling_symlinks "$WORKDIR" SOURCE_PATHS
if [ -d "$WORKDIR/.siblings" ] && [ -n "$(ls -A "$WORKDIR/.siblings" 2>/dev/null)" ]; then
    echo "FAIL: .siblings/ should be empty when nothing included"
    ls -la "$WORKDIR/.siblings"
    exit 1
fi

echo "  ok: sibling symlinks auth-gated, redirect-safe, and idempotent"
