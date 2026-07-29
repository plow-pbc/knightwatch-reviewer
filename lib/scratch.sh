#!/usr/bin/env bash
# write_scratch — writes input artifacts into the run dir's inputs/ and
# exposes them under the codex-scratch view in the workdir so agents can
# read them via the paths their prompts cite (e.g. ".codex-scratch/diff.patch").
#
# Sourced by lib/review-one-pr.sh (production path) and lib/replay.sh
# (operator-bench replay) so both stage scratch with identical shape:
# real files at .codex-scratch/<name>, archived to $RUN_DIR/inputs/.
# Replay's prompt A/B comparison is only valid if its scratch shape
# matches production's — same primitive, same paths, same file layout.
#
# Every entry is a REAL FILE, never a symlink: agents enumerate
# .codex-scratch to discover what was staged, and `find -type f` can't see a
# symlink. See docs/specs/2026-05-04-python-migration-design.md for the
# incident that established this.
write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local input_path="$RUN_DIR/inputs/$filename"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$(dirname "$input_path")" "$scratch_dir/specialists"
    # rm first: `>` follows a planted symlink out of the workdir; `ln -sfn`
    # never did. Fences the planted entry; the directory redirect is the
    # caller's wipe — both callers rm -rf + recreate .codex-scratch
    # immediately before their first write_scratch (grep "Redirect-safe
    # staging"), and in production that also lands after PR-controlled
    # execution.
    rm -f "$scratch_dir/$filename"
    printf '%s' "$content" > "$scratch_dir/$filename"
    cp "$scratch_dir/$filename" "$input_path"
}
