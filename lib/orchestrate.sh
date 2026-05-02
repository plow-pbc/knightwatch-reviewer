#!/bin/bash
# LLM specialist pipeline — the production half of a review.
#
# `run_specialist_pipeline`: runs the full LLM review pipeline against a
# checked-out repo:
#   1. intent pre-pass (sequential, fail-loud)
#   2. dead-code-search pre-pass (sequential, fail-soft → degraded mode)
#   3. 8 angle specialists (parallel, fail-loud on any)
#   4. momentum specialist (re-reviews only, fail-loud)
#   5. critic pass (fail-soft → placeholder via critic_fallback)
#   6. aggregator (fail-loud)
#
# Inputs (read from caller's environment):
#   REPO_DIR    — checked-out worktree (cwd for codex; .codex-scratch lives here)
#   RUN_DIR     — runs/<RUN_ID> (where agents/<name>/* are written)
#   PR_ID       — repo#num used in log lines
#   PR_TITLE PR_URL PR_AUTHOR — placeholder substitution into prompts
#   _LIB_DIR    — directory containing run-specialist.sh
#
# Side effects:
#   $RUN_DIR/agents/<name>/{prompt.txt,output.md,log.txt} for each agent
#   $REPO_DIR/.codex-scratch/{inferred-intent.md,dead-code.md,specialists/*.md,
#     momentum.md (re-reviews only), critic.md} as symlinks into $RUN_DIR
#   On any fail-loud error: rm -rf "$REPO_DIR" and exit 1.
#
# Outputs (set in caller's environment):
#   AGG_EXIT — codex exit code from the aggregator pass
#   AGG_OUT  — path to the aggregator's output.md (consumer reads + posts it)
#
# Requires the following helpers already sourced in the caller's shell:
#   log, write_scratch, substitute_placeholders, build_specialist_prompt,
#   build_aggregator_prompt, critic_fallback.

run_specialist_pipeline() {
    local SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
    mkdir -p "$SPECIALISTS_DIR"

    # Every codex invocation goes through run-specialist.sh — it writes the
    # prompt, output, and codex stderr into runs/<RUN_ID>/agents/<name>/.
    # Symlinks under .codex-scratch/ keep the prompt-cited paths
    # (.codex-scratch/inferred-intent.md, .codex-scratch/specialists/<angle>.md,
    # .codex-scratch/critic.md) resolving to those outputs.
    log "$PR_ID: inferring developer intent..."
    local INTENT_PROMPT
    INTENT_PROMPT=$(substitute_placeholders \
        "$HOME/.pr-reviewer/prompts/intent.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
    "$_LIB_DIR/run-specialist.sh" "intent" "$REPO_DIR" "$INTENT_PROMPT" "$RUN_DIR/agents/intent"
    local INTENT_EXIT=$?
    local INTENT_OUT="$RUN_DIR/agents/intent/output.md"
    ln -sfn "$INTENT_OUT" "$REPO_DIR/.codex-scratch/inferred-intent.md"

    if [ "$INTENT_EXIT" -ne 0 ] || [ ! -s "$INTENT_OUT" ]; then
        log "$PR_ID: intent inference failed (codex exit=$INTENT_EXIT, output empty=$([ ! -s "$INTENT_OUT" ] && echo true || echo false)) — aborting"
        rm -rf "$REPO_DIR"
        exit 1
    fi

    local INTENT_NONBLANK_LINES
    INTENT_NONBLANK_LINES=$(grep -cv '^[[:space:]]*$' "$INTENT_OUT")
    if [ "$INTENT_NONBLANK_LINES" -ne 1 ]; then
        log "$PR_ID: intent output has $INTENT_NONBLANK_LINES non-blank lines, expected exactly 1 — aborting"
        rm -rf "$REPO_DIR"
        exit 1
    fi

    if ! grep -q '^Inferred intent: ' "$INTENT_OUT"; then
        log "$PR_ID: intent output missing 'Inferred intent: ' prefix — aborting"
        rm -rf "$REPO_DIR"
        exit 1
    fi

    log "$PR_ID: intent inference complete: $(head -1 "$INTENT_OUT")"

    # ---- dead-code-search LLM pre-pass ----
    # Reads .codex-scratch/dead-code-static.md (raw static-tool output) +
    # diff.patch and writes structured evidence to .codex-scratch/dead-code.md
    # for the `consumers` specialist to file findings from. Same pattern as
    # the intent pre-pass above: synchronous, sequential, non-fatal on
    # failure (degrades to empty evidence; consumers specialist falls back
    # to its degraded LLM-grep mode).
    log "$PR_ID: dead-code search..."
    local DC_PROMPT
    DC_PROMPT=$(substitute_placeholders \
        "$HOME/.pr-reviewer/prompts/dead-code-search.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
    "$_LIB_DIR/run-specialist.sh" "dead-code-search" "$REPO_DIR" "$DC_PROMPT" "$RUN_DIR/agents/dead-code-search"
    local DC_EXIT=$?
    local DC_OUT="$RUN_DIR/agents/dead-code-search/output.md"
    if [ "$DC_EXIT" -eq 0 ] && [ -s "$DC_OUT" ]; then
        ln -sfn "$DC_OUT" "$REPO_DIR/.codex-scratch/dead-code.md"
        log "$PR_ID: dead-code search complete ($(wc -l < "$DC_OUT") line(s) of evidence)"
    else
        log "$PR_ID: dead-code search failed (exit $DC_EXIT, empty=$([ ! -s "$DC_OUT" ] && echo true || echo false)) — consumers specialist falls back to degraded LLM-grep mode"
        : > "$REPO_DIR/.codex-scratch/dead-code.md"
    fi

    local ANGLES=(security data-integrity architecture simplification tests shape performance consumers)

    log "$PR_ID: launching ${#ANGLES[@]} specialists in parallel..."
    declare -A AGENT_PIDS=()
    local angle PROMPT
    for angle in "${ANGLES[@]}"; do
        PROMPT=$(build_specialist_prompt \
            "$angle" \
            "$HOME/.pr-reviewer/prompts/${angle}.md" \
            "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
        "$_LIB_DIR/run-specialist.sh" \
            "$angle" \
            "$REPO_DIR" \
            "$PROMPT" \
            "$RUN_DIR/agents/$angle" &
        AGENT_PIDS["$angle"]=$!
    done

    # Per-PID wait so a non-zero exit from run-specialist.sh (codex error or
    # empty output) actually surfaces as a worker abort — bare `wait` returns 0
    # even when individual children failed, so a partial codex output could
    # otherwise slip through the empty-file check and reach the aggregator.
    # Symlink + summary-log are folded into the same pass: an angle's output.md
    # is final by the time its wait returns, and the critic/aggregator only
    # read the symlinks after this whole block completes.
    local SPECIALIST_FAILURE=0 LINES NO_FINDINGS
    for angle in "${ANGLES[@]}"; do
        if ! wait "${AGENT_PIDS[$angle]}"; then
            log "$PR_ID: specialist $angle exited non-zero (see $RUN_DIR/agents/$angle/log.txt)"
            SPECIALIST_FAILURE=1
            continue
        fi
        ln -sfn "$RUN_DIR/agents/$angle/output.md" "$SPECIALISTS_DIR/${angle}.md"
        LINES=$(wc -l < "$SPECIALISTS_DIR/${angle}.md")
        NO_FINDINGS=""
        grep -q '^No findings\.' "$SPECIALISTS_DIR/${angle}.md" && NO_FINDINGS=" (no findings)"
        log "$PR_ID: specialist=$angle lines=$LINES$NO_FINDINGS"
    done
    if [ "$SPECIALIST_FAILURE" -ne 0 ]; then
        log "$PR_ID: at least one specialist failed — aborting review"
        rm -rf "$REPO_DIR"
        exit 1
    fi
    log "$PR_ID: all ${#ANGLES[@]} specialists completed"

    # Momentum specialist — runs only on re-reviews. Outputs prose-only
    # trajectory meta-finding for the aggregator's loop-breaker (Path 2).
    # Skipped on first reviews (where the aggregator handles absence by
    # design); on re-reviews failure is fail-loud — see the abort below.
    if [ -s "$RUN_DIR/inputs/previous-review.md" ]; then
        log "$PR_ID: launching momentum specialist (re-review)..."
        local MOMENTUM_PROMPT
        MOMENTUM_PROMPT=$(substitute_placeholders \
            "$HOME/.pr-reviewer/prompts/momentum.md" \
            "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
        "$_LIB_DIR/run-specialist.sh" "momentum" "$REPO_DIR" "$MOMENTUM_PROMPT" "$RUN_DIR/agents/momentum"
        local MOMENTUM_EXIT=$?
        if [ $MOMENTUM_EXIT -ne 0 ]; then
            # Fail-fast > graceful degradation. Path 2 of the aggregator's
            # loop-breaker depends on this output; an absent momentum.md
            # silently demotes Path 2 to "no structural callout," which is
            # wrong output on exactly the re-reviews where the callout
            # matters most. Mirror the existing fail-loud abort pattern
            # (see knightwatch-config error arms above).
            log "$PR_ID: momentum specialist failed (exit $MOMENTUM_EXIT) — aborting review (Path 2 needs this output; silent degrade would produce wrong loop-breaker behavior)"
            rm -rf "$REPO_DIR"
            exit 1
        fi
        local MOMENTUM_OUT="$RUN_DIR/agents/momentum/output.md"
        ln -sfn "$MOMENTUM_OUT" "$REPO_DIR/.codex-scratch/momentum.md"
    else
        log "$PR_ID: skipping momentum specialist (first review)"
    fi

    log "$PR_ID: critic pass..."
    local CRITIC_PROMPT
    CRITIC_PROMPT=$(cat "$HOME/.pr-reviewer/prompts/critic.md")
    "$_LIB_DIR/run-specialist.sh" "critic" "$REPO_DIR" "$CRITIC_PROMPT" "$RUN_DIR/agents/critic"
    local CRITIC_EXIT=$?
    local CRITIC_OUT="$RUN_DIR/agents/critic/output.md"

    # Log the failure mode for the run.log narrative; critic_fallback in
    # lib/agent-fallback.sh handles the actual file substitution and is the
    # regression-fenced path (see lib/tests/critic-fallback-smoke.sh).
    # Empty-output is reported as exit 3 by run-specialist.sh, so it lands
    # here as a non-zero CRITIC_EXIT — there's no separate elif branch.
    if [ "$CRITIC_EXIT" -ne 0 ]; then
        log "$PR_ID: critic exited $CRITIC_EXIT — discarding any partial/empty output, falling back to placeholder (see agents/critic/log.txt)"
    fi
    critic_fallback "$CRITIC_EXIT" "$CRITIC_OUT"
    ln -sfn "$CRITIC_OUT" "$REPO_DIR/.codex-scratch/critic.md"

    log "$PR_ID: aggregator (with critic input)..."
    # build_aggregator_prompt stitches in prompts/voice.md (operator-tunable
    # voice + tone) at aggregator.md's INSERT_VOICE_HERE marker, then
    # substitutes placeholders. The aggregator is NOT a specialist — must
    # not inherit the specialist common-header which would demand the
    # Surveyed/Finding-N output shape — so it gets its own build path.
    local AGG_PROMPT
    if ! AGG_PROMPT=$(build_aggregator_prompt "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR"); then
        log "$PR_ID: build_aggregator_prompt failed — aborting (incomplete install or stitch-contract regression)"
        rm -rf "$REPO_DIR"
        exit 1
    fi
    "$_LIB_DIR/run-specialist.sh" "aggregator" "$REPO_DIR" "$AGG_PROMPT" "$RUN_DIR/agents/aggregator"
    # AGG_EXIT and AGG_OUT are caller-visible (no `local`) — the caller
    # gates on these to decide whether to post the review.
    AGG_EXIT=$?
    AGG_OUT="$RUN_DIR/agents/aggregator/output.md"
}
