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
declare -A DEAD_CODE_CMDS=()
declare -A STRICT_TYPING_CMDS=()
# `[ -f X ] && . X` would trip errexit at the top level when X is
# absent (the && chain returns 1, errexit exits). `if/then/fi`
# is errexit-exempt — same effect, but safe under `set -e`.
if [ -f "${STATE_DIR}/repos.conf" ]; then . "${STATE_DIR}/repos.conf"; fi
if [ -f "${STATE_DIR}/config.env" ]; then . "${STATE_DIR}/config.env"; fi

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
