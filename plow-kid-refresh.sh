#!/bin/bash
# Refresh kid indexes for all tracked review repos. Runs hourly via the
# pr-reviewer-kid-refresh.timer systemd unit. A repo is indexed iff its index
# is not already built from the checked-out commit — so a never-indexed repo
# bootstraps, a moved repo re-indexes, and a FAILED index retries next tick.
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
# Bound each repo's index so one that cannot finish doesn't take the whole
# sweep down with it. plow's full index needs well over 5 minutes (#227); the
# unit's TimeoutStartSec (3h) bounds the sweep, and the lock above makes an
# hourly fire during a long sweep a no-op.
KID_INDEX_TIMEOUT="${KID_INDEX_TIMEOUT:-1800}"

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


# A repo this host DOES hold but could not (re)index — fetch, pull, index
# failure, or an unreadable checkout — degrades every review on it with no
# other visible symptom, so those causes reach the exit status. A repo with no
# checkout at all is org-sync's condition, not this unit's; see the skip below.
# Every one of them already logs its own repo, cause and remedy, so one counter
# and one summary line carry as much as a per-cause split would.
FAILED=0

# mark_stale PROJECT REASON — write .keepitdry/.stale (atomic); cwd is PROJECT. `since` is the
# first failing sweep and survives later ones so the review header can say how
# long the index has been behind. The marker rides the same read-only mount the
# reviewer already has, so no new bind is needed for it to be seen.
#
# The mirror is a checkout of a tracked repo, so everything under it is
# author-shaped: the temp file is created exclusively (a committed
# `.stale.tmp` symlink into this unit's writable paths would otherwise be
# followed), and `indexed` is validated to a full sha (a committed multiline
# `.indexed-sha` must never reach a key=value line). The rename replaces a
# symlink at the marker path instead of following it.
write_marker() {
    local project="$1" reason="$2" marker="$1/.keepitdry/.stale"
    local indexed behind="?" since tmp
    mkdir -p "$project/.keepitdry"
    indexed=$(head -c 40 "$project/.keepitdry/.indexed-sha" 2>/dev/null)
    [[ "$indexed" =~ ^[0-9a-f]{7,40}$ ]] || indexed=never
    [ "$indexed" != never ] && behind=$(git rev-list --count "$indexed..HEAD" 2>/dev/null || echo "?")
    since=$(grep '^since=' "$marker" 2>/dev/null | cut -d= -f2-)
    [ -n "$since" ] || since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    tmp=$(mktemp "$project/.keepitdry/.stale.XXXXXX") || return 1
    printf 'reason=%s\nindexed=%s\nbehind=%s\nsince=%s\n' "$reason" "$indexed" "$behind" "$since" > "$tmp" \
        && mv -f "$tmp" "$marker"
}

mark_stale() {
    write_marker "$1" "$2"
    FAILED=$((FAILED + 1))
}

default_branch() {   # origin/HEAD's short name; main when the remote never told us
    local ref
    ref=$(git symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) && printf '%s' "${ref##refs/remotes/origin/}" || printf 'main'
}

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
        FAILED=$((FAILED + 1))   # no marker possible here: the project is the thing we can't write
        continue
    fi

    BRANCH=$(default_branch)
    if ! git fetch origin "$BRANCH" --quiet 2>>"$LOG_FILE"; then
        log "$NAME: git fetch origin $BRANCH failed — skipping"
        mark_stale "$PROJECT" fetch-failed
        continue
    fi

    LOCAL=$(git rev-parse HEAD 2>/dev/null)
    REMOTE=$(git rev-parse "origin/$BRANCH" 2>/dev/null)

    if [ "$LOCAL" != "$REMOTE" ]; then
        log "$NAME: new commits ${LOCAL:0:7} → ${REMOTE:0:7}, pulling"
        if ! git pull --ff-only --quiet 2>>"$LOG_FILE"; then
            # A mirror nobody should commit to has local commits. Never reset it
            # from a timer — name it and let the operator look.
            log "$NAME: git pull --ff-only failed — mirror diverged from origin/$BRANCH; not resetting"
            mark_stale "$PROJECT" diverged
            continue
        fi
    fi

    # Index iff the index is not already built from this exact commit.
    # Comparing against the INDEX's recorded SHA rather than the CHECKOUT's is
    # the whole fix: a failed index leaves the pull's HEAD already advanced, so
    # a checkout-SHA gate saw "nothing to do" forever after and served stale
    # prior art while exiting 0. An absent marker means never indexed, so this
    # one comparison also covers the bootstrap case.
    HEAD_SHA=$(git rev-parse HEAD 2>/dev/null)
    SHA_FILE="$PROJECT/.keepitdry/.indexed-sha"
    [ "$(cat "$SHA_FILE" 2>/dev/null)" = "$HEAD_SHA" ] && { rm -f "$PROJECT/.keepitdry/.stale"; continue; }

    # A reviewer copies the index while this runs; the marker makes that
    # review say STALE (refreshing) instead of ✅ on a half-written index.
    write_marker "$PROJECT" refreshing
    if timeout "$KID_INDEX_TIMEOUT" kid index "$PROJECT" >> "$LOG_FILE" 2>&1; then
        echo "$HEAD_SHA" > "$SHA_FILE"
        rm -f "$PROJECT/.keepitdry/.stale"
        log "$NAME: index complete at ${HEAD_SHA:0:7}"
    else
        rc=$?
        reason=index-failed; [ "$rc" -eq 124 ] && reason=index-timeout
        log "$NAME: kid index failed ($reason, budget ${KID_INDEX_TIMEOUT}s)"
        mark_stale "$PROJECT" "$reason"
    fi
done

if [ "$FAILED" -gt 0 ]; then
    log "FAILED: $FAILED repo(s) left without a fresh index — see the per-repo remedies above"
    exit 1
fi
