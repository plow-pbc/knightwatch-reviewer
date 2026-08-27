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
        # GH_SHIM_JSON: a real /rate_limit body run through real jq, so the --jq
        # expression under test actually EXECUTES. GH_SHIM_BUCKETS alone prints a
        # canned TSV and never runs jq, which left the `// -1` defaults — the fix
        # for an interior null shifting every later field — unreachable from the
        # suite, and deletable while every scenario stayed green.
        if [ -n "${GH_SHIM_JSON:-}" ]; then
            jq_expr=""; take_next=0
            for a in "$@"; do
                [ "$take_next" = 1 ] && { jq_expr="$a"; break; }
                [ "$a" = "--jq" ] && take_next=1
            done
            [ -n "$jq_expr" ] || exit 1
            printf '%s' "$GH_SHIM_JSON" | jq -r "$jq_expr"
            exit 0
        fi
        [ -n "${GH_SHIM_BUCKETS:-}" ] || exit 1
        printf '%s\n' "$GH_SHIM_BUCKETS"
        exit 0
    fi
done
# GH_SHIM_OK: a non-rate_limit call that SUCCEEDS. gh_retry's success path is
# where the quota drain lives, and without this the shim could only ever
# exercise its failure branches.
[ -n "${GH_SHIM_OK:-}" ] && exit 0
printf '%s\n' "${GH_SHIM_ERR:-gh: some other failure (HTTP 404)}" >&2
exit 1
SHIM
chmod +x "$TMP/bin/gh"

# Source the seam with stderr pointed at a capture file, because sourcing is
# when it dups the entrypoint's stderr. This models production exactly: the unit
# starts, the seam saves ITS stderr (the journal), and the per-call `2>errfile`
# redirects that fetch_issue_comments/is_trusted_repo_author do later cannot
# reach it. Scenarios below therefore assert diagnostics in $DIAG_LOG, not in
# the failing call's own errfile — that separation IS the property under test.
DIAG_LOG="$TMP/diag.log"
: > "$DIAG_LOG"
exec 3>&2                                  # keep the real stderr for fail()
exec 2>"$DIAG_LOG"
. "$PROJECT_ROOT/lib/gh-retry.sh"   # sources state-io.sh itself
exec 2>&3                                  # restore; GH_DIAG_FD still points at $DIAG_LOG

RATE_LIMIT_ERR='gh: API rate limit exceeded for user ID 95421. (HTTP 403)'
NOW=$(date +%s)

reset_state() { rm -f "$(gh_pause_file)"; : > "$DIAG_LOG"; }

# --- 1. secondary: budget remains, yet a rate-limit 403 → short fixed pause ---
# This is the case that actually fired in production: core 4920/5000 and graphql
# 4742/5000 remaining while every call 403'd. /rate_limit cannot see secondary
# limits, so "403 with budget left" IS the secondary signal.
echo "  scenario 1: rate-limit 403 with budget remaining → secondary, short pause..."
reset_state
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
grep -q 'secondary' "$DIAG_LOG" \
    || fail "scenario 1: diagnostic did not classify the limit as secondary — diag: $(cat "$DIAG_LOG")"
# …and it did NOT land in the caller's own errfile, which is where the 400-byte
# truncation used to eat it.
grep -q 'secondary' "$TMP/err1" \
    && fail "scenario 1: the diagnostic followed the caller's redirected stderr — it must go to the saved descriptor instead"

# --- 2. primary/core exhausted → pause until the bucket's OWN reset ---
echo "  scenario 2: core remaining=0 → primary, pause until the real reset epoch..."
reset_state
CORE_RESET=$((NOW + 1800))
GH_SHIM_BUCKETS="0	$CORE_RESET	4742	$((NOW + 3000))	5000	5000" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "user" >/dev/null 2>"$TMP/err2" || true
[ "$(head -n1 "$(gh_pause_file)")" = "$CORE_RESET" ] \
    || fail "scenario 2: expected pause until core reset $CORE_RESET, got $(head -n1 "$(gh_pause_file)")"
grep -q 'primary/core' "$DIAG_LOG" \
    || fail "scenario 2: diagnostic did not classify as primary/core — diag: $(cat "$DIAG_LOG")"

# --- 3. graphql is the exhausted bucket → its reset wins ---
# GraphQL is the loaded bucket in this deployment (~30 pts/min vs core ~0), so
# misreading a graphql exhaustion as core would resume at the wrong time.
echo "  scenario 3: graphql remaining=0 → primary/graphql, graphql's reset..."
reset_state
GQL_RESET=$((NOW + 2400))
GH_SHIM_BUCKETS="4920	$((NOW + 600))	0	$GQL_RESET	5000	5000" \
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
GH_SHIM_BUCKETS="0	$((NOW - 500))	4742	$((NOW + 3000))	5000	5000" \
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
    GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
    GH_SHIM_BUCKETS="0	$CORE_RESET	4742	$((NOW + 3000))	5000	5000" \
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
    export GH_SHIM_BUCKETS="4920	'"$((NOW + 3000))"'	4742	'"$((NOW + 3000))"'	5000	5000"
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
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    gh api "repos/acme/repo/issues/7/comments" >/dev/null 2>&1 || true
grep -qF 'repos/acme/repo/issues/7/comments' "$TMP/log17" \
    || fail "scenario 17: the throttled endpoint is absent from the log — knowing WHICH call trips the limit is the whole point: $(cat "$TMP/log17")"
# A review body must never reach a log line.
reset_state
: > "$TMP/log17b"
LOG_FILE="$TMP/log17b" \
GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
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
    GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))	5000	5000" \
    GH_SHIM_ERR="$RATE_LIMIT_ERR" \
    bash -c '. "'"$PROJECT_ROOT"'/lib/gh-retry.sh"; gh api user' >/dev/null 2>&1 || LOCK_RC=$?
exec {holder_fd}>&-
[ "$LOCK_RC" -ne 124 ] \
    || fail "scenario 18: a held lock HUNG the publish — the tick would burn its TimeoutStartSec and be SIGKILLed"
grep -q 'pause NOT published' "$TMP/log18" \
    || fail "scenario 18: a publish that could not lock said nothing — the fleet keeps calling with no diagnostic: $(cat "$TMP/log18")"
reset_state

# --- 19. the diagnostic survives a caller that captures gh's stderr ----------
# The busiest callers run `gh … 2>"$errfile"` (fetch_issue_comments,
# is_trusted_repo_author) and re-emit only the first 400 bytes. gh's own 403 text
# is ~300 of them, so scenario 17's endpoint line and the classifier that follows
# it were truncated off mid-timestamp: 1001 lines/day reached poll.log and ZERO
# reached the journal, which is why "which limit is it" went unanswered for
# hours. Writing to a saved fd instead of fd 2 makes the diagnostic independent
# of whatever the caller does with its own stderr.
echo "  scenario 19: a caller capturing stderr cannot swallow the diagnostic..."
reset_state
: > "$TMP/diag19"; : > "$TMP/callererr19"
(
    exec {GH_DIAG_FD}>"$TMP/diag19"
    export GH_DIAG_FD
    GH_SHIM_BUCKETS="4920	$((NOW + 3000))	4742	$((NOW + 3000))" \
    GH_SHIM_ERR="$RATE_LIMIT_ERR" GH_SECONDARY_PAUSE_SECS=60 \
        gh api "repos/acme/repo/issues/7/comments" >/dev/null 2>"$TMP/callererr19" || true
)
grep -q 'rate-limited on' "$TMP/diag19" \
    || fail "scenario 19: the endpoint line did not reach the saved diag fd — a caller's errfile still eats it: $(cat "$TMP/diag19")"
grep -q 'secondary' "$TMP/diag19" \
    || fail "scenario 19: the classifier line did not reach the saved diag fd: $(cat "$TMP/diag19")"
# The ALLOCATION end of the contract, at the seam that owns it. Without this,
# deleting gh-retry.sh's `exec {GH_DIAG_FD}>&2` block leaves every scenario above
# green (they open the fd themselves) while every diagnostic silently returns to
# fd 2 and back into the callers' errfiles — the whole bug this change exists to
# fix. Same shape as scenario 12's source-and-check. stderr is NOT redirected
# during the source, because that is the descriptor the seam must capture.
: > "$TMP/err19d"
# The assertion is IMMUNITY, not liveness: after sourcing, the child rebinds its
# own fd 2 the way fetch_issue_comments does, and the marker must still reach the
# ORIGINAL stderr. Asserting only "GH_DIAG_FD is set and writable" would stay
# green against `GH_DIAG_FD=2; export GH_DIAG_FD` — a plausible next edit now
# that gh-retry.sh documents 2 as an acceptable fallback — while every diagnostic
# went straight back into the callers' truncated errfiles.
: > "$TMP/swallowed19d"
env -u BASH_ENV -u GH_DIAG_FD bash -c '
    . "'"$PROJECT_ROOT"'/lib/gh-retry.sh" >/dev/null || exit 3
    [ -n "${GH_DIAG_FD:-}" ] || exit 4
    exec 2>"'"$TMP/swallowed19d"'"
    echo SEAM_DIAG_FD_OK >&"$GH_DIAG_FD"
' 2>"$TMP/err19d" || true
grep -q 'SEAM_DIAG_FD_OK' "$TMP/err19d" \
    || fail "scenario 19: the seam's GH_DIAG_FD did not survive the caller rebinding fd 2 — it is not a saved duplicate of the entrypoint's stderr. err19d: $(cat "$TMP/err19d") swallowed: $(cat "$TMP/swallowed19d")"
grep -q 'SEAM_DIAG_FD_OK' "$TMP/swallowed19d" \
    && fail "scenario 19: the diagnostic followed the caller's rebound fd 2 — exactly the swallowing this change exists to prevent"
reset_state

# --- 20-29. Quota telemetry (#233) -----------------------------------------
# The fleet kept tripping limits and every incident restarted the same dig:
# correlate six containers' logs by timestamp to guess the top consumer. These
# fence the surface that makes consumption legible BEFORE a limit trips.
reset_state
echo "  scenario 20: gh_endpoint_shape collapses owner/repo/number/user to a stable shape..."
# Without a shape the tally scatters one bucket per repo/PR/user and the
# top-consumer answer — the whole point — is unreadable. The api path sits at $2
# for `gh api <path> --jq` but at $3 for `gh api --paginate <path>`.
[ "$(gh_endpoint_shape api repos/plow-pbc/plow/collaborators/srosro/permission --jq .permission)" \
    = "repos/*/*/collaborators/*/permission" ] || fail "scenario 20: permission shape"
[ "$(gh_endpoint_shape api --paginate repos/plow-pbc/plow/issues/1348/comments)" \
    = "repos/*/*/issues/*/comments" ] || fail "scenario 20: paginated comments shape (path is not \$2)"
[ "$(gh_endpoint_shape api repos/plow-pbc/plow/commits/9f3a1c2b4d5e6f708192a3b4c5d6e7f8091a2b3c)" \
    = "repos/*/*/commits/*" ] || fail "scenario 20: commit-SHA shape (bakeoff's per-commit loop is the busiest known consumer; unshaped it scatters into hundreds of one-count buckets and never reaches the top 3)"
[ "$(gh_endpoint_shape pr view 1348 --repo x/y)" = "pr view" ] \
    || fail "scenario 20: non-api argv should collapse to '<verb> <sub>'"

echo "  scenario 21: the tally aggregates by shape..."
: > "$(gh_tally_file)"
gh_tally_call api repos/o/r/collaborators/u/permission --jq .permission
gh_tally_call api repos/o/r/collaborators/u2/permission --jq .permission
gh_tally_call api --paginate repos/o/r/issues/7/comments
TOP=$(gh_top_callers 3)
case "$TOP" in
    "repos/*/*/collaborators/*/permission=2"*) ;;
    *) fail "scenario 21: two different users must fold into ONE permission bucket, ranked first — got '$TOP'" ;;
esac
# Reading CONSUMES the window. Without this every consumer attributes over all
# history — on a host unit that only ever trips, that is months of traffic, the
# trip diagnostic names the wrong endpoint, and the file never stops growing
# (only the container loop calls the periodic report).
[ ! -s "$(gh_tally_file)" ] \
    || fail "scenario 21: gh_top_callers did not consume the window — attribution would drift to all-time and the tally would grow unbounded"

echo "  scenario 22: report emits per-bucket headroom + top callers, consumes the tally, then throttles..."
# Scenario 21 consumed the window, so repopulate before reporting.
gh_tally_call api repos/o/r/collaborators/u/permission --jq .permission
gh_tally_call api repos/o/r/collaborators/u2/permission --jq .permission
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log22"
LOG_FILE="$TMP/log22" GH_QUOTA_REPORT_SECS=300 \
    GH_SHIM_BUCKETS="4977	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000" gh_quota_report
grep -q '\[gh-quota\] core=4977/5000 (99%, resets in 20m) graphql=4775/5000 (95%, resets in 20m)' "$TMP/log22" \
    || fail "scenario 22: no per-bucket headroom line — operators cannot see the budget: $(cat "$TMP/log22")"
grep -q 'top callers: repos/\*/\*/collaborators/\*/permission=2' "$TMP/log22" \
    || fail "scenario 22: headroom without attribution is the whack-a-mole this replaces: $(cat "$TMP/log22")"
[ ! -s "$(gh_tally_file)" ] || fail "scenario 22: tally not consumed — counts would accumulate across reports"
# Second call inside the interval must stay silent, or six containers ticking
# every 30s would each emit and drown the log they exist to clarify.
LOG_FILE="$TMP/log22" GH_QUOTA_REPORT_SECS=300 \
    GH_SHIM_BUCKETS="4977	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000" gh_quota_report
[ "$(grep -c '\[gh-quota\] core=' "$TMP/log22")" = 1 ] \
    || fail "scenario 22: a second report inside the interval emitted anyway"

echo "  scenario 23: the warning fires on EITHER bucket, and stays quiet when both are healthy..."
# One table: same setup, one bucket tuple per row. GraphQL is the loaded bucket
# here (gh pr view per worker, gh pr list per repo), so a core-only gate would
# watch it drain in silence; the healthy row keeps the signal from being noise.
# Tuple order is gh_probe_buckets': core_rem core_reset gql_rem gql_reset core_lim gql_lim
WARN_MATRIX=(
    "core-low|100	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000|WARNING — core headroom under"
    "graphql-low|4977	$((NOW + 1200))	100	$((NOW + 1200))	5000	5000|WARNING — graphql headroom under"
    "healthy|4977	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000|@ABSENT@"
)
for row in "${WARN_MATRIX[@]}"; do
    IFS='|' read -r label buckets want <<<"$row"
    rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log-warn"
    LOG_FILE="$TMP/log-warn" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
        GH_SHIM_BUCKETS="$buckets" gh_quota_report
    if [ "$want" = "@ABSENT@" ]; then
        grep -q 'WARNING' "$TMP/log-warn" \
            && fail "scenario 23 [$label]: warned with both buckets healthy — the signal would be noise: $(cat "$TMP/log-warn")"
    else
        grep -q -- "$want" "$TMP/log-warn" \
            || fail "scenario 23 [$label]: expected '$want' in: $(cat "$TMP/log-warn")"
    fi
done
# Each bucket carries ITS OWN reset. One countdown sourced from core used to be
# printed after both, so a graphql-low warning handed the operator core's
# recovery time — the wrong number for the depleted bucket. Distinct resets here
# (core +600s, graphql +3000s) make a shared countdown visible.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log-reset"
LOG_FILE="$TMP/log-reset" GH_QUOTA_REPORT_SECS=0 GH_QUOTA_WARN_PCT=20 \
    GH_SHIM_BUCKETS="4977	$((NOW + 600))	100	$((NOW + 3000))	5000	5000" gh_quota_report
grep -q 'core=4977/5000 (99%, resets in 10m)' "$TMP/log-reset" \
    || fail "scenario 23: core did not carry its own reset: $(cat "$TMP/log-reset")"
grep -q 'graphql=100/5000 (2%, resets in 50m)' "$TMP/log-reset" \
    || fail "scenario 23: the depleted graphql bucket did not carry ITS OWN reset — the operator gets the wrong recovery time: $(cat "$TMP/log-reset")"

# A failed probe earns no line at all, but must still stamp — otherwise a
# flapping API turns the report into a per-tick storm of its own.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log-warn2"
gh_tally_call api "repos/o/r/collaborators/u/permission" --jq .permission
LOG_FILE="$TMP/log-warn2" GH_QUOTA_REPORT_SECS=0 GH_SHIM_BUCKETS="" gh_quota_report
grep -q 'gh-quota' "$TMP/log-warn2" && fail "scenario 23: a failed probe logged a bogus quota line"
[ -s "$(gh_quota_stamp_file)" ] || fail "scenario 23: a failed probe left no stamp — every tick would re-probe"
# ...and it must still DRAIN. The stamp has already moved, so returning without
# consuming suppresses the next attempt while leaving the window unreaped — and
# with no writer-side cap that is unbounded growth on a file the whole fleet
# appends to. The reachable window is an expired token (every call 401s, so the
# trip diagnostic's drain never fires either), a 5xx spell, or a partition.
[ ! -s "$(gh_tally_file)" ] \
    || fail "scenario 23: a failed probe stamped but did not consume the window — the tally then grows with no reaper at all: $(cat "$(gh_tally_file)")"

echo "  scenario 25: the SEAM is wired to the tally — a call through gh() is counted..."
# Scenarios 20-23 exercise the helpers directly, so deleting `gh_tally_call` from
# gh_retry would leave every one of them green while the feature is inert. This
# asserts the single line that wires it, through the real seam.
reset_state; : > "$(gh_tally_file)"
GH_SHIM_ERR='gh: Not Found (HTTP 404)' \
    gh api repos/o/r/collaborators/someuser/permission --jq .permission >/dev/null 2>&1 || true
grep -qx 'repos/\*/\*/collaborators/\*/permission' "$(gh_tally_file)" \
    || fail "scenario 25: a call through the seam produced no tally line — gh_tally_call is not wired into gh_retry: $(cat "$(gh_tally_file)")"

echo "  scenario 26: every ATTEMPT is tallied, not every call — a retry spends real budget..."
reset_state; : > "$(gh_tally_file)"
GH_SHIM_ERR='gh: HTTP 502: Bad Gateway' GH_API_RETRY_MAX=3 GH_API_RETRY_DELAY=0 \
    gh api repos/o/r/issues/7/comments >/dev/null 2>&1 || true
N26=$(grep -cx 'repos/\*/\*/issues/\*/comments' "$(gh_tally_file)")
[ "$N26" = 3 ] \
    || fail "scenario 26: expected 3 tally lines for 3 attempts, got $N26 — retries would be under-reported"
reset_state; : > "$(gh_tally_file)"

echo "  scenario 27: a malformed /rate_limit reply is rejected WHOLESALE, never shifted..."
# GitHub's documented response always carries complete numeric core and graphql
# tuples, so gh_probe_buckets treats anything else as a failed probe rather than
# coercing field by field. This pins that gate: a null field renders empty in
# @tsv and collapses under `tr`, so it presents as a short count — and it must
# fail the gate, not slide core.limit into core_rem where it would decide the
# pause window. Real jq on a real body, since GH_SHIM_BUCKETS never runs --jq.
reset_state; : > "$TMP/log27"
NULL_CORE_JSON='{"resources":{"core":{"remaining":null,"limit":5000,"reset":'"$((NOW + 1200))"'},"graphql":{"remaining":4775,"limit":5000,"reset":'"$((NOW + 1200))"'}}}'
LOG_FILE="$TMP/log27" GH_SHIM_JSON="$NULL_CORE_JSON" gh_note_rate_limit
grep -q 'gh rate limit (secondary)' "$TMP/log27" \
    || fail "scenario 27: a malformed reply did not fall through to the secondary window: $(cat "$TMP/log27")"
grep -q 'core=?/? graphql=?/?' "$TMP/log27" \
    || fail "scenario 27: a rejected probe rendered figures instead of '?': $(cat "$TMP/log27")"
if sed 's/^\[[0-9-]* [0-9:]*\] //' "$TMP/log27" | grep -q -- '-1'; then
    fail "scenario 27: the -1 sentinel reached operator-facing text: $(cat "$TMP/log27")"
fi
reset_state

echo "  scenario 27b: a failed probe renders '?', never the -1 sentinel..."
# The trip diagnostic exists to separate "probe failed, classification guessed"
# from "buckets healthy, genuinely secondary", and a failed probe is the LIKELY
# path: it runs during a 403 cascade when GitHub is degraded.
reset_state; : > "$TMP/log27b"
LOG_FILE="$TMP/log27b" GH_SHIM_BUCKETS="" GH_SHIM_ERR="$RATE_LIMIT_ERR" gh_note_rate_limit
grep -q 'core=?/? graphql=?/? remaining' "$TMP/log27b" \
    || fail "scenario 27b: an unmeasured bucket did not render as '?': $(cat "$TMP/log27b")"
reset_state

echo "  scenario 28: the drain truncates IN PLACE, keeping the inode..."
# The tally is a bind-mounted FILE, and docker pins a file bind to its SOURCE
# inode — so a drain that REPLACES the file leaves every already-running
# container appending to the orphan while the host writes the new one, silently
# restoring the split the bind exists to close.
#
# Tested by its actual failure mode rather than by inode NUMBER: a freed inode
# number is immediately reused by the next temp file, so comparing `stat %i`
# passes about as often as it fails. An open descriptor is deterministic — it IS
# the stranded writer.
: > "$(gh_tally_file)"
exec 9>>"$(gh_tally_file)"
gh_tally_call api "repos/o/r/collaborators/u/permission" --jq .permission
gh_top_callers 3 >/dev/null
printf 'STRANDED_WRITER_PROBE\n' >&9
exec 9>&-
grep -q 'STRANDED_WRITER_PROBE' "$(gh_tally_file)" \
    || fail "scenario 28: a writer holding the tally open across the drain lost its append — the drain replaced the file, which under the bind strands every running container on the orphaned inode"
: > "$(gh_tally_file)"

echo "  scenario 28b: the SEAM reports BEFORE the call, never after a side effect..."
# Scenarios 22-23 drive gh_quota_report directly, so deleting its call from
# gh_retry would leave every one of them green while nothing drains the window on
# the happy path — the inert-guard class scenario 25 fences for the tally's write
# half. One call site at the seam is what replaced five entrypoint calls and the
# source parser that had to hold them in sync: gh() routes every call in the repo,
# so coverage is by construction rather than by grep.
#
# Driven first through a call that FAILS, which is the exact discriminator for
# the ORDERING. The probe is bounded at 15s, so reporting after a successful call
# put a blocking window between a GitHub-side side effect and the caller's record
# of it: a worker timeout landing there leaves `gh pr comment` posted with
# GH_POSTED still false, the run reads as never-author-visible, and the next tick
# posts the review again. Only the pre-attempt placement reports on a call that
# never succeeded.
reset_state; : > "$(gh_tally_file)"; rm -f "$(gh_quota_stamp_file)"; : > "$TMP/log28b"
gh_tally_call api "repos/o/r/collaborators/u/permission" --jq .permission
LOG_FILE="$TMP/log28b" GH_QUOTA_REPORT_SECS=0 \
    GH_SHIM_BUCKETS="4977	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000" \
    gh api "repos/o/r/pulls/7" >/dev/null 2>/dev/null || true
grep -q 'repos/\*/\*/collaborators/\*/permission=1' "$TMP/log28b" \
    || fail "scenario 28b: a call through the seam did not report the window — with the entrypoint calls gone nothing else reaps the window, and reporting only after a SUCCESS puts the probe between a side effect and its bookkeeping: $(cat "$TMP/log28b")"
# The line has to land on the saved descriptor too, not only in LOG_FILE, which
# log()'s `tee -a` fills wherever stdout points.
grep -qa '\[gh-quota\] core=4977/5000' "$DIAG_LOG" \
    || fail "scenario 28b: the report never reached the saved descriptor — it has to land in the journal, not only in LOG_FILE: $(cat "$DIAG_LOG")"
# Drained, and this attempt tallied in its place: the seeded sample is gone and
# only the call just made remains.
[ "$(cat "$(gh_tally_file)")" = 'repos/*/*/pulls/*' ] \
    || fail "scenario 28b: the window was not consumed-then-refilled by this attempt — got: $(cat "$(gh_tally_file)")"
# And on the SUCCESS path it must stay out of gh's stdout, which IS the API result
# every caller captures (`perm=$(gh_api_retry …)`). Only the >&GH_DIAG_FD redirect
# keeps it there, and the LOG_FILE assertion above cannot see the difference.
rm -f "$(gh_quota_stamp_file)"; : > "$TMP/out28b"
LOG_FILE="$TMP/log28b" GH_QUOTA_REPORT_SECS=0 GH_SHIM_OK=1 \
    GH_SHIM_BUCKETS="4977	$((NOW + 1200))	4775	$((NOW + 1200))	5000	5000" \
    gh api "repos/o/r/pulls/8" >"$TMP/out28b" 2>/dev/null
[ ! -s "$TMP/out28b" ] \
    || fail "scenario 28b: the quota report leaked into gh's stdout — callers capture that as the API result: $(cat "$TMP/out28b")"
reset_state; : > "$(gh_tally_file)"

echo "  scenario 29: review-loop.sh loads the token before it can report quota..."
# gh_quota_report runs `gh api rate_limit` in review-loop.sh's OWN shell, but
# config.env is mounted root-only and was loaded only by child processes. The
# probe therefore ran unauthenticated, failed, and the entire quota report was
# silent in production while every test passed — the feature shipped inert.
# Source-grep, because the failure is a missing source line and nothing else in
# the suite can see it. No order fence: state-io.sh is sourced through the
# re-pinned REVIEWER_LIB_DIR, so a deleted re-pin breaks the container at startup
# rather than needing a test to notice.
LOOP_SRC=$(sed -e 's/#.*//' "$PROJECT_ROOT/review-loop.sh")
grep -qE '^[[:space:]]*(\.|source)[[:space:]].*CONFIG_ENV_FILE' <<<"$LOOP_SRC" \
    || fail "scenario 29: review-loop.sh calls gh_quota_report without loading config.env — the probe runs tokenless and the report is silent"
grep -qE '^[[:space:]]*gh_quota_report([[:space:]]|$)' <<<"$LOOP_SRC" \
    || fail "scenario 29: review-loop.sh no longer CALLS gh_quota_report — the seam only reports on a call it makes, and while the fleet is paused gh_retry short-circuits before making one, so this tick is the only thing reporting headroom during the incident"

echo "PASS: gh-rate-limit-smoke"
