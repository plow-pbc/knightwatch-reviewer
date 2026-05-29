#!/usr/bin/env bash
# Shared work-list queue for the enumerate-once-distribute model.
#
# One container per ENUMERATE_SECS window runs the GraphQL-heavy enumerate
# + per-PR eligibility scan (review.sh's refresh_queue) under the election
# flock and writes the eligible-PR specs here; EVERY container then consumes
# the queue, claiming PRs via the existing per-PR flock. This collapses the
# redundant N-container enumeration that exhausted the 5000/hr GraphQL quota
# to a single refresh per window while keeping N-way review parallelism.
#
# Queue file: $STATE_DIR/queue.json (on the SHARED `claims` volume) —
#   {"refreshed_at": <epoch>, "specs": [ {dispatch spec}, ... ]}
# Freshness keys off the refreshed_at FIELD (not file mtime) so it stays
# portable across GNU/BSD without stat(1)/date(1) flag divergence.
# Written atomically (tmp in $TMPDIR + mv) so a consumer never reads a
# half-written file. Depends on lib/locking.sh being sourced (flock helpers).

# queue_path STATE_DIR
queue_path() { printf '%s/queue.json' "$1"; }

# queue_needs_refresh STATE_DIR MAX_AGE_SECS NOW_EPOCH — exit 0 (needs
# refresh) if the queue is missing/unreadable or its refreshed_at is at
# least MAX_AGE_SECS old; exit 1 if still fresh.
queue_needs_refresh() {
    local f refreshed; f=$(queue_path "$1")
    [ -f "$f" ] || return 0
    refreshed=$(jq -r '.refreshed_at // 0' "$f" 2>/dev/null) || return 0
    [ "$(( $3 - refreshed ))" -ge "$2" ]
}

# write_queue STATE_DIR NOW_EPOCH SPECS_JSON — atomically write the queue.
write_queue() {
    local f tmp; f=$(queue_path "$1")
    tmp=$(mktemp "${TMPDIR:-/tmp}/queue.XXXXXX")
    if jq -n --argjson now "$2" --argjson specs "$3" \
            '{refreshed_at:$now, specs:$specs}' > "$tmp"; then
        mv -f "$tmp" "$f"
    else
        rm -f "$tmp"; return 1
    fi
}

# read_queue_specs STATE_DIR — print the specs array ([] if missing/unreadable).
read_queue_specs() {
    local f; f=$(queue_path "$1")
    [ -f "$f" ] || { echo "[]"; return 0; }
    jq -c '.specs // []' "$f" 2>/dev/null || echo "[]"
}

# acquire_enumerator_lock STATE_DIR — non-blocking flock electing the single
# refresher this window. Exit 0 if won (ENUM_LOCK_FD held until
# release_enumerator_lock or process exit), 1 if another container holds it.
acquire_enumerator_lock() {
    local d="$1/locks"; mkdir -p "$d"
    exec {ENUM_LOCK_FD}> "$d/__enumerator"
    flock -n "$ENUM_LOCK_FD"
}

release_enumerator_lock() {
    [ -n "${ENUM_LOCK_FD:-}" ] || return 0
    exec {ENUM_LOCK_FD}>&-
    unset ENUM_LOCK_FD
}

# queue_drained STATE_DIR — exit 0 if the queue HAS specs but NONE are
# currently claimable (every queued PR's per-PR flock is held = in-flight on
# some container) → the visible batch is worked through, refetch for more.
# Exit 1 if the queue is EMPTY (idle — governed by the time cadence alone, so
# idle ticks don't herd every container into re-enumerating) OR at least one
# PR is still claimable (work remains; no refetch needed yet). Probes via
# acquire_pr_lock (from lib/locking.sh) and releases immediately — a free
# probe means claimable. Depends on lib/locking.sh being sourced.
queue_drained() {
    local specs n slug; specs=$(read_queue_specs "$1")
    n=$(jq 'length' <<<"$specs"); [ "$n" -gt 0 ] || return 1
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        if acquire_pr_lock "$1" "$slug"; then release_pr_lock; return 1; fi
    done < <(jq -r '.[] | (.repo|gsub("/";"_")) + "__" + (.pr_num|tostring)' <<<"$specs")
    return 0
}
