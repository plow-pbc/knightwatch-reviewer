#!/usr/bin/env bash
# Shared path/slug derivation for the replay subsystem.
#
# Sourced by lib/replay.sh, lib/replay-verify.sh, and lib/replay-batch.sh
# so the per-cell directory name (`<repo-slug>-<pr>-<sha7>-<slug>`) and the
# prompt-set slug rule are owned in one place. The "$HOME/.pr-reviewer/replays/"
# location prefix is the entrypoints' responsibility — this file owns the
# naming contract, not the privacy boundary.
#
# Naming contract:
#   replay_prompt_slug PROMPTS_DIR
#       → basename(PROMPTS_DIR or "default"), with non-alphanumerics → '_'
#   replay_run_dir REPO PR SHA SLUG
#       → "<repo-slug>-<pr>-<sha7>-<slug>"  (relative; no $HOME prefix)
#
# Source guard: re-sourcing is safe (function definitions, no side effects).

# Slug for an alternate prompts/ directory. Empty / unset PROMPTS_DIR yields
# "default" so back-to-back A/B runs against the same repo/PR/SHA don't
# clobber each other's output dir.
replay_prompt_slug() {
    local prompts_dir="${1:-default}"
    # Strip basename's trailing newline before `tr` so the slug doesn't
    # carry a trailing '_'. printf is the cleanest no-newline emit.
    local base
    base=$(basename "$prompts_dir")
    printf '%s' "$base" | tr -c 'A-Za-z0-9' '_'
}

# Per-cell directory name. Composed by the entrypoint into a full path:
#   $HOME/.pr-reviewer/replays/<this>     (default)
#   replays/<this>                         (when --output-dir replays/... is passed)
#
# Validates pr (digits) and sha (hex) to prevent path traversal via
# fixture/CSV-controlled values. A pr=../../foo or sha=../../ would
# otherwise compose into a dir name that resolves outside the intended
# replay tree once concatenated with $HOME/.pr-reviewer/replays/.
replay_run_dir() {
    local repo="$1" pr="$2" sha="$3" slug="$4"
    case "$pr" in
        ''|*[!0-9]*)
            echo "FAIL: replay_run_dir: pr must be all-digits, got: '$pr'" >&2
            return 2 ;;
    esac
    case "$sha" in
        ''|*[!0-9a-fA-F]*)
            echo "FAIL: replay_run_dir: sha must be hex, got: '$sha'" >&2
            return 2 ;;
    esac
    printf '%s-%s-%s-%s\n' "${repo//\//-}" "$pr" "${sha:0:7}" "$slug"
}
