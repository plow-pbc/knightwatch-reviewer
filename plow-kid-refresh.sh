#!/bin/bash
# Refresh kid indexes for all tracked review repos. Runs hourly via the
# pr-reviewer-kid-refresh.timer systemd unit. The PULL is gated on new commits;
# the index re-runs every tick so a failed one retries (see the seam below). If
# a project has never been indexed, this does a bootstrap index on first run.
#
# Naming note: this file is still called plow-kid-refresh.sh for historical
# reasons (it predates multi-repo support). It now refreshes every kid index
# the reviewer uses.

set -u
# PATH inherited from systemd unit (system dirs first; writable user dirs
# trailing). See review.sh for the writable-PATH security context.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG="${LOG:-$STATE_DIR/plow-kid-refresh.log}"
LOCK="${LOCK:-/tmp/plow-kid-refresh.lock}"

# Tracked-repo manifest — same KID_PATHS this script's siblings use.
# The refresh iterates every entry; a repo that hasn't been indexed
# yet (no .keepitdry dir) gets a bootstrap index on first run. Adding
# a repo here is a one-line edit in repos.conf.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$STATE_DIR/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if [ -e "$LOCK" ]; then
    log "refresh already running (lock $LOCK present) — skipping"
    exit 0
fi
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# A repo this host DOES hold but could not (re)index — fetch, pull, index
# failure, or an unreadable checkout — degrades every review on it with no
# other visible symptom, so those causes reach the exit status. A repo with no
# checkout at all is org-sync's condition, not this unit's; see the skip below.
# Every one of them already logs its own repo, cause and remedy, so one counter
# and one summary line carry as much as a per-cause split would.
FAILED=0
for NAME in "${!KID_PATHS[@]}"; do
    PROJECT="${KID_PATHS[$NAME]}"

    # Deliberately NOT tallied. A missing checkout is a documented, tolerated
    # state (see install.sh's note on the `-` prefix): a partial-org repo or a
    # kwr-config .repos[] entry is tracked for review but never cloned here, so
    # tallying it would leave the unit permanently red and bury the repo that
    # actually just went stale. A repo whose mirror fails vouching doesn't reach
    # here at all — org-sync withholds it from the manifest, so it never enters
    # KID_PATHS, and that sweep exits non-zero until the mirror is fixed. One
    # owner per condition; org-sync owns "no mirror", this unit owns "no index".
    if [ ! -d "$PROJECT/.git" ]; then
        log "$NAME: checkout missing or not a git repo ($PROJECT) — skipping"
        continue
    fi

    cd "$PROJECT" || { log "$NAME: cd $PROJECT failed"; FAILED=$((FAILED + 1)); continue; }

    # kid writes its index to $PROJECT/.keepitdry, but this unit runs under
    # ProtectHome=read-only with a per-repo ReadWritePaths allowlist that
    # install.sh renders from repos.conf AT INSTALL TIME. org-sync grows the
    # tracked set hourly, so a repo discovered since the last install is
    # outside the sandbox and can never be indexed. Probe for that here:
    # otherwise chromadb dies deep in a bootstrap with a bare
    # "Read-only file system (os error 30)" traceback and the only log line
    # is "initial index failed" — the true cause invisible, and a doomed
    # bootstrap burned from the sweep's 20min budget every hour.
    if [ ! -w "$PROJECT" ]; then
        log "$NAME: $PROJECT not writable under this unit's sandbox — outside ReadWritePaths; re-run install.sh to widen it, then this repo will index"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Bootstrap: no .keepitdry yet → first-time indexing. Do a full index
    # now against whatever's checked out; don't bother pulling this tick.
    if [ ! -d "$PROJECT/.keepitdry" ]; then
        log "$NAME: no index present, bootstrapping initial index (may take a while)..."
        if kid index "$PROJECT" >> "$LOG" 2>&1; then
            log "$NAME: initial index complete at $(git rev-parse --short HEAD 2>/dev/null)"
        else
            log "$NAME: initial index failed"
            FAILED=$((FAILED + 1))
        fi
        continue
    fi

    if ! git fetch origin main --quiet 2>>"$LOG"; then
        log "$NAME: git fetch failed — skipping"
        FAILED=$((FAILED + 1))
        continue
    fi

    LOCAL=$(git rev-parse HEAD 2>/dev/null)
    REMOTE=$(git rev-parse origin/main 2>/dev/null)

    # Only the PULL is gated on new commits.
    if [ "$LOCAL" != "$REMOTE" ]; then
        log "$NAME: new commits ${LOCAL:0:7} → ${REMOTE:0:7}, pulling and re-indexing"
        if ! git pull --ff-only --quiet 2>>"$LOG"; then
            log "$NAME: git pull --ff-only failed — skipping index"
            FAILED=$((FAILED + 1))
            continue
        fi
    fi

    # The index is NOT gated on new commits. A failed index leaves HEAD already
    # advanced by the pull, so gating here would strand that repo stale until
    # some unrelated commit lands — reporting success every tick in between.
    # kid index is incremental: measured in this unit's own environment, a
    # fully-indexed repo re-runs in ~0.7s, flat from 7 to 153 files (~1min
    # across the tracked set), so retrying is cheaper than tracking which SHA
    # last indexed cleanly.
    #
    # kid's own chatter goes to a temp file, not straight to $LOG: on an
    # unchanged tick it prints a "Skipped N unchanged files" line, and at one
    # per repo per tick that would bury the per-repo remedies the final summary
    # points at — in a log nothing rotates. Keep it only when it says something
    # ($LOG-worthy): a failure, or a tick that actually pulled.
    KID_OUT=$(mktemp)
    if kid index "$PROJECT" > "$KID_OUT" 2>&1; then
        if [ "$LOCAL" != "$REMOTE" ]; then
            cat "$KID_OUT" >> "$LOG"
            log "$NAME: index complete at $(git rev-parse --short HEAD)"
        fi
    else
        cat "$KID_OUT" >> "$LOG"
        log "$NAME: kid index failed"
        FAILED=$((FAILED + 1))
    fi
    rm -f "$KID_OUT"
done

if [ "$FAILED" -gt 0 ]; then
    log "FAILED: $FAILED repo(s) left without a fresh index — see the per-repo remedies above"
    exit 1
fi
