#!/usr/bin/env bash
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

# `dispatch_agent NAME`: build the prompt for NAME (using the right builder
# for its contract) and run it through run-specialist.sh. Reads $REPO_DIR,
# $RUN_DIR, $PR_ID/$PR_TITLE/$PR_URL/$PR_AUTHOR, $_LIB_DIR from the
# enclosing scope. Returns the underlying run-specialist exit code, or
# build_aggregator_prompt's non-zero exit if the aggregator stitch fails
# pre-codex (caller's existing AGG_EXIT/AGG_OUT gate handles both).
# `persist_layered_specialists SPECIALISTS_DIR RUN_DIR ANGLE1 [ANGLE2 ...]`
# Mirrors each layered specialist file (specialist + critic + optional
# go-deep) from the workdir-resident `.codex-scratch/specialists/<angle>.md`
# into `RUN_DIR/agents/<angle>/layered.md`. The workdir is rm -rf'd at the
# end of review-one-pr.sh; this copy is the operator-inspection artifact
# the spec promises. Sourceable so the smoke can drive it directly with
# fixture files (round-5/round-7 regression coverage).
persist_layered_specialists() {
    local specialists_dir="$1" run_dir="$2"
    shift 2
    local angle
    for angle in "$@"; do
        if [ -e "$specialists_dir/${angle}.md" ]; then
            mkdir -p "$run_dir/agents/${angle}"
            cp "$specialists_dir/${angle}.md" "$run_dir/agents/${angle}/layered.md"
        fi
    done
}

dispatch_agent() {
    local name="$1"
    local file="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/${name}.md"
    local prompt
    case "$name" in
        intent|dead-code-search|momentum)
            prompt=$(substitute_placeholders "$file" "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR") ;;
        go-deep-*)
            # Up to 3 instances per review, all sharing prompts/go-deep.md
            # but each pinned to a different specialist file via the
            # SPECIALIST_NAME placeholder. The output dir uses the full
            # prefixed name to avoid races. substitute_placeholders (not
            # build_specialist_prompt) — go-deep's contract conflicts with
            # the specialist common-header, same way intent / momentum do.
            local angle="${name#go-deep-}"
            prompt=$(substitute_placeholders \
                "${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/go-deep.md" \
                "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR" "$angle") ;;
        critic)
            prompt=$(cat "$file") ;;
        aggregator)
            prompt=$(build_aggregator_prompt "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR") || return $? ;;
        *)
            prompt=$(build_specialist_prompt "$name" "$file" "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR") ;;
    esac
    "$_LIB_DIR/run-specialist.sh" "$name" "$REPO_DIR" "$prompt" "$RUN_DIR/agents/$name"
}

run_specialist_pipeline() {
    local SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
    mkdir -p "$SPECIALISTS_DIR"

    # Every codex invocation goes through run-specialist.sh — it writes the
    # prompt, output, and codex stderr into runs/<RUN_ID>/agents/<name>/.
    # Symlinks under .codex-scratch/ keep the prompt-cited paths
    # (.codex-scratch/inferred-intent.md, .codex-scratch/specialists/<angle>.md,
    # .codex-scratch/critic.md) resolving to those outputs.
    log "$PR_ID: inferring developer intent..."
    dispatch_agent intent
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
    dispatch_agent dead-code-search
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
    local angle
    for angle in "${ANGLES[@]}"; do
        dispatch_agent "$angle" &
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
        dispatch_agent momentum
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
    dispatch_agent critic
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

    # Split the critic's per-finding output by [<angle>] section and append
    # each section to the corresponding specialists/<angle>.md, so the
    # aggregator + go-deep tech-leads see one layered file per specialist
    # (specialist findings → critic counter-arguments). Single writer per
    # phase per file — no race. Fail-soft (logs per-angle warnings; never
    # aborts — the aggregator can still read critic.md directly).
    log "$PR_ID: splitting critic output into specialist files..."
    split_critic_to_specialists "$CRITIC_OUT" "$SPECIALISTS_DIR" 2>>"$LOG_FILE" || true

    # ---- go-deep tech-leads (Phase 2) ----
    # Hot specialist files = those whose layered file contains a critic-
    # emitted "Calibration questions for go-deep" block (only emitted for
    # ≥20 LOC remedies). Cap parallel fan-out at 3, biased by severity
    # band ([blocking] > [medium] > [low] > [nit]). Each go-deep instance
    # writes to RUN_DIR/agents/go-deep-<angle>/output.md; orchestrator
    # appends to specialists/<angle>.md after wait. Auto-scales to 0 on
    # simple PRs: empty hot-list → no go-deep runs. Selection logic lives
    # in lib/go-deep-rank.sh (sourceable seam, behavior-tested).
    declare -a HOT_ANGLES=()
    mapfile -t HOT_ANGLES < <(rank_hot_angles "$SPECIALISTS_DIR" "${ANGLES[@]}")

    if [ "${#HOT_ANGLES[@]}" -eq 0 ]; then
        log "$PR_ID: no findings ≥20 LOC remedy — skipping go-deep tech-leads"
    else
        log "$PR_ID: launching ${#HOT_ANGLES[@]} go-deep tech-lead(s): ${HOT_ANGLES[*]}"
        declare -A GD_PIDS=()
        for angle in "${HOT_ANGLES[@]}"; do
            dispatch_agent "go-deep-$angle" &
            GD_PIDS["$angle"]=$!
        done
        local GD_FAILURE=0
        for angle in "${HOT_ANGLES[@]}"; do
            if ! wait "${GD_PIDS[$angle]}"; then
                log "$PR_ID: go-deep-$angle exited non-zero (see $RUN_DIR/agents/go-deep-$angle/log.txt)"
                GD_FAILURE=1
            fi
        done
        if [ "$GD_FAILURE" -ne 0 ]; then
            # Fail-fast > graceful degradation. The hot-list selection
            # means at least one ≥20 LOC remedy finding exists — exactly
            # the population go-deep is meant to investigate. Silently
            # degrading to specialist+critic output would publish the
            # high-cost findings without the calibration the operator
            # selected go-deep to provide. Mirror the momentum specialist's
            # fail-loud abort pattern above.
            log "$PR_ID: at least one go-deep tech-lead failed — aborting review (high-LOC findings need go-deep calibration; silent degrade would publish wrong recommendations)"
            rm -rf "$REPO_DIR"
            exit 1
        fi
        local GD_OUT
        for angle in "${HOT_ANGLES[@]}"; do
            GD_OUT="$RUN_DIR/agents/go-deep-$angle/output.md"
            if [ -s "$GD_OUT" ]; then
                {
                    printf '\n---\n\n## Go-deep tech-lead investigation\n\n'
                    cat "$GD_OUT"
                } >> "$SPECIALISTS_DIR/${angle}.md"
            fi
        done
        log "$PR_ID: go-deep tech-leads complete"
    fi

    persist_layered_specialists "$SPECIALISTS_DIR" "$RUN_DIR" "${ANGLES[@]}"

    log "$PR_ID: aggregator (with critic input)..."
    # The aggregator's prompt build (stitching in prompts/voice.md at
    # aggregator.md's INSERT_VOICE_HERE marker) can fail pre-codex on
    # missing voice.md or stitch-contract regression — dispatch_agent
    # propagates that as a non-zero return, and the AGG_EXIT/AGG_OUT
    # gate in the caller treats it the same as any other aggregator
    # failure (build_aggregator_prompt's own stderr message names the
    # specific cause). AGG_EXIT and AGG_OUT are caller-visible (no
    # `local`) — the caller gates on these to decide whether to post.
    dispatch_agent aggregator
    AGG_EXIT=$?
    AGG_OUT="$RUN_DIR/agents/aggregator/output.md"
}
