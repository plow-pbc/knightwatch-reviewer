#!/usr/bin/env bash
# Manifest contract smoke — the SINGLE suite that exercises every
# repos.conf consumer plus install.sh from one shared fixture.
# Replaces the previous patch-by-patch approach where each consumer
# added its own bespoke smoke and they drifted independently.
#
# Contract:
#   A. repos.conf sources cleanly + has the expected shape (REPOS
#      non-empty, KID_PATHS is an assoc array, every REPO has a
#      KID_PATHS entry, no stale KID_PATHS keys, plow-content tracked).
#   B. lib/tracked-repos.sh is the ONE seam for loading the manifest:
#      pre-declares REPOS/KID_PATHS empty so accesses stay safe under
#      `set -u` when repos.conf is absent, sources repos.conf and
#      config.env in that order so config.env can override REPOS.
#   C. Every production consumer sources lib/tracked-repos.sh — the
#      hard list catches drift if a new consumer is added without
#      going through the loader.
#   D. install.sh symlinks repos.conf into INSTALL_DIR — sandboxed
#      install + readlink verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONF="$PROJECT_ROOT/repos.conf"
LOADER="$PROJECT_ROOT/lib/tracked-repos.sh"

[ -f "$CONF" ] || { echo "FAIL: $CONF missing"; exit 1; }
[ -f "$LOADER" ] || { echo "FAIL: $LOADER missing"; exit 1; }

# ----- Contract A: canonical repos.conf shape -----------------------------
# Source the canonical conf in a subshell so it doesn't pollute the test's
# env. The smoke binary is bash, so sourcing the bash conf is the same
# shape every consumer uses.
declare -a REPOS=()
declare -A KID_PATHS=()
. "$CONF"

echo "  A1: REPOS is non-empty..."
[ "${#REPOS[@]}" -ge 1 ] || { echo "FAIL A1: REPOS array is empty"; exit 1; }

echo "  A2: KID_PATHS is an associative array (declare -A)..."
declare -p KID_PATHS 2>/dev/null | grep -q '^declare -A' || { echo "FAIL A2: KID_PATHS is not declared as an associative array"; exit 1; }

echo "  A3: every REPO has a non-empty KID_PATHS entry..."
for repo in "${REPOS[@]}"; do
    val="${KID_PATHS[$repo]:-}"
    [ -n "$val" ] || { echo "FAIL A3: KID_PATHS[$repo] is missing or empty"; exit 1; }
done

echo "  A3b: SOURCE_PATHS is an associative array (declare -A)..."
declare -p SOURCE_PATHS 2>/dev/null | grep -q '^declare -A' || { echo "FAIL A3b: SOURCE_PATHS is not declared as an associative array"; exit 1; }

echo "  A3c: every REPO has a non-empty SOURCE_PATHS entry..."
# Cross-repo grep depends on a source-checkout path per repo.
# Empty entries are allowed (= exclude that repo from the grep
# surface), but undeclared keys mean the manifest drifted.
for repo in "${REPOS[@]}"; do
    declare -p SOURCE_PATHS | grep -qE "\\[$repo\\]=" || { echo "FAIL A3c: SOURCE_PATHS missing key for $repo"; exit 1; }
done

echo "  A3d: DEAD_CODE_CMDS is an associative array (declare -A)..."
declare -p DEAD_CODE_CMDS 2>/dev/null | grep -q '^declare -A' || { echo "FAIL A3d: DEAD_CODE_CMDS is not declared as an associative array"; exit 1; }

echo "  A3e: every REPO has a DEAD_CODE_CMDS entry (empty allowed)..."
# Empty string = no static tool wired (LLM grep still runs). What we
# fence is that adding a repo without adding a DEAD_CODE_CMDS entry
# trips set -u in the worker.
for repo in "${REPOS[@]}"; do
    declare -p DEAD_CODE_CMDS | grep -qE "\\[$repo\\]=" || { echo "FAIL A3e: DEAD_CODE_CMDS missing key for $repo"; exit 1; }
done

echo "  A3f: STRICT_TYPING_CMDS is an associative array (declare -A)..."
declare -p STRICT_TYPING_CMDS 2>/dev/null | grep -q '^declare -A' || { echo "FAIL A3f: STRICT_TYPING_CMDS is not declared as an associative array"; exit 1; }

echo "  A3g: every REPO has a STRICT_TYPING_CMDS entry (empty allowed)..."
# Same fence as DEAD_CODE_CMDS — empty = check skipped (e.g. bash repos
# don't have a strict-typing concept). The worker's `${STRICT_TYPING_CMDS[$REPO]:-}`
# tolerates a missing key, but a missing key is also config drift the
# operator should know about.
for repo in "${REPOS[@]}"; do
    declare -p STRICT_TYPING_CMDS | grep -qE "\\[$repo\\]=" || { echo "FAIL A3g: STRICT_TYPING_CMDS missing key for $repo"; exit 1; }
done

echo "  A4: every KID_PATHS key corresponds to a tracked REPO..."
# Catch the inverse: a stale KID_PATHS entry whose repo got removed
# from REPOS. (Harmless functionally, but a config-drift signal.)
for key in "${!KID_PATHS[@]}"; do
    found=0
    for repo in "${REPOS[@]}"; do
        if [ "$key" = "$repo" ]; then found=1; break; fi
    done
    [ "$found" = "1" ] || { echo "FAIL A4: KID_PATHS has stale entry [$key] not in REPOS"; exit 1; }
done

echo "  A5: cncorp/plow-content is tracked..."
# Specific anchor for the PR that introduced this conf file. If a
# future edit accidentally drops plow-content, the smoke surfaces it
# directly (rather than only via 'no review showed up on plow-content'
# in prod).
found=0
for repo in "${REPOS[@]}"; do
    if [ "$repo" = "cncorp/plow-content" ]; then found=1; break; fi
done
[ "$found" = "1" ] || { echo "FAIL A5: cncorp/plow-content missing from REPOS"; exit 1; }

# ----- Contract B: lib/tracked-repos.sh loader behavior -------------------
TMPDIR=$(mktemp -d -t repos-conf-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT
SAND_STATE="$TMPDIR/state"
mkdir -p "$SAND_STATE"

echo "  B1: loader populates REPOS+KID_PATHS from a fixture repos.conf..."
cat > "$SAND_STATE/repos.conf" <<'CONF'
REPOS=("acme/foo" "acme/bar")
declare -A KID_PATHS=([acme/foo]=/x/foo [acme/bar]=/x/bar)
CONF
out=$(STATE_DIR="$SAND_STATE" bash -c "set -euo pipefail; . '$LOADER'; echo \"REPOS=\${#REPOS[@]} foo=\${KID_PATHS[acme/foo]:-MISSING}\"")
[ "$out" = "REPOS=2 foo=/x/foo" ] || { echo "FAIL B1: loader output: $out"; exit 1; }

echo "  B2: loader survives missing repos.conf under set -u (empty arrays)..."
rm -f "$SAND_STATE/repos.conf"
out=$(STATE_DIR="$SAND_STATE" bash -c "set -euo pipefail; . '$LOADER'; echo \"REPOS=\${#REPOS[@]} KID_PATHS=\${#KID_PATHS[@]} SOURCE_PATHS=\${#SOURCE_PATHS[@]} DEAD_CODE_CMDS=\${#DEAD_CODE_CMDS[@]} STRICT_TYPING_CMDS=\${#STRICT_TYPING_CMDS[@]}\"")
[ "$out" = "REPOS=0 KID_PATHS=0 SOURCE_PATHS=0 DEAD_CODE_CMDS=0 STRICT_TYPING_CMDS=0" ] || { echo "FAIL B2: loader output: $out"; exit 1; }

echo "  B3: config.env override wins over repos.conf (legacy seam)..."
cat > "$SAND_STATE/repos.conf" <<'CONF'
REPOS=("acme/foo")
declare -A KID_PATHS=([acme/foo]=/x/foo)
CONF
cat > "$SAND_STATE/config.env" <<'CONF'
REPOS=("acme/override")
CONF
out=$(STATE_DIR="$SAND_STATE" bash -c "set -euo pipefail; . '$LOADER'; echo \"REPOS=\${REPOS[0]}\"")
[ "$out" = "REPOS=acme/override" ] || { echo "FAIL B3: loader output: $out"; exit 1; }

echo "  B4: lookup of an unknown REPO returns empty, not a set-u error..."
# Catches the regression where the worker's KID_PROJECT_PATH lookup
# crashed with "unbound variable" because KID_PATHS wasn't pre-declared.
rm -f "$SAND_STATE/repos.conf" "$SAND_STATE/config.env"
out=$(STATE_DIR="$SAND_STATE" bash -c "set -euo pipefail; . '$LOADER'; REPO=cncorp/nonexistent; echo \"v=[\${KID_PATHS[\$REPO]:-}]\"" 2>&1)
[ "$out" = "v=[]" ] || { echo "FAIL B4: loader output: $out"; exit 1; }

# ----- Contract C: every production consumer goes through the loader ------
echo "  C: every production consumer sources lib/tracked-repos.sh..."
# Hard list of every script that needs the manifest. Adding a new
# consumer means adding it here AND making it source the loader.
CONSUMERS=(
    "review.sh"
    "re-request-poller.sh"
    "learn-from-replies.sh"
    "approve-from-replies.sh"
    "lib/review-one-pr.sh"
    "plow-kid-refresh.sh"
)
for c in "${CONSUMERS[@]}"; do
    f="$PROJECT_ROOT/$c"
    [ -f "$f" ] || { echo "FAIL C: $c missing from repo"; exit 1; }
    grep -q 'tracked-repos\.sh' "$f" || { echo "FAIL C: $c does not source lib/tracked-repos.sh"; exit 1; }
done

# ----- Contract D: install.sh symlinks repos.conf into INSTALL_DIR --------
echo "  D: install.sh symlinks repos.conf into INSTALL_DIR..."
# Sandboxed install. install.sh runs sudo cp + sudo systemctl; stub
# both so the test doesn't need real privilege or systemd. We only
# care about the symlink leg (no sudo, no systemctl), but stubbing
# keeps the install run from failing partway through.
SAND_INSTALL="$TMPDIR/install"
SAND_SYSTEMD="$TMPDIR/systemd"
SAND_HOME="$TMPDIR/home"
mkdir -p "$SAND_INSTALL" "$SAND_SYSTEMD" "$SAND_HOME/.local/bin"
cat > "$SAND_HOME/.local/bin/sudo" <<'STUB'
#!/bin/bash
exec "$@"
STUB
cat > "$SAND_HOME/.local/bin/systemctl" <<'STUB'
#!/bin/bash
case "$1" in
    is-enabled|is-active) exit 0 ;;  # already enabled — install skips enable --now
    *) exit 0 ;;
esac
STUB
chmod +x "$SAND_HOME/.local/bin/sudo" "$SAND_HOME/.local/bin/systemctl"

(
    cd "$PROJECT_ROOT"
    HOME="$SAND_HOME" \
        PATH="$SAND_HOME/.local/bin:$PATH" \
        INSTALL_DIR="$SAND_INSTALL" \
        SYSTEMD_DIR="$SAND_SYSTEMD" \
        ./install.sh > /dev/null
)

LINK="$SAND_INSTALL/repos.conf"
[ -L "$LINK" ] || { echo "FAIL D: $LINK is not a symlink"; ls -la "$SAND_INSTALL"; exit 1; }
TARGET="$(readlink -f "$LINK")"
EXPECTED="$(readlink -f "$CONF")"
[ "$TARGET" = "$EXPECTED" ] || { echo "FAIL D: symlink resolves to $TARGET, expected $EXPECTED"; exit 1; }

echo "  PASS (A1-A5: shape; B1-B4: loader; C: $(echo "${#CONSUMERS[@]}") consumers; D: install delivery)"
