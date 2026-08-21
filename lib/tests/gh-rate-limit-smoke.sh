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

# --- 16. the pause survives as ONE inode, so a file bind can carry it ---------
# The host timers and the containers spend the same PAT but live on different
# filesystems, so the pause is unified by bind-mounting the host's file onto the
# container's path. That only works if publishing never replaces the inode:
# docker pins a file bind-mount to its source inode, so a temp+rename would leave
# every container reading the pre-write one — silently, forever. (The same
# property sent repos.conf the other way, to a directory mount; here the pin is
# what makes the sharing possible.)
echo "  scenario 16: publishing keeps the inode (a bind-mounted file stays bound)..."
reset_state
printf '%s\n' "$(( NOW - 10 ))" > "$(gh_pause_file)"
INO_BEFORE=$(stat -c '%i' "$(gh_pause_file)")
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" GH_SECONDARY_PAUSE_SECS=60 \
    gh api "user" >/dev/null 2>&1 || true
[ "$(stat -c '%i' "$(gh_pause_file)")" = "$INO_BEFORE" ] \
    || fail "scenario 16: publishing replaced the inode — docker pins a file bind-mount to the source inode, so every container would read the pre-write file forever"
[ "$(head -n1 "$(gh_pause_file)")" -gt "$NOW" ] 2>/dev/null \
    || fail "scenario 16: publishing over an existing pause did not move the epoch forward"
# No sidecar lock: it would land in the container's own volume and serialize
# nothing across the boundary, on the one inode the mount exists to share.
[ ! -e "$(gh_pause_file).lock" ] \
    || fail "scenario 16: a sidecar .lock was created — it is not covered by the file bind, so the two halves would interleave writes on the shared inode"
reset_state

# --- 17. a throttled call names the endpoint that tripped --------------------
# Diagnosing a trip used to be archaeology: callers capture gh's stderr into
# their own errfile, so the raw 403 reached no log at all and finding the call
# meant correlating journald on the host with orchestrator.log in the containers.
echo "  scenario 17: a throttled call names its endpoint..."
reset_state
: > "$TMP/log17"
LOG_FILE="$TMP/log17" \
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "repos/acme/repo/issues/7/comments" >/dev/null 2>&1 || true
grep -qF 'repos/acme/repo/issues/7/comments' "$TMP/log17" \
    || fail "scenario 17: the throttled endpoint is absent from the log — knowing WHICH call trips the limit is the whole point: $(cat "$TMP/log17")"
# A review body must never reach a log line.
reset_state
: > "$TMP/log17b"
LOG_FILE="$TMP/log17b" \
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh pr comment 7 --repo o/r --body "SECRET-REVIEW-BODY" >/dev/null 2>&1 || true
grep -q 'rate-limited on' "$TMP/log17b" \
    || fail "scenario 17: the create-shaped call never reached the endpoint log — the payload check below would prove nothing"
grep -qF 'SECRET-REVIEW-BODY' "$TMP/log17b" \
    && fail "scenario 17: the --body payload was logged — the argv slice is too wide"
reset_state

# --- 18. a publish that cannot take the lock says so ------------------------
# gh_retry discards this function's status, so the log is the only channel: a
# silent failure would mean the fleet does not back off AND nothing says why —
# the class this whole protocol exists to remove. Reachable rather than
# defensive: readers take `flock -s` on this same inode on EVERY gh call across
# every container and the host timers, and flock is not FIFO-fair.
echo "  scenario 18: an unlockable pause file fails loudly, not silently..."
reset_state
: > "$(gh_pause_file)"
# The holder is a parent-owned fd locked SYNCHRONOUSLY — no background process,
# no fixed sleep to race against the scheduler, nothing to kill afterwards.
exec {holder_fd}>>"$(gh_pause_file)"
flock -x "$holder_fd"
: > "$TMP/log18"
LOCK_RC=0
timeout 15 env -u BASH_ENV STATE_DIR="$STATE_DIR" PATH="$TMP/bin:$PATH" \
    LOG_FILE="$TMP/log18" GH_SECONDARY_PAUSE_SECS=60 GH_PAUSE_LOCK_WAIT_SECS=1 \
    GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
    GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    bash -c '. "'"$PROJECT_ROOT"'/lib/gh-retry.sh"; gh api user' >/dev/null 2>&1 || LOCK_RC=$?
exec {holder_fd}>&-
[ "$LOCK_RC" -ne 124 ] \
    || fail "scenario 18: a held lock HUNG the publish — the tick would burn its TimeoutStartSec and be SIGKILLed"
grep -q 'pause NOT published' "$TMP/log18" \
    || fail "scenario 18: a publish that could not lock said nothing — the fleet keeps calling with no diagnostic: $(cat "$TMP/log18")"
reset_state

# --- 19-22. Quota telemetry (#233) -----------------------------------------
# The fleet kept tripping limits and every incident restarted the same dig:
# correlate six containers' logs by timestamp to guess the top consumer. These
# fence the surface that makes consumption legible BEFORE a limit trips.
reset_state
echo "  scenario 19: gh_endpoint_shape collapses owner/repo/number/user to a stable shape..."
# Without a shape the tally scatters one bucket per repo/PR/user and the
# top-consumer answer — the whole point — is unreadable. The api path sits at $2
# for `gh api <path> --jq` but at $3 for `gh api --paginate <path>`.
[ "$(gh_endpoint_shape api repos/plow-pbc/plow/collaborators/srosro/permission --jq .permission)" \
    = "repos/*/*/collaborators/*/permission" ] || fail "scenario 19: permission shape"
[ "$(gh_endpoint_shape api --paginate repos/plow-pbc/plow/issues/1348/comments)" \
    = "repos/*/*/issues/*/comments" ] || fail "scenario 19: paginated comments shape (path is not \$2)"
[ "$(gh_endpoint_shape pr view 1348 --repo x/y)" = "pr view" ] \
    || fail "scenario 19: non-api argv should collapse to '<verb> <sub>'"

echo "  scenario 20: the tally aggregates by shape..."
: > "$(gh_tally_file)"
gh_tally_call api repos/o/r/collaborators/u/permission --jq .permission
gh_tally_call api repos/o/r/collaborators/u2/permission --jq .permission
gh_tally_call api --paginate repos/o/r/issues/7/comments
TOP=$(gh_top_callers 3)
case "$TOP" in
    "repos/*/*/collaborators/*/permission=2"*) ;;
    *) fail "scenario 20: two different users must fold into ONE permission bucket, ranked first — got '$TOP'" ;;
esac
# Reading CONSUMES the window. Without this every consumer attributes over all
# history — on a host unit that only ever trips, that is months of traffic, the
# trip diagnostic names the wrong endpoint, and the file never stops growing
# (only the container loop calls the periodic report).
[ ! -s "$(gh_tally_file)" ] \
    || fail "scenario 20: gh_top_callers did not consume the window — attribution would drift to all-time and the tally would grow unbounded"

echo "  scenario 21: report emits per-bucket headroom + top callers, consumes the tally, then throttles..."
# Scenario 20 consumed the window, so repopulate before reporting.
gh_tally_call api repos/o/r/collaborators/u/permission --jq .permission
gh_tally_call api repos/o/r/collaborators/u2/permission --jq .permission
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log21"
LOG_FILE="$TMP/log21" GH_QUOTA_REPORT_SECS=300 \
    GH_SHIM_BUCKETS="4977	5000	$((NOW + 1200))	4775	5000" gh_quota_report
grep -q '\[gh-quota\] core=4977/5000 (99%) graphql=4775/5000 (95%)' "$TMP/log21" \
    || fail "scenario 21: no per-bucket headroom line — operators cannot see the budget: $(cat "$TMP/log21")"
grep -q 'top callers: repos/\*/\*/collaborators/\*/permission=2' "$TMP/log21" \
    || fail "scenario 21: headroom without attribution is the whack-a-mole this replaces: $(cat "$TMP/log21")"
[ ! -s "$(gh_tally_file)" ] || fail "scenario 21: tally not consumed — counts would accumulate across reports"
# Second call inside the interval must stay silent, or six containers ticking
# every 30s would each emit and drown the log they exist to clarify.
LOG_FILE="$TMP/log21" GH_QUOTA_REPORT_SECS=300 \
    GH_SHIM_BUCKETS="4977	5000	$((NOW + 1200))	4775	5000" gh_quota_report
[ "$(grep -c '\[gh-quota\] core=' "$TMP/log21")" = 1 ] \
    || fail "scenario 21: a second report inside the interval emitted anyway"

echo "  scenario 22: low headroom WARNs while there is still budget to act on..."
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log22"
LOG_FILE="$TMP/log22" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
    GH_SHIM_BUCKETS="100	5000	$((NOW + 1200))	4775	5000" gh_quota_report
grep -q '\[gh-quota\] WARNING' "$TMP/log22" \
    || fail "scenario 22: 100/5000 raised no warning — the whole point is to see it coming: $(cat "$TMP/log22")"
# And a healthy bucket must NOT warn, or the signal is noise.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log22b"
LOG_FILE="$TMP/log22b" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
    GH_SHIM_BUCKETS="4977	5000	$((NOW + 1200))	4775	5000" gh_quota_report
grep -q 'WARNING' "$TMP/log22b" && fail "scenario 22: warned at 99% headroom — the signal would be noise"
# A failed probe earns no line, but must still stamp, so a flapping API cannot
# become a per-tick storm of its own.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log22c"
LOG_FILE="$TMP/log22c" GH_QUOTA_REPORT_SECS=0 GH_SHIM_BUCKETS="" gh_quota_report
grep -q 'gh-quota' "$TMP/log22c" && fail "scenario 22: a failed probe logged a bogus quota line"
[ -s "$(gh_quota_stamp_file)" ] || fail "scenario 22: a failed probe left no stamp — every tick would re-probe"
reset_state

echo "  scenario 23: GraphQL exhaustion warns too — a core-only gate watches the loaded bucket drain in silence..."
# gh pr view (per worker) and gh pr list (per repo) are GraphQL, so GraphQL is
# the bucket most likely to go first here. A core-only threshold cannot fire for it.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log23"
LOG_FILE="$TMP/log23" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
    GH_SHIM_BUCKETS="4977	5000	$((NOW + 1200))	100	5000" gh_quota_report
grep -q 'WARNING — graphql headroom under' "$TMP/log23" \
    || fail "scenario 23: graphql at 100/5000 raised no warning — the loaded bucket is unmonitored: $(cat "$TMP/log23")"

echo "  scenario 24: the SEAM is wired to the tally — a call through gh() is counted..."
# Scenarios 19-22 exercise the helpers directly, so deleting `gh_tally_call` from
# gh_retry would leave every one of them green while the feature is inert. This
# asserts the single line that wires it, through the real seam.
reset_state; : > "$(gh_tally_file)"
GH_SHIM_ERR='gh: Not Found (HTTP 404)' \
    gh api repos/o/r/collaborators/someuser/permission --jq .permission >/dev/null 2>&1 || true
grep -qx 'repos/\*/\*/collaborators/\*/permission' "$(gh_tally_file)" \
    || fail "scenario 24: a call through the seam produced no tally line — gh_tally_call is not wired into gh_retry: $(cat "$(gh_tally_file)")"

echo "  scenario 25: every ATTEMPT is tallied, not every call — a retry spends real budget..."
reset_state; : > "$(gh_tally_file)"
GH_SHIM_ERR='gh: HTTP 502: Bad Gateway' GH_API_RETRY_MAX=3 GH_API_RETRY_DELAY=0 \
    gh api repos/o/r/issues/7/comments >/dev/null 2>&1 || true
N25=$(grep -cx 'repos/\*/\*/issues/\*/comments' "$(gh_tally_file)")
[ "$N25" = 3 ] \
    || fail "scenario 25: expected 3 tally lines for 3 attempts, got $N25 — retries would be under-reported"
reset_state; : > "$(gh_tally_file)"

echo "  scenario 26: an absent graphql bucket reads as UNKNOWN, never as 0 — no permanent false alarm..."
# @tsv renders a JSON null as an EMPTY field; `tr` + default IFS swallows it and
# every later field shifts left. Read as 0 that would fire "graphql headroom
# under 20%" on every report forever, with corrupted numbers printed beside it —
# unfalsifiable from the log, and it would drown the warning that matters.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log26"
LOG_FILE="$TMP/log26" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
    GH_SHIM_BUCKETS="4977	5000	$((NOW + 1200))" gh_quota_report
grep -q 'graphql=unknown' "$TMP/log26" \
    || fail "scenario 26: a missing graphql bucket was not reported as unknown: $(cat "$TMP/log26")"
grep -q 'WARNING' "$TMP/log26" \
    && fail "scenario 26: an absent graphql bucket raised a warning — a missing bucket is not an empty one: $(cat "$TMP/log26")"
# core must still report normally alongside it.
grep -q 'core=4977/5000 (99%)' "$TMP/log26" \
    || fail "scenario 26: an unknown graphql bucket suppressed the core headroom line too"

echo "  scenario 27: the tally is capped where it is written (host units consume it on neither happy path)..."
: > "$(gh_tally_file)"
# Cap set locally so the scenario is self-contained rather than depending on the
# production default holding at whatever value it drifts to.
for _i in $(seq 1 400); do
    GH_TALLY_MAX_BYTES=2048 GH_TALLY_KEEP_LINES=50 gh_tally_call api "repos/o/r/issues/$_i/comments"
done
BYTES=$(wc -c < "$(gh_tally_file)")
[ "$BYTES" -le 4096 ] \
    || fail "scenario 27: tally grew to ${BYTES}B past a 2048B cap — a host unit that never trips would grow it forever"
[ -s "$(gh_tally_file)" ] \
    || fail "scenario 27: the cap emptied the tally entirely — attribution would always be blank"
: > "$(gh_tally_file)"

echo "PASS: gh-rate-limit-smoke"
