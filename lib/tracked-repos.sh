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
# `[ -f X ] && . X` would trip errexit at the top level when X is
# absent (the && chain returns 1, errexit exits). `if/then/fi`
# is errexit-exempt — same effect, but safe under `set -e`.
if [ -f "${STATE_DIR}/repos.conf" ]; then . "${STATE_DIR}/repos.conf"; fi
if [ -f "${STATE_DIR}/config.env" ]; then . "${STATE_DIR}/config.env"; fi
