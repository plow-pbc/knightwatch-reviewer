#!/bin/bash
# Refresh ~/Hacking/plow-kid mirror and re-index for kid semantic search.
# Runs hourly via cron. No-op when origin/main has no new commits.

set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

PROJECT="$HOME/Hacking/plow-kid"
LOG="$HOME/.pr-reviewer/plow-kid-refresh.log"
LOCK="/tmp/plow-kid-refresh.lock"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -e "$LOCK" ]; then
    log "refresh already running (lock $LOCK present) — skipping"
    exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

cd "$PROJECT" || { log "project dir missing: $PROJECT"; exit 0; }

if ! git fetch origin main --quiet 2>>"$LOG"; then
    log "git fetch failed — skipping"
    exit 0
fi

LOCAL=$(git rev-parse HEAD 2>/dev/null)
REMOTE=$(git rev-parse origin/main 2>/dev/null)

if [ "$LOCAL" = "$REMOTE" ]; then
    exit 0
fi

log "new commits: ${LOCAL:0:7} → ${REMOTE:0:7}, pulling and re-indexing"
if ! git pull --ff-only --quiet 2>>"$LOG"; then
    log "git pull --ff-only failed — skipping index"
    exit 0
fi

# kid index is incremental — only changed files are re-embedded.
if kid index "$PROJECT" >> "$LOG" 2>&1; then
    log "index complete at $(git rev-parse --short HEAD)"
else
    log "kid index failed"
fi
