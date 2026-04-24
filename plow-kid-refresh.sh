#!/bin/bash
# Refresh kid indexes for all tracked review repos. Runs hourly via the
# pr-reviewer-kid-refresh.timer systemd unit. No-op per-project when
# origin/main has no new commits. If a project has never been indexed,
# this does a bootstrap index on first run.
#
# Naming note: this file is still called plow-kid-refresh.sh for historical
# reasons (it predates multi-repo support). It now refreshes every kid index
# the reviewer uses.

set -u
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

LOG="$HOME/.pr-reviewer/plow-kid-refresh.log"
LOCK="/tmp/plow-kid-refresh.lock"

# Map project label → local checkout path. Label is logging-only; the path
# is what kid indexes. Plow uses a dedicated mirror under plow-kid; tkmx
# repos are indexed in place.
PROJECTS=(
    "plow:$HOME/Hacking/plow-kid"
    "tkmx-client:$HOME/Hacking/tkmx-client"
    "tkmx-server:$HOME/Hacking/tkmx-server"
    "knightwatch-reviewer:$HOME/Hacking/knightwatch-reviewer"
)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -e "$LOCK" ]; then
    log "refresh already running (lock $LOCK present) — skipping"
    exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

for entry in "${PROJECTS[@]}"; do
    NAME="${entry%%:*}"
    PROJECT="${entry#*:}"

    if [ ! -d "$PROJECT/.git" ]; then
        log "$NAME: checkout missing or not a git repo ($PROJECT) — skipping"
        continue
    fi

    cd "$PROJECT" || { log "$NAME: cd $PROJECT failed"; continue; }

    # Bootstrap: no .keepitdry yet → first-time indexing. Do a full index
    # now against whatever's checked out; don't bother pulling this tick.
    if [ ! -d "$PROJECT/.keepitdry" ]; then
        log "$NAME: no index present, bootstrapping initial index (may take a while)..."
        if kid index "$PROJECT" >> "$LOG" 2>&1; then
            log "$NAME: initial index complete at $(git rev-parse --short HEAD 2>/dev/null)"
        else
            log "$NAME: initial index failed"
        fi
        continue
    fi

    if ! git fetch origin main --quiet 2>>"$LOG"; then
        log "$NAME: git fetch failed — skipping"
        continue
    fi

    LOCAL=$(git rev-parse HEAD 2>/dev/null)
    REMOTE=$(git rev-parse origin/main 2>/dev/null)

    if [ "$LOCAL" = "$REMOTE" ]; then
        continue
    fi

    log "$NAME: new commits ${LOCAL:0:7} → ${REMOTE:0:7}, pulling and re-indexing"
    if ! git pull --ff-only --quiet 2>>"$LOG"; then
        log "$NAME: git pull --ff-only failed — skipping index"
        continue
    fi

    # kid index is incremental — only changed files are re-embedded.
    if kid index "$PROJECT" >> "$LOG" 2>&1; then
        log "$NAME: index complete at $(git rev-parse --short HEAD)"
    else
        log "$NAME: kid index failed"
    fi
done
