#!/bin/bash
# One-shot migration: move org-sync auto-managed clones from the
# legacy $HOME/Hacking/<name> path to the new $HOME/services/kwr-repos/<name>
# location. Reads the auto-tracked set from ~/.pr-reviewer/repos.conf.auto
# and for each entry whose legacy checkout exists, has a matching origin
# URL, and is NOT operator-claimed via a manual KID_PATHS override, runs
# `mv` to the new path. Preserves .git history (no re-clone, no network).
#
# Idempotent: re-running after a successful migration is a no-op (legacy
# path doesn't exist anymore for already-moved repos). Safe to run with
# the pr-reviewer-org-sync.timer paused OR running, but paused is cleaner
# — a mid-migration tick could fresh-clone something into the new path
# before the mv lands and then conflict.
#
# Skip cases (each logged, none fail the run):
#   - legacy path doesn't exist (nothing to move)
#   - legacy path exists but isn't a git checkout (operator artifact, skip)
#   - legacy path's origin URL doesn't match canonical forms (collision
#     with a different repo, skip — operator's call to resolve)
#   - new path already exists (prior migration or fresh clone, skip)
#   - manual KID_PATHS for this repo points at the legacy path (operator
#     explicitly claimed that dev clone as the prior-art source)
#
# Exit code: 0 if migration completed (any number of skips is fine);
# 1 only on unexpected error (config sourcing failure, mkdir failure).
#
# Usage: bash /home/odio/services/knightwatch-reviewer/scripts/migrate-org-sync-clones.sh
# (or wherever the prod clone lives — this script doesn't depend on its own location)

set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LEGACY_BASE="${LEGACY_BASE:-$HOME/Hacking}"
NEW_BASE="${NEW_BASE:-$HOME/services/kwr-repos}"
CONF="${CONF:-$STATE_DIR/repos.conf}"
AUTO_CONF="${AUTO_CONF:-$STATE_DIR/repos.conf.auto}"

[ -f "$AUTO_CONF" ] || { echo "FATAL: $AUTO_CONF not found — has org-sync run at least once?"; exit 1; }

# Source repos.conf alone (manual set) to read MANUAL KID_PATHS — those
# are the operator's "use my dev clone, leave it alone" markers and must
# be honored as skip signals. Sub-shell so the parent's set -u stays
# clean; export via printf-cooked output read back into a string map.
MANUAL_KID_PATHS_DUMP=$(
    set -e
    declare -a REPOS=()
    declare -A KID_PATHS=()
    declare -A SOURCE_PATHS=()
    declare -a ORGS=()
    # shellcheck disable=SC1090
    [ -f "$CONF" ] && . "$CONF"
    for full in "${!KID_PATHS[@]}"; do
        printf '%s\t%s\n' "$full" "${KID_PATHS[$full]}"
    done
) || { echo "FATAL: failed to source $CONF for manual KID_PATHS"; exit 1; }
declare -A MANUAL_KID=()
while IFS=$'\t' read -r full path; do
    [ -n "$full" ] && MANUAL_KID["$full"]="$path"
done <<< "$MANUAL_KID_PATHS_DUMP"

# Source the auto file too, BUT only to extract its REPOS list. The
# AUTO_CONF embeds KID_PATHS expressions referencing the OLD path —
# don't act on those; the source-of-truth for "what's auto-managed" is
# the REPOS list, and the path is fixed by convention.
AUTO_REPOS=$(
    set -e
    declare -a REPOS=()
    declare -A KID_PATHS=()
    # shellcheck disable=SC1090
    . "$AUTO_CONF"
    printf '%s\n' "${REPOS[@]}"
) || { echo "FATAL: failed to source $AUTO_CONF"; exit 1; }

mkdir -p "$NEW_BASE"

MOVED=0
SKIPPED_NO_LEGACY=0
SKIPPED_NOT_GIT=0
SKIPPED_URL_MISMATCH=0
SKIPPED_NEW_EXISTS=0
SKIPPED_OPERATOR_CLAIMED=0

while IFS= read -r full; do
    [ -n "$full" ] || continue
    name="${full#*/}"
    legacy="$LEGACY_BASE/$name"
    new="$NEW_BASE/$name"

    # Operator-claimed via manual KID_PATHS pointing at the legacy path?
    # That's the operator saying "this is my dev clone, leave it alone."
    # Honor it — leave legacy in place, let org-sync fresh-clone into
    # the new path on next tick.
    operator_claimed=""
    for manual_full in "${!MANUAL_KID[@]}"; do
        if [ "${MANUAL_KID[$manual_full]}" = "$legacy" ]; then
            operator_claimed="yes"
            break
        fi
    done
    if [ -n "$operator_claimed" ]; then
        echo "skip $full: operator-claimed via manual KID_PATHS → $legacy"
        SKIPPED_OPERATOR_CLAIMED=$((SKIPPED_OPERATOR_CLAIMED + 1))
        continue
    fi

    if [ -e "$new" ]; then
        echo "skip $full: $new already exists"
        SKIPPED_NEW_EXISTS=$((SKIPPED_NEW_EXISTS + 1))
        continue
    fi

    if [ ! -e "$legacy" ]; then
        # No legacy clone — already in the new world, or never cloned.
        SKIPPED_NO_LEGACY=$((SKIPPED_NO_LEGACY + 1))
        continue
    fi

    if [ ! -d "$legacy/.git" ]; then
        echo "skip $full: $legacy exists but is not a git checkout — operator artifact, leaving alone"
        SKIPPED_NOT_GIT=$((SKIPPED_NOT_GIT + 1))
        continue
    fi

    if ! url=$(git -C "$legacy" remote get-url origin 2>/dev/null); then
        echo "skip $full: $legacy has no origin remote — leaving alone"
        SKIPPED_NOT_GIT=$((SKIPPED_NOT_GIT + 1))
        continue
    fi

    # Same canonical-forms guard as org-sync.sh — only move clones we
    # can prove are actually this repo. A mismatched URL means the
    # legacy path is a different repo with a colliding name, and the
    # operator needs to resolve it (rename, or set a manual KID_PATHS
    # marker to claim the dev clone).
    case "$url" in
        "git@github.com:${full}.git"|"git@github.com:${full}"|"https://github.com/${full}.git"|"https://github.com/${full}") ;;
        *)
            echo "skip $full: $legacy origin URL does not match canonical forms for $full — collision, operator must resolve"
            SKIPPED_URL_MISMATCH=$((SKIPPED_URL_MISMATCH + 1))
            continue
            ;;
    esac

    echo "moving $full: $legacy → $new"
    mv "$legacy" "$new"
    MOVED=$((MOVED + 1))
done <<< "$AUTO_REPOS"

echo "---"
echo "migration summary:"
echo "  moved:                    $MOVED"
echo "  skipped (no legacy):      $SKIPPED_NO_LEGACY"
echo "  skipped (not git):        $SKIPPED_NOT_GIT"
echo "  skipped (URL mismatch):   $SKIPPED_URL_MISMATCH"
echo "  skipped (new exists):     $SKIPPED_NEW_EXISTS"
echo "  skipped (operator-claim): $SKIPPED_OPERATOR_CLAIMED"
