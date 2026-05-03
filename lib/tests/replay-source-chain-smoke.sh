#!/bin/bash
# Source-chain smoke: extracts the `. "$LIB_DIR/<file>.sh"` lines from
# lib/replay.sh, sources them in the same order in a subshell, then asserts
# `run_specialist_pipeline` is defined. Catches typos like sourcing a
# nonexistent file, or pipeline drift adding a helper replay.sh forgot to
# source. Does NOT invoke codex.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"

# Run in subshell so any variables set by sourced files don't leak
(
    set +u  # source files may reference unset vars; we just need them to define functions
    # Mirror the source order in lib/replay.sh's real-replay path
    . "$LIB_DIR/state-io.sh"
    . "$LIB_DIR/prompt-build.sh"
    . "$LIB_DIR/agent-fallback.sh"
    . "$LIB_DIR/run-dir.sh"
    . "$LIB_DIR/critic-splitter.sh"
    . "$LIB_DIR/go-deep-rank.sh"
    . "$LIB_DIR/orchestrate.sh"
    . "$LIB_DIR/scratch.sh"

    declare -F log >/dev/null || { echo "FAIL: log not defined after source chain"; exit 1; }
    declare -F substitute_placeholders >/dev/null || { echo "FAIL: substitute_placeholders not defined"; exit 1; }
    declare -F build_specialist_prompt >/dev/null || { echo "FAIL: build_specialist_prompt not defined"; exit 1; }
    declare -F build_aggregator_prompt >/dev/null || { echo "FAIL: build_aggregator_prompt not defined"; exit 1; }
    declare -F critic_fallback >/dev/null || { echo "FAIL: critic_fallback not defined"; exit 1; }
    declare -F run_specialist_pipeline >/dev/null || { echo "FAIL: run_specialist_pipeline not defined"; exit 1; }
    declare -F dispatch_agent >/dev/null || { echo "FAIL: dispatch_agent not defined"; exit 1; }
    declare -F write_scratch >/dev/null || { echo "FAIL: write_scratch not defined"; exit 1; }

    echo "OK: replay source chain valid"
)
