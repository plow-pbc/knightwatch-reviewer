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
# Usage: call `gh` normally — sourcing this file makes every call go through
#        gh_retry below. `command gh` reaches the binary un-intercepted;
#        gh_note_rate_limit's probe uses `timeout <n> gh api rate_limit`, which
#        execs the binary too and additionally bounds it.
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
    # Short-circuit while the pause is active. The per-loop gates stop a producer
    # at its next queue boundary, but work already inside a boundary (an inner
    # loop, a helper that makes several calls) still reached the wire — so the
    # tick that TRIPPED the limit kept feeding it. Refusing here makes "stop
    # calling" a property of the seam rather than of remembering to gate, and
    # callers get the same non-zero a throttled call would have returned.
    # gh_note_rate_limit's own `gh api rate_limit` probe is a bare gh call, so it
    # is unaffected and classification still works.
    gh_pause_active && return 1
    local attempt=1 max="${GH_API_RETRY_MAX:-3}" base="${GH_API_RETRY_DELAY:-2}"
    local errfile out rc
    errfile=$(mktemp)
    while :; do
        if out=$(command gh "$@" 2>"$errfile"); then
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
        # Never retry a call that CREATES something. Widening this wrapper from
        # `gh api` to any gh argv made every non-idempotent subcommand retryable,
        # with nothing but remembering GH_API_RETRY_MAX=1 standing between a
        # transient blip and a duplicate public comment. A 5xx/reset can follow a
        # request the server already applied, so retrying a create double-posts.
        # This refuses the RETRY, not the call: the rate-limit branch above has
        # already run, so a throttled write still stamps the pause.
        # Two argv shapes, because the repo writes both ways: the subcommand form
        # (`gh pr comment`) and — at two of the three create sites, via the api
        # shim — `gh api <path> --method POST`. Matching only the first two words
        # would leave the form most likely to grow a new caller unprotected while
        # reading as covered. PATCH/DELETE stay retryable: both existing uses
        # address an existing comment id, so a repeat is idempotent.
        if grep -qE '^(pr (comment|create|review)|issue (comment|create)|release create)$' <<<"$1 $2" \
           || grep -qE -- '(--method[ =]|-X[ =]?)(POST|PUT)' <<<"$*"; then
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

# THE seam. Defining `gh` as a function makes every call site in every script
# that sources this file routed by construction — no per-call-site edits, no
# allowlist, no test that greps for stragglers. That whole class of finding
# ("this call bypasses the wrapper") disappears: there is nothing left to bypass.
# `command gh` above is what keeps it from recursing into itself;
# gh_note_rate_limit's probe gets the same effect from `timeout … gh`, which
# execs the binary rather than re-entering this function.
gh() { gh_retry "$@"; }
