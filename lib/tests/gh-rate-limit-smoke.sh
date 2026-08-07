#!/usr/bin/env bash
# Smoke test for the GitHub rate-limit backoff protocol (lib/state-io.sh +
# lib/gh-retry.sh + review-loop.sh's third tick gate).
#
# Context: the fleet had NO GitHub rate-limit backoff. A rate-limit 403 fell
# through gh api as an ordinary hard failure, so every container
# re-attempted against the same throttled shared PAT on the next POLL_SECS tick
# — a transient limit became a two-day retry storm (2,179 deferrals on one unit).
#
# The load-bearing behaviors, in the order they matter:
#   1. A rate-limit 403 stamps a pause (it no longer passes silently).
#   2. Primary vs secondary are told apart by live bucket state, not by the 403
#      text — GitHub words both identically. Primary waits for the real reset;
#      secondary (invisible to /rate_limit) waits a short fixed window.
#   3. The pause is FLEET-WIDE, not per-account. One shared PAT means a
#      per-WORKER_ID pause would leave the other containers hammering.
#   4. A non-rate-limit failure must NOT pause — that would take the fleet down
#      on any ordinary 404/422.
#
# Runs in a private tmpdir with a shimmed `gh`; touches no real API and no
# ~/.pr-reviewer.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d -t gh-rate-limit-smoke-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

export STATE_DIR="$TMP/shared"
mkdir -p "$STATE_DIR" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

# `gh` shim. GH_SHIM_BUCKETS is the TSV /rate_limit answer; GH_SHIM_ERR is the
# stderr text of the failing call. Any non-rate_limit invocation fails.
cat > "$TMP/bin/gh" <<'SHIM'
#!/usr/bin/env bash
[ -n "${GH_SHIM_CALL_LOG:-}" ] && echo "$*" >> "$GH_SHIM_CALL_LOG"
for a in "$@"; do
    if [ "$a" = "rate_limit" ]; then
        [ -n "${GH_SHIM_PROBE_LOG:-}" ] && echo probe >> "$GH_SHIM_PROBE_LOG"
        [ -n "${GH_SHIM_BUCKETS:-}" ] || exit 1
        printf '%s\n' "$GH_SHIM_BUCKETS"
        exit 0
    fi
done
printf '%s\n' "${GH_SHIM_ERR:-gh: some other failure (HTTP 404)}" >&2
exit 1
SHIM
chmod +x "$TMP/bin/gh"

. "$PROJECT_ROOT/lib/gh-retry.sh"   # sources state-io.sh itself

RATE_LIMIT_ERR='gh: API rate limit exceeded for user ID 95421. (HTTP 403)'
NOW=$(date +%s)

reset_state() { rm -f "$(gh_pause_file)"; }

# --- 1. secondary: budget remains, yet a rate-limit 403 → short fixed pause ---
# This is the case that actually fired in production: core 4920/5000 and graphql
# 4742/5000 remaining while every call 403'd. /rate_limit cannot see secondary
# limits, so "403 with budget left" IS the secondary signal.
echo "  scenario 1: rate-limit 403 with budget remaining → secondary, short pause..."
reset_state
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
GH_SECONDARY_PAUSE_SECS=60 \
    gh api "user" >"$TMP/out1" 2>"$TMP/err1" || true
[ -f "$(gh_pause_file)" ] || fail "scenario 1: rate-limit 403 left no pause file — the fleet would keep hammering"
# gh_api_retry's stdout IS the API result its callers capture
# (`perm=$(gh api …)` in auth.sh) — a diagnostic leaked there would be
# read back as a permission string.
grep -q 'rate limit' "$TMP/out1" 2>/dev/null \
    && fail "scenario 1: the diagnostic leaked to stdout, corrupting the value callers capture"
UNTIL=$(head -n1 "$(gh_pause_file)")
DELTA=$(( UNTIL - NOW ))
[ "$DELTA" -ge 55 ] && [ "$DELTA" -le 75 ] \
    || fail "scenario 1: expected a ~60s secondary window, got ${DELTA}s (until=$UNTIL now=$NOW)"
grep -q 'secondary' "$TMP/err1" \
    || fail "scenario 1: diagnostic did not classify the limit as secondary — output: $(cat "$TMP/err1")"

# --- 2. primary/core exhausted → pause until the bucket's OWN reset ---
echo "  scenario 2: core remaining=0 → primary, pause until the real reset epoch..."
reset_state
CORE_RESET=$((NOW + 1800))
GH_SHIM_BUCKETS="0	$CORE_RESET	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "user" >/dev/null 2>"$TMP/err2" || true
[ "$(head -n1 "$(gh_pause_file)")" = "$CORE_RESET" ] \
    || fail "scenario 2: expected pause until core reset $CORE_RESET, got $(head -n1 "$(gh_pause_file)")"
grep -q 'primary/core' "$TMP/err2" \
    || fail "scenario 2: diagnostic did not classify as primary/core — output: $(cat "$TMP/err2")"

# --- 3. graphql is the exhausted bucket → its reset wins ---
# GraphQL is the loaded bucket in this deployment (~30 pts/min vs core ~0), so
# misreading a graphql exhaustion as core would resume at the wrong time.
echo "  scenario 3: graphql remaining=0 → primary/graphql, graphql's reset..."
reset_state
GQL_RESET=$((NOW + 2400))
GH_SHIM_BUCKETS="4920	$((NOW + 600))	0	$GQL_RESET" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "graphql" >/dev/null 2>"$TMP/err3" || true
[ "$(head -n1 "$(gh_pause_file)")" = "$GQL_RESET" ] \
    || fail "scenario 3: expected pause until graphql reset $GQL_RESET, got $(head -n1 "$(gh_pause_file)")"

# --- 4. an ordinary failure must NOT pause the fleet ---
echo "  scenario 4: non-rate-limit failure → no pause..."
reset_state
GH_SHIM_ERR='gh: Not Found (HTTP 404)' \
    gh api "repos/o/r/collaborators/u/permission" >/dev/null 2>&1 || true
[ ! -f "$(gh_pause_file)" ] \
    || fail "scenario 4: a 404 stamped a fleet pause — any missing collaborator would halt reviewing"

# --- 5. a stale reset epoch must not resume instantly ---
echo "  scenario 5: already-passed reset epoch → floored to a real window..."
reset_state
GH_SHIM_BUCKETS="0	$((NOW - 500))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
GH_SECONDARY_PAUSE_SECS=60 \
    gh api "user" >/dev/null 2>&1 || true
[ "$(head -n1 "$(gh_pause_file)")" -gt "$NOW" ] \
    || fail "scenario 5: a past reset epoch produced a non-future pause — would re-trip every tick"

# --- 6. gh_pause_active window semantics (what the tick gate reads) ---
echo "  scenario 6: gh_pause_active true inside the window, false after..."
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$(gh_pause_file)"
gh_pause_active || fail "scenario 6: gh_pause_active false inside an open window"
printf '%s\n' "$(( $(date +%s) - 1 ))" > "$(gh_pause_file)"
! gh_pause_active || fail "scenario 6: gh_pause_active still true after the window passed"
reset_state
! gh_pause_active || fail "scenario 6: gh_pause_active true with no pause file"

# --- 7. fleet-wide, not per-account ---
# The whole point: all containers share one PAT. If this file were namespaced
# under pool/<WORKER_ID>/ the container that noticed would pause alone.
echo "  scenario 7: pause file is fleet-wide (not under pool/<WORKER_ID>/)..."
case "$(WORKER_ID=3 gh_pause_file)" in
    */pool/*) fail "scenario 7: gh_pause_file is namespaced per account — siblings would keep hammering the shared token" ;;
esac
[ "$(WORKER_ID=3 gh_pause_file)" = "$(WORKER_ID=5 gh_pause_file)" ] \
    || fail "scenario 7: gh_pause_file differs by WORKER_ID — the pause is not fleet-wide"

# --- 8. every entrypoint that can STAMP a pause must also HONOR it ---
# The recurring defect class: routing a call site through the gh wrapper silently
# makes its entrypoint a PRODUCER of the fleet pause, and one that produces but
# never reads it keeps hammering the token it just told the others to back off
# from. That is a real bug class (it shipped once, in specialist-bakeoff.sh), but
# a static list is the right weight for it — the derived version this replaces
# parsed systemd units and walked the source graph for ~125 LOC and still could
# not see the direct-`gh` bypass that a later review caught by reading the code.
# Every entrypoint that reaches the wrapper belongs here.
echo "  scenario 8: every pause-producing entrypoint gates on gh_pause_active..."
for entry in review-loop.sh poll-pr-actions.sh learn-from-replies.sh specialist-bakeoff.sh org-sync.sh; do
    grep -q 'gh_pause_active' "$PROJECT_ROOT/$entry" \
        || fail "scenario 8: $entry can stamp a pause but never reads one — it would keep calling a throttled token"
done

# TWO gates, not one, for the three that walk a work-list. A top-of-tick check
# alone only guards the NEXT tick: once a wrapped call trips the limit mid-walk,
# the loop still visits every remaining PR/repo. Presence alone can't tell the
# two apart, so require both a column-0 gate (top-of-tick) and an indented one
# (inside the loop body). review.sh's dispatcher gate is covered behaviorally
# instead — queue-distribute-smoke F3 asserts it stops claiming after one
# dispatch; review-loop.sh is exempt because its only gate lives inside `while
# true`, so indentation can't distinguish the two there.
for entry in poll-pr-actions.sh learn-from-replies.sh specialist-bakeoff.sh; do
    grep -qE '^gh_pause_active|^if gh_pause_active' "$PROJECT_ROOT/$entry" \
        || fail "scenario 8: $entry has no top-of-tick gh_pause_active gate"
    grep -qE '^[[:space:]]+if gh_pause_active' "$PROJECT_ROOT/$entry" \
        || fail "scenario 8: $entry gates only at top-of-tick — once a mid-walk call trips the limit it keeps working the rest of the list against a throttled token"
done

# --- 9. already paused → no second probe, no window push-out ---
# The in-flight tick keeps running after the first 403, so every later failing
# call reaches gh_note_rate_limit too. Probing again would turn N failures into
# 2N requests (×6 containers) during the exact window GitHub wants quiet, and
# re-stamping would drag the window forward on every straggler.
echo "  scenario 9: already paused → probe short-circuits, window not extended..."
reset_state
export GH_SHIM_PROBE_LOG="$TMP/probes"; : > "$GH_SHIM_PROBE_LOG"
for _ in 1 2 3; do
    GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
    GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    GH_SECONDARY_PAUSE_SECS=60 \
        gh api "user" >/dev/null 2>&1 || true
done
PROBES=$(wc -l < "$GH_SHIM_PROBE_LOG")
[ "$PROBES" -eq 1 ] \
    || fail "scenario 9: $PROBES rate_limit probes across 3 rate-limited calls — expected 1 (amplifying during a throttle)"
# …and the 2nd/3rd calls never reached the wire at all. The per-loop gates stop a
# producer at its next queue boundary, but work already inside one kept calling;
# refusing at the seam is what makes "stop calling" hold without every caller
# remembering to gate.
: > "$TMP/calls"
GH_SHIM_CALL_LOG="$TMP/calls" GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "repos/o/r/pulls/7/commits" >/dev/null 2>&1 || true
[ ! -s "$TMP/calls" ] \
    || fail "scenario 9: gh_retry still called gh while the pause was active — it must short-circuit: $(cat "$TMP/calls")"
FIRST_UNTIL=$(head -n1 "$(gh_pause_file)")
sleep 1
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" GH_SECONDARY_PAUSE_SECS=60 \
    gh api "user" >/dev/null 2>&1 || true
[ "$(head -n1 "$(gh_pause_file)")" = "$FIRST_UNTIL" ] \
    || fail "scenario 9: a later straggler pushed the pause window forward"
unset GH_SHIM_PROBE_LOG

# --- 10. torn read of the shared file must read as PAUSED-safe, not error ---
# Six containers write this file; a reader can land on a truncated one. head
# succeeds with empty output, so a bare `[ N -lt "$(head …)" ]` would abort with
# "integer expression expected" — which reads as NOT paused, the worst default.
echo "  scenario 10: empty/torn pause file → no error, reads as not-paused..."
: > "$(gh_pause_file)"
if gh_pause_active 2>"$TMP/err10"; then
    fail "scenario 10: an empty pause file read as PAUSED"
fi
[ ! -s "$TMP/err10" ] \
    || fail "scenario 10: gh_pause_active errored on an empty file — $(cat "$TMP/err10")"

# --- 11. the shared pause file must never be deleted by the loop ---
# The per-account quota/auth files above it each have ONE owner, so their `rm`s
# are safe; this one has six writers and a delete would race a sibling's fresh
# stamp, resuming the whole fleet against a throttled token.
echo "  scenario 11: review-loop.sh never rm's the fleet-wide pause file..."
grep -qE '^[^#]*rm .*gh_pause_file' "$PROJECT_ROOT/review-loop.sh" \
    && fail "scenario 11: review-loop.sh deletes the shared pause file — races a sibling's stamp"

# --- 12. the seam: sourcing gh-retry.sh routes every `gh` call, by construction
# This replaces two earlier scenarios — a systemd/source-graph parser and a
# per-line allowlist — that existed to hunt call sites bypassing the wrapper.
# With `gh` itself defined as the wrapper there is nothing left to bypass, so the
# property is structural rather than asserted, and the hunt is obsolete. What
# still needs checking is much smaller: the seam exists, it does not recurse, and
# every producer entrypoint pulls it in.
echo "  scenario 12: gh() is the seam — intercepts, and does not recurse..."
: > "$TMP/calls"
reset_state
GH_SHIM_CALL_LOG="$TMP/calls" GH_SHIM_ERR='gh: Not Found (HTTP 404)' \
    gh pr view 7 --repo o/r >/dev/null 2>&1 || true
[ "$(wc -l < "$TMP/calls")" -eq 1 ] \
    || fail "scenario 12: a plain `gh pr view` made $(wc -l < "$TMP/calls") underlying calls — the seam is missing or recursing"
grep -q 'pr view 7' "$TMP/calls" \
    || fail "scenario 12: the seam did not pass argv through: $(cat "$TMP/calls")"
# A plain `gh` call must stamp the pause like any other — that IS the point.
: > "$TMP/calls"; reset_state
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" gh pr comment 7 --repo o/r --body hi >/dev/null 2>&1 || true
[ -f "$(gh_pause_file)" ] \
    || fail "scenario 12: a rate-limited plain `gh` call left no pause — the seam is not classifying"
reset_state

# The seam is structural only if the script actually SOURCES it — that is the one
# non-structural precondition, so it gets the strongest check here. Derived from
# git, not hand-listed (a list omits whatever nobody remembered — it had already
# dropped review.sh, review-one-pr.sh and replay.sh, the three biggest callers),
# and matched on a NON-COMMENT source line, since a filename mentioned in prose
# satisfied the previous grep while the real source line could be deleted.
# Which libs carry the seam, transitively. review-one-pr.sh reaches gh() only via
# `. auth.sh` -> gh-retry.sh, so a direct-source check would flag the worker — the
# repo's single biggest gh caller — while a hand-added exception for auth.sh would
# just be the same staleness one level down. Fixpoint instead: start at
# gh-retry.sh and absorb any lib that sources a carrier.
# Two views of the same set: a plain space-separated list for membership (the
# regex form can't be matched against — `auth\.sh` as a pattern never matches the
# literal `auth\.sh` stored in the accumulator, so the old dedup always missed and
# the guard below counted duplicates, making it unfailable), and the escaped
# alternation for grepping source lines.
SEAM_NAMES=" gh-retry.sh "
SEAM_CARRIERS='gh-retry\.sh'
for _ in 1 2 3 4; do
    for _lib in "$PROJECT_ROOT"/lib/*.sh; do
        _base=$(basename "$_lib")
        [[ "$SEAM_NAMES" == *" $_base "* ]] && continue
        _src=$(sed -e 's/#.*//' "$_lib")
        if grep -qE "^[[:space:]]*(\.|source)[[:space:]].*($SEAM_CARRIERS)" <<<"$_src"; then
            SEAM_NAMES="$SEAM_NAMES$_base "
            SEAM_CARRIERS="$SEAM_CARRIERS|${_base%.sh}\\.sh"
        fi
    done
done
for _need in auth.sh bootstrap.sh; do
    [[ "$SEAM_NAMES" == *" $_need "* ]] \
        || fail "scenario 12: seam-carrier closure is [$SEAM_NAMES] — $_need is missing, so the transitive resolution broke and callers reaching gh() through it would read as unseamed"
done

mapfile -t GH_CALLERS < <(cd "$PROJECT_ROOT" && git ls-files '*.sh' | grep -v '^lib/tests/' | grep -v '^lib/gh-retry.sh$')
[ "${#GH_CALLERS[@]}" -gt 10 ] \
    || fail "scenario 12: derived only ${#GH_CALLERS[@]} scripts — the git derivation broke, so this asserts nothing"
checked=0
for f in "${GH_CALLERS[@]}"; do
    [ -f "$PROJECT_ROOT/$f" ] \
        || fail "scenario 12: derived path $f does not exist — a vanished script must fail loudly"
    # Strip into variables first, then match with a herestring. NOT `sed … | grep
    # -q …`: under `set -o pipefail` grep -q exits on the first match, sed takes
    # SIGPIPE (141), and the PIPELINE reports failure even though the match
    # succeeded — a race that fires on big files whose match is early, i.e.
    # exactly review.sh. It was flaky ~1 run in 12 before this.
    # Strip the two SANCTIONED bypasses — `command gh` and `timeout <n> gh`, both
    # of which deliberately reach the binary — so a file using them falls out of
    # the detector naturally. Exempting the FILE instead (as this did for
    # state-io.sh) is worse than the entry list it replaced: it skips silently,
    # and state-io.sh is the one place a plain `gh` would RECURSE, since
    # gh_retry -> gh_note_rate_limit lives there. Now it stays audited.
    # Bypass strips run BEFORE the quote strip: `timeout "${VAR}" gh` collapses to
    # `timeout  gh` once the quoted arg is removed, and the pattern would miss it.
    # Anchored to the ONE sanctioned call. An unanchored `timeout … gh` would
    # sanction that spelling repo-wide — and it skips gh_pause_active, retry, and
    # classification, so a script whose gh calls all took that form would drop out
    # of the audit silently. `timeout` is already a common idiom here (review.sh,
    # review-one-pr.sh, run-dir.sh), so that is a plausible next spelling.
    stripped_code=$(sed -e 's/command gh/ /g' -e 's/timeout [^ ]* gh api rate_limit/ /g' \
                        -e 's/"[^"]*"//g' -e "s/'[^']*'//g" -e 's/#.*//' "$PROJECT_ROOT/$f")
    grep -qE '(^|[^[:alnum:]_.])gh[[:space:]]' <<<"$stripped_code" || continue
    case "$f" in install.sh) continue ;; esac   # pre-seam `gh --version` preflight
    checked=$((checked + 1))
    stripped_src=$(sed -e 's/#.*//' "$PROJECT_ROOT/$f")
    grep -qE "^[[:space:]]*(\.|source)[[:space:]].*($SEAM_CARRIERS)" <<<"$stripped_src" \
        || fail "scenario 12: $f calls gh but sources nothing that defines the seam — every one of those calls bypasses the pause"
done
[ "$checked" -ge 5 ] \
    || fail "scenario 12: only $checked gh-calling scripts found (expected >=5) — the call detection broke"

# And the seam must actually be DEFINED by what they source — a rename or a
# boy-scout deletion of the definition would satisfy every check above.
for lib in gh-retry.sh bootstrap.sh; do
    [ "$(cd "$PROJECT_ROOT" && REVIEWER_LIB_DIR="$PROJECT_ROOT/lib" bash -c ". lib/$lib >/dev/null 2>&1; type -t gh")" = function ] \
        || fail "scenario 12: sourcing lib/$lib does not define gh() — the seam is gone, and every caller silently talks to the real binary"
done

# --- 13. a primary classification must not be clobbered by a slower sibling ---
# Two containers hit the limit at once. A's probe classifies PRIMARY (pause to the
# bucket's real reset); B's probe fails and falls back to the 60s secondary
# window. Unserialized, B's write lands last and the fleet resumes ~59 minutes
# early into a still-exhausted bucket. The lock plus the in-lock recheck means
# whoever loses the race leaves the winner's answer alone.
echo "  scenario 13: concurrent classification — the primary pause survives..."
reset_state
CORE_RESET=$((NOW + 1800))
(
    GH_SHIM_BUCKETS="0	$CORE_RESET	4742	$((NOW + 3000))" \
    GH_SHIM_ERR="$RATE_LIMIT_ERR" gh api user >/dev/null 2>&1 || true
) &
(
    # No buckets → the probe fails → this sibling would stamp the 60s fallback.
    GH_SHIM_ERR="$RATE_LIMIT_ERR" GH_SECONDARY_PAUSE_SECS=60 \
        gh api user >/dev/null 2>&1 || true
) &
wait
GOT=$(head -n1 "$(gh_pause_file)")
[ "$GOT" = "$CORE_RESET" ] \
    || fail "scenario 13: pause is $GOT, expected the primary reset $CORE_RESET — a slower sibling's 60s fallback overwrote the real window, so the fleet resumes early"
reset_state

# --- 14. a create is never RETRIED; a read still is ---
# Deleted by accident when scenarios 12/14 were replaced — this is the only
# coverage for the create guard, and without it a retried create double-posts a
# public comment on a transient blip.
echo "  scenario 14: creates are not retried on a transient error; reads are..."
attempts() {   # $1.. = argv passed through the seam; echoes the gh invocation count
    : > "$TMP/calls"
    GH_SHIM_CALL_LOG="$TMP/calls" GH_SHIM_ERR='net/http: TLS handshake timeout' \
    GH_API_RETRY_DELAY=0 gh "$@" >/dev/null 2>&1 || true
    wc -l < "$TMP/calls"
}
reset_state
[ "$(attempts pr comment 7 --repo o/r --body hi)" -eq 1 ] \
    || fail "scenario 14: 'gh pr comment' was retried — a blip after the server applied it would double-post"
[ "$(attempts api repos/o/r/issues/7/comments --method POST -f body=hi)" -eq 1 ] \
    || fail "scenario 14: 'gh api --method POST' was retried — the shape the api-shaped create sites use"
[ "$(attempts api repos/o/r/pulls/7/commits)" -eq 3 ] \
    || fail "scenario 14: a READ lost its retry budget — the transient-blip resilience the wrapper exists for"
reset_state

# --- 15. publishing must not depend on the CALLER's shell options -------------
# The only falsifiable guard for a bug that shipped here: a bare `( … )` inherits
# the caller's errexit, and on the FIRST writer `head` on the not-yet-existing
# pause file exits 1 — so the critical section dies there, before the log and
# before the write. No pause published, no diagnostic logged. Every other
# scenario reaches this code via `gh … || true`, which suppresses errexit for the
# whole dynamic extent, so none of them would catch a regression.
echo "  scenario 15: publish survives a set -e caller with no pause file yet..."
reset_state
env -u BASH_ENV bash -c '
    set -euo pipefail
    export STATE_DIR="'"$STATE_DIR"'" PATH="'"$TMP/bin"'":$PATH
    export GH_SHIM_BUCKETS="4920	'"$((NOW + 3000))"'	4742	'"$((NOW + 3000))"'"
    export GH_SECONDARY_PAUSE_SECS=60
    . "'"$PROJECT_ROOT"'/lib/gh-retry.sh"
    gh_note_rate_limit
' >/dev/null 2>&1 || true
[ -f "$(gh_pause_file)" ] \
    || fail "scenario 15: no pause published under a set -e caller — the critical section aborted on the missing pause file, so the fleet never backs off and no diagnostic is logged"
reset_state

echo "PASS: gh-rate-limit-smoke"
