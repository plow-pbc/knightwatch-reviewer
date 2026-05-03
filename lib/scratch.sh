#!/usr/bin/env bash
# write_scratch — writes input artifacts into the run dir's inputs/ and
# exposes them under the codex-scratch view in the workdir so agents can
# read them via the paths their prompts cite (e.g. ".codex-scratch/diff.patch").
#
# Sourced by lib/review-one-pr.sh (production path) and lib/replay.sh
# (operator-bench replay) so both stage scratch with identical shape:
# real files under $RUN_DIR/inputs/, symlinks at .codex-scratch/<name>.
# Replay's prompt A/B comparison is only valid if its scratch shape
# matches production's — same primitive, same paths, same symlink layout.
write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local input_path="$RUN_DIR/inputs/$filename"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$(dirname "$input_path")" "$scratch_dir/specialists"
    printf '%s' "$content" > "$input_path"
    ln -sfn "$input_path" "$scratch_dir/$filename"
}
