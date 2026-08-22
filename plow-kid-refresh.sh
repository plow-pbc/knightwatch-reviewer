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
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/plow-kid-refresh.log}"
LOCK="${LOCK:-/tmp/plow-kid-refresh.lock}"

# Tracked-repo manifest — same KID_PATHS this script's siblings use.
# The refresh iterates every entry; a repo that hasn't been indexed
# yet (no .keepitdry dir) gets a bootstrap index on first run. Adding
# a repo here is a one-line edit in repos.conf.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$STATE_DIR/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
# state-io's log() writes "[timestamp] $*" to LOG_FILE and TEES it to stdout. The
# non-teeing one-liner this replaces hid every line of this run — the lock skip,
# the per-project index results, the fetch/pull failures below — from
# `journalctl -u pr-reviewer-kid-refresh`, though the unit is
# StandardOutput=journal and it runs hourly.
. "$REVIEWER_LIB_DIR/state-io.sh"

if [ -e "$LOCK" ]; then
    log "refresh already running (lock $LOCK present) — skipping"
    exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

for NAME in "${!KID_PATHS[@]}"; do
    PROJECT="${KID_PATHS[$NAME]}"

    if [ ! -d "$PROJECT/.git" ]; then
        log "$NAME: checkout missing or not a git repo ($PROJECT) — skipping"
        continue
    fi

    cd "$PROJECT" || { log "$NAME: cd $PROJECT failed"; continue; }

    # Bootstrap: no .keepitdry yet → first-time indexing. Do a full index
    # now against whatever's checked out; don't bother pulling this tick.
    if [ ! -d "$PROJECT/.keepitdry" ]; then
        log "$NAME: no index present, bootstrapping initial index (may take a while)..."
        if kid index "$PROJECT" >> "$LOG_FILE" 2>&1; then
            log "$NAME: initial index complete at $(git rev-parse --short HEAD 2>/dev/null)"
        else
            log "$NAME: initial index failed"
        fi
        continue
    fi

    if ! git fetch origin main --quiet 2>>"$LOG_FILE"; then
        log "$NAME: git fetch failed — skipping"
        continue
    fi

    LOCAL=$(git rev-parse HEAD 2>/dev/null)
    REMOTE=$(git rev-parse origin/main 2>/dev/null)

    if [ "$LOCAL" = "$REMOTE" ]; then
        continue
    fi

    log "$NAME: new commits ${LOCAL:0:7} → ${REMOTE:0:7}, pulling and re-indexing"
    if ! git pull --ff-only --quiet 2>>"$LOG_FILE"; then
        log "$NAME: git pull --ff-only failed — skipping index"
        continue
    fi

    # kid index is incremental — only changed files are re-embedded.
    if kid index "$PROJECT" >> "$LOG_FILE" 2>&1; then
        log "$NAME: index complete at $(git rev-parse --short HEAD)"
    else
        log "$NAME: kid index failed"
    fi
done
