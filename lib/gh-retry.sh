#!/bin/bash
# Retry transient GitHub network blips around `gh api`.
#
# The bakeoff walks hundreds of commit/PR fetches per run across ~17 active
# repos; a single transient TLS-handshake / i-o timeout among them would
# otherwise tip the whole run to PARTIAL (exit 1) via fetch_failures (see
# specialist-bakeoff.sh). Real failures — 4xx, primary rate-limit, or a
# timeout that persists past the budget — fall through unretried so the
# caller's existing fail-loud accounting still fires.
#
# Usage: gh_api_retry <args…>            # exactly the args you'd pass to `gh api`
# Env:   GH_API_RETRY_MAX   (default 3)  total attempts (initial + retries)
#        GH_API_RETRY_DELAY (default 2)  base backoff seconds, ×attempt number

# Transient = the connection never cleanly completed; safe to retry. Anchored on
# the Go net/http + gh strings seen on the wire (the observed failure was
# "net/http: TLS handshake timeout"; 5xx and connection-level drops join it).
GH_API_TRANSIENT_RE='TLS handshake timeout|i/o timeout|connection reset|connection refused|unexpected EOF|: EOF|HTTP 5[0-9][0-9]'

# Rate-limit signature. NOT added to GH_API_TRANSIENT_RE: retrying in-process is
# exactly the wrong response — the fix is to stop calling fleet-wide, which
# gh_note_rate_limit does by stamping the pause review-loop.sh gates each tick.
# Both the primary and secondary limits surface as 403 with this wording; the
# classification is bucket state, not text (see gh_note_rate_limit).
GH_API_RATE_LIMIT_RE='rate limit exceeded|secondary rate limit'

# state-io.sh carries gh_note_rate_limit + the pause helpers. Acyclic: state-io
# sources nothing, and it only defines functions, so a re-source by a caller
# that already has it is a no-op.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state-io.sh"

# gh_retry takes a FULL gh argv (`pr view …`, `repo view …`, `api …`), not just
# an api path. The rate-limit pause is only as good as its coverage, and the
# hardcoded `gh api` left the highest-volume reads outside it: `gh pr view` runs
# per worker and `gh pr list` per repo, both on GraphQL — the loaded bucket — so
# a 403 there aborted the caller without ever stamping the pause, and the next
# tick walked straight back into the throttle.
gh_retry() {
    local attempt=1 max="${GH_API_RETRY_MAX:-3}" base="${GH_API_RETRY_DELAY:-2}"
    local errfile out rc
    errfile=$(mktemp)
    while :; do
        if out=$(gh "$@" 2>"$errfile"); then
            cat "$errfile" >&2          # preserve any success-time gh warnings
            printf '%s' "$out"
            rm -f "$errfile"
            return 0
        else
            rc=$?                       # capture in else: $? after a bare `fi` is 0, not gh's exit
        fi
        cat "$errfile" >&2              # surface the failure to the caller's log
        # Rate limited → diagnose + pause the fleet, then give up immediately
        # (below) rather than burning this call's remaining attempts against a
        # token GitHub has just told us to stop using.
        if grep -qiE "$GH_API_RATE_LIMIT_RE" "$errfile"; then
            # >&2 like the errfile spill above: this function's stdout is the
            # API result its callers capture (`perm=$(gh_api_retry …)`), so the
            # diagnostic must not land there. log()'s LOG_FILE tee is unaffected.
            gh_note_rate_limit >&2
            rm -f "$errfile"
            return "$rc"
        fi
        # Out of budget, or not a transient network blip → give up with real rc.
        if [ "$attempt" -ge "$max" ] || ! grep -qiE "$GH_API_TRANSIENT_RE" "$errfile"; then
            rm -f "$errfile"
            return "$rc"
        fi
        sleep "$(( base * attempt ))"
        attempt=$(( attempt + 1 ))
        : > "$errfile"
    done
}

# Back-compat shim for the many existing `gh_api_retry <path>` callers. Kept as a
# one-liner rather than rewriting every call site to `gh_retry api …` — the
# rename would touch a dozen files for no behavior change.
gh_api_retry() { gh_retry api "$@"; }
