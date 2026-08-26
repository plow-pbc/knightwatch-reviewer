#!/usr/bin/env bash
# No ExecStart entrypoint may define its own log().
#
# bakeoff, org-sync and kid-refresh each carried a strictly-lossy copy of
# state-io's log() — the same "[timestamp] $*" to the same file, minus the tee to
# stdout — so every line those units emitted was invisible in
# `journalctl -u <unit>` despite all three being StandardOutput=journal. The
# defect recurred three times, always as a fresh local definition that looked
# harmless beside the sourcing line.
#
# A source-shape check, because the defect IS a source shape: a shadowing
# function definition. The per-entrypoint stdout captures in org-sync-smoke and
# plow-kid-refresh-smoke are the behavioural backstop for those two; this covers
# the rest, which have none.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

# DERIVED from the units, not hand-listed: kid-refresh carried a unit and a
# shadow for the whole time an earlier hand-list claimed to cover it, and only a
# human noticing closed the gap — which is the drift lib/systemd-units.sh exists
# to prevent and that three call sites already use. render-compose.sh is
# correctly excluded (it is ExecStartPre, not ExecStart); review-loop.sh is added
# by hand because it is the CONTAINER entry and has no unit.
. "$PROJECT_ROOT/lib/systemd-units.sh"
ENTRYPOINTS=$(list_execstart_shell_scripts "$PROJECT_ROOT" "$PROJECT_ROOT"/systemd/*.service; echo review-loop.sh)
[ "$(printf '%s\n' "$ENTRYPOINTS" | grep -c .)" -ge 6 ] \
    || fail "derived only $(printf '%s\n' "$ENTRYPOINTS" | grep -c .) entrypoints — the unit derivation broke, so this asserts nothing"

for _entry in $ENTRYPOINTS; do
    # Comment-stripped and FLATTENED before matching, so the brace may sit on the
    # next line: `log()\n{` is ordinary bash, and a single-line-only pattern let
    # it straight through on every entrypoint that had no behaviour pin.
    _flat_src=$(sed -e 's/#.*//' "$PROJECT_ROOT/$_entry" | tr '\n' ' ')
    grep -qE '(^|[^A-Za-z0-9_])(function[[:space:]]+)?log[[:space:]]*\(?\)?[[:space:]]*\{' <<<"$_flat_src" \
        && fail "$_entry shadows log() — state-io's already writes to LOG_FILE and TEES to stdout, so a local copy silently drops this unit's whole run out of journalctl"
done

echo "  PASS ($(printf '%s\n' "$ENTRYPOINTS" | grep -c .) entrypoints, none shadowing log())"
