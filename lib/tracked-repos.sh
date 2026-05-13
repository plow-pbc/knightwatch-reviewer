# Shared loader for the tracked-repos manifest.
#
# Single seam between the manifest file (repos.conf) and every consumer
# (review.sh, re-request-poller.sh, learn-from-replies.sh,
# approve-from-replies.sh, lib/review-one-pr.sh). Adding a new consumer
# means sourcing this file — not duplicating the source-twice-then-assert
# bootstrap that lived inline in each script before.
#
# Caller contract:
#   - $STATE_DIR must be set before sourcing.
#   - Source at FILE SCOPE, not inside a function. `declare -A` inside a
#     function creates locals (even with `-g`-pre-declared globals as
#     intended targets), and repos.conf uses bare `declare -A KID_PATHS=…`
#     so its assignment must land in the global scope.
#
# Pre-declares REPOS and KID_PATHS as empty so accesses stay safe under
# `set -u` even when repos.conf is absent (e.g. narrow test sandboxes).
# Consumers that REQUIRE a non-empty REPOS assert it themselves after
# sourcing — the worker (lib/review-one-pr.sh) doesn't, because it only
# needs KID_PATHS for prior-art lookup and works fine when repos.conf
# is missing for a particular kid.

declare -a REPOS=()
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
# ORGS — optional GitHub orgs that org-sync.sh discovers + folds into
# REPOS hourly. Pre-declared empty so consumers that don't enable
# org-sync still load cleanly under `set -u`.
declare -a ORGS=()
# Source order:
#   1. config.env       — ops knobs (BOT_USER, BOT_CMD_PREFIX, etc.).
#                         Pre-PR-#75 it could override REPOS too; that
#                         seam was retired.
#   2. repos.conf       — operator-owned manifest (manual REPOS,
#                         KID_PATHS, SOURCE_PATHS, ORGS). Operator
#                         edits use bare `REPOS=(...)` and
#                         `declare -A KID_PATHS=(...)` (replace, not
#                         append) so this MUST be sourced before any
#                         file that depends on those arrays existing.
#   3. repos.conf.auto  — tool-owned, regenerated hourly by org-sync.sh.
#                         Appends with `REPOS+=("...")` and uses the
#                         CONDITIONAL form `KID_PATHS[k]="${KID_PATHS[k]:-default}"`
#                         for the path assignments. The conditional
#                         form is load-bearing for manual-wins-on-
#                         collision: an operator promoting an
#                         auto-tracked repo to manual (with a custom
#                         KID_PATHS) takes effect immediately, even in
#                         the window before the next hourly sync prunes
#                         the now-redundant auto entry.
#
# `[ -f X ] && . X` would trip errexit at the top level when X is
# absent (the && chain returns 1, errexit exits). `if/then/fi`
# is errexit-exempt — same effect, but safe under `set -e`.
if [ -f "${STATE_DIR}/config.env" ];      then . "${STATE_DIR}/config.env"; fi
if [ -f "${STATE_DIR}/repos.conf" ];      then . "${STATE_DIR}/repos.conf"; fi
if [ -f "${STATE_DIR}/repos.conf.auto" ]; then . "${STATE_DIR}/repos.conf.auto"; fi

# Dedup REPOS preserving order. The conditional `${var:-default}` form
# in repos.conf.auto already protects KID_PATHS / SOURCE_PATHS from
# collisions, but the auto file's `REPOS+=("...")` is unconditional
# (bash indexed arrays don't have a clean "append only if not present"
# primitive). During the operator-promotion window — operator pins an
# auto-tracked repo in repos.conf before the next sync prunes the auto
# entry — REPOS would otherwise carry the slug twice, and consumers
# iterating it (review.sh, learn-from-replies.sh, etc.) would process
# the same PR set twice. Loader-side dedup is one fix for all
# consumers (PR #75 round 5).
if [ "${#REPOS[@]}" -gt 0 ]; then
    mapfile -t REPOS < <(printf '%s\n' "${REPOS[@]}" | awk '!seen[$0]++')
fi

# Single owner of the post-config TMPDIR policy. pr-reviewer.service
# combines PrivateTmp=yes (sandbox) with KillMode=process (workers
# survive orchestrator exit); the unit-private /tmp tears down when the
# unit deactivates a few seconds later, so any detached worker doing
# `mktemp` in /tmp lands in a dead mount namespace and the call fails
# with `'/tmp/tmp.XXXXXXXXXX': No such file or directory`. STATE_DIR
# lives outside the private mount and is in the unit's ReadWritePaths.
#
# Pinning unconditionally — and HERE, after config.env may have set its
# own TMPDIR — makes $STATE_DIR/tmp policy: every consumer that sources
# this loader (review.sh orchestrator + lib/review-one-pr.sh worker +
# all -from-replies / -poller / -refresh siblings) gets the same pin
# without each script needing its own order-sensitive copy. This is
# Bug-Class-Recurrence territory — the prior per-script duplication
# made each new entrypoint a fresh chance to regress the invariant.
export TMPDIR="$STATE_DIR/tmp"
mkdir -p "$TMPDIR"
