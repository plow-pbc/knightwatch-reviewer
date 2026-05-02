#!/bin/bash
# Run one codex exec pass with read-only repo access.
#
# Args:
#   $1 NAME       — agent name (for log header)
#   $2 REPO_DIR   — absolute path to the checked-out repo (cwd for codex)
#   $3 PROMPT     — the full prompt text
#   $4 AGENT_DIR  — directory where prompt.txt, output.md, log.txt are written
#
# Side effects:
#   $AGENT_DIR/prompt.txt — the prompt text (input)
#   $AGENT_DIR/output.md  — codex's last-message output (codex -o target)
#   $AGENT_DIR/log.txt    — start/exit markers + raw codex stderr
#
# Exits 0 on success, non-zero on codex failure. Fails loud.

NAME="$1"
REPO_DIR="$2"
PROMPT="$3"
AGENT_DIR="$4"

if [ -z "$NAME" ] || [ -z "$REPO_DIR" ] || [ -z "$PROMPT" ] || [ -z "$AGENT_DIR" ]; then
    echo "run-specialist.sh: missing args (got NAME='$NAME' REPO_DIR='$REPO_DIR' AGENT_DIR='$AGENT_DIR')" >&2
    exit 2
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "run-specialist.sh: $REPO_DIR is not a git repo" >&2
    exit 2
fi

mkdir -p "$AGENT_DIR"
PROMPT_FILE="$AGENT_DIR/prompt.txt"
OUT_FILE="$AGENT_DIR/output.md"
LOG_FILE="$AGENT_DIR/log.txt"

printf '%s' "$PROMPT" > "$PROMPT_FILE"

echo "[$(date '+%H:%M:%S')] agent=$NAME starting" >> "$LOG_FILE"

# Outer sandbox is provided by the systemd unit (NoNewPrivileges, ProtectHome,
# ReadWritePaths, PrivateTmp). Codex's inner bwrap sandbox is disabled because
# Ubuntu 24.04 AppArmor restricts unprivileged userns and breaks it.
# -C: set working directory for the agent (can still read anywhere readable).
# -o: write final message to file; avoids fragile stdout parsing.
codex exec \
    -C "$REPO_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    -c model="gpt-5.5" \
    -c model_reasoning_effort=high \
    -o "$OUT_FILE" \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1
CODEX_EXIT=$?

echo "[$(date '+%H:%M:%S')] agent=$NAME exit=$CODEX_EXIT" >> "$LOG_FILE"

if [ "$CODEX_EXIT" -ne 0 ]; then
    exit "$CODEX_EXIT"
fi

if [ ! -s "$OUT_FILE" ]; then
    echo "[$(date '+%H:%M:%S')] agent=$NAME produced empty output" >> "$LOG_FILE"
    exit 3
fi

# Probe-format validation for agents that emit probe blocks (per
# prompts/probe-schema.md). Catches LLM drift on required fields and
# enum values BEFORE the malformed output reaches critic / aggregator
# (where it would silently render in the wrong band or get dropped).
# Skipped for agents whose output contract is not probe-shaped: intent
# (single-line), dead-code-search (free-form), momentum (prose),
# aggregator (final posted review), go-deep-* (legacy contract, idle
# under the probe pipeline). Critic IS validated — its "## Resolved
# probes" section is delta-only (no full probe blocks), but its
# "## Generated probes" section MUST contain valid probes; the parser
# only activates on `### Probe N` headers and so naturally validates
# only the generated-probes block.
case "$NAME" in
    security|data-integrity|architecture|simplification|tests|shape|performance|consumers|critic)
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        . "$SCRIPT_DIR/probe-parse.sh"
        if ! probe_validate < "$OUT_FILE" 2>>"$LOG_FILE"; then
            echo "[$(date '+%H:%M:%S')] agent=$NAME emitted malformed probe(s) — see log above" >> "$LOG_FILE"
            exit 4
        fi
        ;;
esac

exit 0
