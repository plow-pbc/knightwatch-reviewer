#!/usr/bin/env bash
# Behavior smoke for `dispatch_agent` in lib/orchestrate.sh.
#
# `dispatch_agent NAME` is the routing seam that selects the right prompt
# builder per agent contract:
#   - intent / dead-code-search / momentum → substitute_placeholders (no
#     specialist common-header — their output contracts conflict with it)
#   - critic                               → raw cat (no PR placeholders)
#   - aggregator                           → build_aggregator_prompt
#                                            (voice.md stitch + placeholders)
#   - everything else (the 8 angles)       → build_specialist_prompt
#                                            (header + body)
#
# A regression here is silent: a misrouted agent gets the wrong prompt
# (e.g. intent inheriting the specialist common-header would demand the
# Surveyed/Finding-N output shape that intent's contract conflicts with).
# The momentum-wire smoke catches the "wired at all" omission class but
# not the "wired to the wrong builder" class — which is what this fences.
#
# Stubs every external surface (the four builders, run-specialist.sh) to
# log their invocation; never calls real codex.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d -t dispatch-agent-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# --- mock environment ---
# orchestrate.sh reads from $HOME/.pr-reviewer/prompts/<name>.md. Override
# $HOME so the dispatch helper resolves the prompt-file path against our
# fixture dir (we don't need real prompt content — the stubs ignore it).
export HOME="$TMPDIR"
mkdir -p "$HOME/.pr-reviewer/prompts"
for name in intent dead-code-search momentum critic aggregator security data-integrity architecture simplification tests shape performance consumers; do
    echo "stub-prompt-for-$name" > "$HOME/.pr-reviewer/prompts/${name}.md"
done

# Fake _LIB_DIR with a run-specialist.sh stub that logs its argv. The
# stub-call log lets us assert dispatch_agent invoked it with the correct
# (name, repo_dir, prompt, agent_dir) tuple per agent.
export _LIB_DIR="$TMPDIR/lib"
mkdir -p "$_LIB_DIR"
RUN_SPECIALIST_LOG="$TMPDIR/run-specialist.log"
cat > "$_LIB_DIR/run-specialist.sh" <<STUB
#!/bin/bash
# argv: NAME REPO_DIR PROMPT AGENT_DIR
printf '%s\n' "name=\$1" "repo_dir=\$2" "prompt=\$3" "agent_dir=\$4" "---" >> "$RUN_SPECIALIST_LOG"
exit 0
STUB
chmod +x "$_LIB_DIR/run-specialist.sh"

# orchestrate.sh expects these in the enclosing shell.
export PR_ID="owner/repo#42"
export PR_TITLE="Stub PR"
export PR_URL="https://example.test/pr/42"
export PR_AUTHOR="stubuser"
export REPO_DIR="$TMPDIR/repo"
export RUN_DIR="$TMPDIR/run"
mkdir -p "$REPO_DIR" "$RUN_DIR"

# Source prompt-build.sh first so the real builder names exist; then
# override them with logging stubs. orchestrate.sh's dispatch_agent calls
# these by name from the enclosing scope, so post-source overrides win.
. "$PROJECT_ROOT/lib/prompt-build.sh"
. "$PROJECT_ROOT/lib/orchestrate.sh"

BUILDER_LOG="$TMPDIR/builder.log"
# substitute_placeholders takes $6 = specialist_name (optional) — log it
# explicitly so go-deep-* dispatch can fence the bare-angle pin: a
# regression that drops the sixth arg would substitute an empty
# {{SPECIALIST_NAME}} and the prompt would resolve
# `.codex-scratch/specialists/.md` instead of the assigned angle.
substitute_placeholders() { echo "substitute_placeholders:$1:specialist_name=${6:-}" >> "$BUILDER_LOG"; echo "PROMPT[$1]"; }
build_specialist_prompt()  { echo "build_specialist_prompt:$1:$2" >> "$BUILDER_LOG"; echo "PROMPT[$1@$2]"; }
build_aggregator_prompt()  { echo "build_aggregator_prompt" >> "$BUILDER_LOG"; echo "PROMPT[aggregator]"; }

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || {
        echo "FAIL: $label"
        echo "--- $file ---"
        cat "$file"
        exit 1
    }
}
assert_no_grep() {
    local label="$1" pattern="$2" file="$3"
    if grep -qF -- "$pattern" "$file"; then
        echo "FAIL: $label (unexpected match)"
        echo "--- $file ---"
        cat "$file"
        exit 1
    fi
}

run_one() {
    local name="$1"
    : > "$BUILDER_LOG"
    : > "$RUN_SPECIALIST_LOG"
    dispatch_agent "$name"
}

# ---- standalone (no header) — intent / dead-code-search / momentum ------
for name in intent dead-code-search momentum; do
    echo "  $name → substitute_placeholders (no header)..."
    run_one "$name"
    assert_grep "$name should call substitute_placeholders" \
        "substitute_placeholders:$HOME/.pr-reviewer/prompts/${name}.md" "$BUILDER_LOG"
    assert_no_grep "$name must NOT call build_specialist_prompt (would inherit specialist common-header)" \
        "build_specialist_prompt" "$BUILDER_LOG"
    assert_grep "$name should reach run-specialist.sh with correct name" \
        "name=$name" "$RUN_SPECIALIST_LOG"
    assert_grep "$name run-specialist.sh agent_dir should be RUN_DIR/agents/$name" \
        "agent_dir=$RUN_DIR/agents/$name" "$RUN_SPECIALIST_LOG"
done

# ---- raw cat — critic ----------------------------------------------------
echo "  critic → raw cat (no placeholder substitution, no header)..."
run_one "critic"
assert_no_grep "critic must NOT call substitute_placeholders" \
    "substitute_placeholders" "$BUILDER_LOG"
assert_no_grep "critic must NOT call build_specialist_prompt" \
    "build_specialist_prompt" "$BUILDER_LOG"
assert_grep "critic should reach run-specialist.sh" \
    "name=critic" "$RUN_SPECIALIST_LOG"
# Verify the raw prompt body reaches run-specialist (cat output passed through).
assert_grep "critic prompt should be the raw file body" \
    "prompt=stub-prompt-for-critic" "$RUN_SPECIALIST_LOG"

# ---- aggregator (voice stitch) ------------------------------------------
echo "  aggregator → build_aggregator_prompt..."
run_one "aggregator"
assert_grep "aggregator should call build_aggregator_prompt" \
    "build_aggregator_prompt" "$BUILDER_LOG"
assert_no_grep "aggregator must NOT call build_specialist_prompt" \
    "build_specialist_prompt" "$BUILDER_LOG"
assert_grep "aggregator should reach run-specialist.sh" \
    "name=aggregator" "$RUN_SPECIALIST_LOG"

# ---- specialist default — the 8 angles ---------------------------------
# Spot-check three; the case statement's `*)` branch handles all of them
# identically, so testing one specialist plus two boundary names (first +
# last in ANGLES) catches both the routing and the prompt-file resolution.
for name in security tests consumers; do
    echo "  $name → build_specialist_prompt (header + body, default branch)..."
    run_one "$name"
    assert_grep "$name should call build_specialist_prompt" \
        "build_specialist_prompt:$name:$HOME/.pr-reviewer/prompts/${name}.md" "$BUILDER_LOG"
    assert_no_grep "$name must NOT call substitute_placeholders directly (would skip header)" \
        "substitute_placeholders" "$BUILDER_LOG"
    assert_grep "$name should reach run-specialist.sh with correct name" \
        "name=$name" "$RUN_SPECIALIST_LOG"
done

# ---- go-deep-* — substitute_placeholders against prompts/go-deep.md ----
# All go-deep instances share prompts/go-deep.md but pin to a different
# specialist file via the SPECIALIST_NAME placeholder (the bare angle,
# stripped from the agent-name's go-deep- prefix). Output dir is the
# full prefixed name to avoid races between parallel instances.
echo "  go-deep-* → prompts/go-deep.md (no header), output dir per-instance..."
echo "stub-prompt-for-go-deep" > "$HOME/.pr-reviewer/prompts/go-deep.md"
run_one "go-deep-security"
assert_grep "go-deep-* should call substitute_placeholders against go-deep.md" \
    "substitute_placeholders:$HOME/.pr-reviewer/prompts/go-deep.md" "$BUILDER_LOG"
assert_no_grep "go-deep-* must NOT call build_specialist_prompt (would inherit specialist common-header)" \
    "build_specialist_prompt" "$BUILDER_LOG"
# Round-4 regression fence: the sixth arg to substitute_placeholders
# (specialist_name) MUST be the bare angle, stripped of the "go-deep-"
# prefix. A drop would substitute {{SPECIALIST_NAME}} with empty string
# and the prompt would point the tech-lead at .codex-scratch/specialists/.md
# instead of the assigned specialist file. The earlier round-1 fence on
# this dispatch only checked the prompt-file-path arg.
assert_grep "go-deep-* must pin SPECIALIST_NAME to the bare angle (not empty, not the prefixed name)" \
    "specialist_name=security" "$BUILDER_LOG"
assert_grep "go-deep-* should reach run-specialist.sh with prefixed agent name" \
    "name=go-deep-security" "$RUN_SPECIALIST_LOG"
assert_grep "go-deep-* output dir should be RUN_DIR/agents/go-deep-<angle>" \
    "agent_dir=$RUN_DIR/agents/go-deep-security" "$RUN_SPECIALIST_LOG"

# ---- aggregator failure path: build_aggregator_prompt non-zero return ---
# The aggregator stitch can fail pre-codex on missing voice.md or missing
# INSERT_VOICE_HERE marker. dispatch_agent must propagate that as a
# non-zero return WITHOUT invoking run-specialist.sh — otherwise codex
# would receive an empty prompt and the worker's AGG_EXIT/AGG_OUT gate
# would fire on the wrong cause.
echo "  aggregator build failure → propagates exit, skips run-specialist..."
build_aggregator_prompt() { echo "build_aggregator_prompt:FAIL" >> "$BUILDER_LOG"; return 7; }
: > "$BUILDER_LOG"
: > "$RUN_SPECIALIST_LOG"
dispatch_agent aggregator
EXIT=$?
if [ "$EXIT" -ne 7 ]; then
    echo "FAIL: dispatch_agent aggregator should propagate build_aggregator_prompt exit (got $EXIT, expected 7)"
    exit 1
fi
assert_grep "build_aggregator_prompt should have been called" \
    "build_aggregator_prompt:FAIL" "$BUILDER_LOG"
if [ -s "$RUN_SPECIALIST_LOG" ]; then
    echo "FAIL: run-specialist.sh must NOT be invoked when build_aggregator_prompt failed"
    cat "$RUN_SPECIALIST_LOG"
    exit 1
fi

# ---- pipeline abort: critic non-zero must skip aggregator dispatch ---
# R6 introduced fail-loud on critic non-zero (orchestrate.sh:215+). Pre-R6
# the worker fell back to an empty-critic placeholder which let
# Answer: unknown probes silently render as [open], demoting real
# blockers. Fence the abort path by stubbing dispatch_agent so every
# upstream agent succeeds, critic returns non-zero, and asserting
# (a) run_specialist_pipeline exits non-zero, (b) aggregator was never
# called.
echo "  critic non-zero → run_specialist_pipeline aborts before aggregator..."

# Stub log() since state-io.sh isn't sourced in this smoke
log() { :; }

# Override dispatch_agent at the smoke level. Each agent writes a stub
# output.md to its expected path and returns 0, except critic which
# returns non-zero.
AGGREGATOR_CALLED_FLAG="$TMPDIR/aggregator-called"
dispatch_agent() {
    local name="$1"
    mkdir -p "$RUN_DIR/agents/$name"
    case "$name" in
        intent)
            printf 'Inferred intent: stub intent line\n' > "$RUN_DIR/agents/$name/output.md"
            return 0 ;;
        dead-code-search)
            printf 'stub dead-code output\n' > "$RUN_DIR/agents/$name/output.md"
            return 0 ;;
        critic)
            return 7 ;;
        aggregator)
            : > "$AGGREGATOR_CALLED_FLAG"
            printf 'aggregator-stub\n' > "$RUN_DIR/agents/$name/output.md"
            return 0 ;;
        *)
            # 8 angles + go-deep-*: stub success
            printf '## [%s] probes\n\nNo probes.\n' "$name" > "$RUN_DIR/agents/$name/output.md"
            return 0 ;;
    esac
}

# rm -rf "$REPO_DIR" inside run_specialist_pipeline kills our tree on
# abort — wrap the call in a subshell so the smoke can recover the
# exit code without losing test state. REPO_DIR is recreated below.
mkdir -p "$REPO_DIR/.codex-scratch/specialists"
rm -f "$AGGREGATOR_CALLED_FLAG"
(
    # Empty previous-review.md → first-review path (skips momentum).
    mkdir -p "$RUN_DIR/inputs"
    : > "$RUN_DIR/inputs/previous-review.md"
    LOG_FILE=/dev/null run_specialist_pipeline
)
PIPE_EXIT=$?

if [ "$PIPE_EXIT" -eq 0 ]; then
    echo "FAIL: run_specialist_pipeline must abort on critic non-zero (got exit 0)"
    exit 1
fi
if [ -e "$AGGREGATOR_CALLED_FLAG" ]; then
    echo "FAIL: aggregator was dispatched after critic failure (must abort before)"
    exit 1
fi
echo "  OK: critic non-zero → pipeline aborts (exit $PIPE_EXIT), aggregator never reached"

echo "  PASS (4 contract groups: standalone × 3, raw critic, aggregator stitch + failure path, specialist default × 3, critic fail-loud abort)"
