#!/bin/bash
# Run one codex exec pass with read-only repo access.
#
# Args:
#   $1 NAME       — specialist name (for logs and output filename)
#   $2 REPO_DIR   — absolute path to the checked-out repo (cwd for codex)
#   $3 PROMPT     — the full prompt text
#   $4 OUT_FILE   — path where codex's last-message should be written
#   $5 LOG_FILE   — append-mode log file for progress + raw codex stderr
#
# Exits 0 on success, non-zero on codex failure. Fails loud.

NAME="$1"
REPO_DIR="$2"
PROMPT="$3"
OUT_FILE="$4"
LOG_FILE="$5"

if [ -z "$NAME" ] || [ -z "$REPO_DIR" ] || [ -z "$PROMPT" ] || [ -z "$OUT_FILE" ] || [ -z "$LOG_FILE" ]; then
    echo "run-specialist.sh: missing args (got NAME='$NAME' REPO_DIR='$REPO_DIR' OUT_FILE='$OUT_FILE' LOG_FILE='$LOG_FILE')" >&2
    exit 2
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "run-specialist.sh: $REPO_DIR is not a git repo" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUT_FILE")"

echo "[$(date '+%H:%M:%S')] specialist=$NAME starting" >> "$LOG_FILE"

# Outer sandbox is provided by the systemd unit (NoNewPrivileges, ProtectHome,
# ReadWritePaths, PrivateTmp). Codex's inner bwrap sandbox is disabled because
# Ubuntu 24.04 AppArmor restricts unprivileged userns and breaks it.
# -C: set working directory for the agent (can still read anywhere readable).
# -o: write final message to file; avoids fragile stdout parsing.
codex exec \
    -C "$REPO_DIR" \
    --dangerously-bypass-approvals-and-sandbox \
    -c model_reasoning_effort=high \
    -o "$OUT_FILE" \
    "$PROMPT" \
    >> "$LOG_FILE" 2>&1
CODEX_EXIT=$?

echo "[$(date '+%H:%M:%S')] specialist=$NAME exit=$CODEX_EXIT" >> "$LOG_FILE"

if [ "$CODEX_EXIT" -ne 0 ]; then
    exit "$CODEX_EXIT"
fi

if [ ! -s "$OUT_FILE" ]; then
    echo "[$(date '+%H:%M:%S')] specialist=$NAME produced empty output" >> "$LOG_FILE"
    exit 3
fi

exit 0
