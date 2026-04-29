#!/bin/bash
# Smoke test for the canonical repos.conf at the repo root. Verifies:
#   - The file sources cleanly
#   - REPOS is a non-empty array
#   - KID_PATHS is an associative array with one entry per REPO
#   - Every KID_PATHS value is non-empty
#
# This is the regression fence for "default tracked-repo set drifts"
# scenarios — e.g., someone removes a repo from REPOS but forgets to
# remove the corresponding KID_PATHS entry, or vice versa. Stays out
# of the way of operator-driven repo additions: editing repos.conf
# correctly produces a passing smoke; broken edits fail loud here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONF="$PROJECT_ROOT/repos.conf"

[ -f "$CONF" ] || { echo "FAIL: $CONF missing"; exit 1; }

# Source the conf in a subshell so it doesn't pollute the test's env.
# The smoke binary is bash, so sourcing the bash conf is the same shape
# every consumer uses (review.sh / learn-from-replies.sh / etc.).
declare -a REPOS=()
declare -A KID_PATHS=()
. "$CONF"

echo "  scenario 1: REPOS is non-empty..."
[ "${#REPOS[@]}" -ge 1 ] || { echo "FAIL scenario 1: REPOS array is empty"; exit 1; }

echo "  scenario 2: KID_PATHS is an associative array (declare -A)..."
# `declare -p` shows the type. `declare -A` if associative.
declare -p KID_PATHS 2>/dev/null | grep -q '^declare -A' || { echo "FAIL scenario 2: KID_PATHS is not declared as an associative array"; exit 1; }

echo "  scenario 3: every REPO has a non-empty KID_PATHS entry..."
for repo in "${REPOS[@]}"; do
    val="${KID_PATHS[$repo]:-}"
    [ -n "$val" ] || { echo "FAIL scenario 3: KID_PATHS[$repo] is missing or empty"; exit 1; }
done

echo "  scenario 4: every KID_PATHS key corresponds to a tracked REPO..."
# Catch the inverse: a stale KID_PATHS entry whose repo got removed
# from REPOS. (Harmless functionally, but a config-drift signal.)
for key in "${!KID_PATHS[@]}"; do
    found=0
    for repo in "${REPOS[@]}"; do
        if [ "$key" = "$repo" ]; then found=1; break; fi
    done
    [ "$found" = "1" ] || { echo "FAIL scenario 4: KID_PATHS has stale entry [$key] not in REPOS"; exit 1; }
done

echo "  scenario 5: cncorp/plow-content is tracked..."
# Specific anchor for the PR that introduced this conf file. If a future
# edit accidentally drops plow-content, the smoke surfaces it directly
# (rather than only via 'no review showed up on plow-content' in prod).
found=0
for repo in "${REPOS[@]}"; do
    if [ "$repo" = "cncorp/plow-content" ]; then found=1; break; fi
done
[ "$found" = "1" ] || { echo "FAIL scenario 5: cncorp/plow-content missing from REPOS"; exit 1; }

echo "  PASS (5 scenarios: REPOS-nonempty, KID_PATHS-is-assoc-array, every-repo-has-kid-path, no-stale-kid-entries, plow-content-tracked)"
