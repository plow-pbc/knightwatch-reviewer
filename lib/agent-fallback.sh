#!/usr/bin/env bash
# Sourceable helpers that decide what to do with an agent's output file
# when the agent's run-specialist.sh invocation exits non-zero or empty.
# Lives outside review-one-pr.sh so the regression smoke can exercise
# the exact decision the worker uses (instead of testing a copy).

# critic_fallback EXIT_CODE OUT_FILE
#
# The critic step is the only agent the review pipeline tolerates a
# failure from — the aggregator's prompt is explicitly written to handle
# an empty critic. But run-specialist.sh leaves any partial output behind
# on a non-zero codex exit, and the aggregator reads .codex-scratch/critic.md
# first, so a truncated critic could steer the posted review. On any
# non-zero exit (codex error or run-specialist's empty-output exit 3),
# replace the file with the same placeholder; on clean success
# (zero exit, which run-specialist only returns when output is non-empty),
# leave the file alone.
critic_fallback() {
    local exit_code="$1" out_file="$2"
    if [ "$exit_code" -ne 0 ]; then
        echo "(critic failed with exit=$exit_code — fall back)" > "$out_file"
    fi
}
