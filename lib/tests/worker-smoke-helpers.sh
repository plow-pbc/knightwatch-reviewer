#!/usr/bin/env bash
# Shared helpers for worker-entrypoint smokes (review-one-pr-*-smoke.sh).
#
# Sourced — do not exec. Defines:
#   write_probe_repos_conf <conf_path>
#       Writes the canonical "test-org/probe-repo" repos.conf the worker
#       sources via tracked-repos.sh. Must declare exactly one tracked
#       repo because the smokes drive scenarios off that single PR.
#   write_worker_flock_stub_if_missing <bindir>
#       Production uses util-linux flock(1). On macOS dev hosts brew's
#       flock formula explicitly excludes the binary; this stub uses
#       python3 + fcntl.flock(2) so the per-PR lock acquisition exercises
#       the same OFD-tied semantics on both platforms (lock survives the
#       acquiring shell's exit, releases on FD close). Linux production
#       finds real flock(1) first and skips the stub.
#   write_worker_timeout_stub_if_missing <bindir>
#       macOS lacks GNU timeout(1). Stub honours the leading `-k <grace>`
#       kill-after the reviewer's worker/just-test wraps pass, escalating
#       SIGTERM → SIGKILL like GNU timeout so the wedged-process scenarios
#       reap on both platforms. Linux finds real timeout(1) first and skips.
#
# Pattern note: the SHA-flow smoke had its own copies of both functions
# inline (commit predates this helper). Drift between two copies of
# platform shims is exactly the class of bug the consolidation defends
# against — every new worker smoke now sources here, so a regression in
# the flock stub or the repos.conf shape gets caught once.

write_probe_repos_conf() {
    cat > "$1" <<'CONF'
REPOS=("test-org/probe-repo")
declare -A KID_PATHS=()
declare -A SOURCE_PATHS=()
# Per-scenario allowlist: the worker sources this file, so a scenario's
# env-prefix reaches it. Empty (the default) means nobody is allowlisted.
declare -A TRUSTED_AUTHORS=(["test-org"]="${MOCK_ALLOWLISTED:-}")
CONF
}

write_worker_flock_stub_if_missing() {
    local bindir="$1"
    if command -v flock >/dev/null 2>&1; then
        return 0
    fi
    cat > "$bindir/flock" <<'STUB'
#!/usr/bin/env bash
# Two invocation forms used by the worker:
#   flock -n FD     — non-blocking, exit 1 if held (per-PR lock at
#                     lib/locking.sh acquire_pr_lock and canonical-lock
#                     retry path)
#   flock FD        — blocking, wait for lock (canonical-lock acquire
#                     in lib/review-one-pr.sh)
nonblock=0
case "$1" in
    -n) nonblock=1; shift ;;
esac
fd="$1"
exec python3 - "$fd" "$nonblock" <<'PY'
import fcntl, sys
fd = int(sys.argv[1])
nonblock = sys.argv[2] == "1"
flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblock else 0)
try:
    fcntl.flock(fd, flags)
except BlockingIOError:
    sys.exit(1)
PY
STUB
    chmod +x "$bindir/flock"
}

# gh_permission_stub_body — the collaborators/*/permission arm every generated
# `gh` stub needs, emitted as text for interpolation into a stub heredoc.
#
# One owner because the worker now asks about TWO people per review — the
# requester at admission and the author before executing — so a stub missing
# this arm makes BOTH lookups fail, admission defers, and the scenario dies
# somewhere far from the cause. Three stubs across two files grew this arm
# independently, each time discovered by a different confusing failure.
#
#   GH_STUB_INDETERMINATE_USERS  space-separated logins → rc=2 (could not
#                                verify). The wording dodges TWO patterns on
#                                purpose: a 403 would stamp the fleet pause and
#                                change what the rest of the tick does, and a 5xx
#                                matches GH_API_TRANSIENT_RE so gh_retry would
#                                retry it — burning the budget and slowing every
#                                scenario that arranges an indeterminate.
#   GH_STUB_TRUSTED_USERS        space-separated logins → push access.
#   GH_STUB_PERMISSION_ROLE      blanket role for scenarios that do not care
#                                which person is being asked about.
#   anyone else                  → no push access.
gh_permission_stub_body() {
    cat <<'PERMSTUB'
for _a in "$@"; do
    case "$_a" in
        */collaborators/*/permission)
            _who="${_a##*/collaborators/}"; _who="${_who%/permission}"
            for _i in ${GH_STUB_INDETERMINATE_USERS:-}; do
                [ "$_who" = "$_i" ] && { echo "gh: HTTP 418: unverifiable (simulated)" >&2; exit 1; }
            done
            for _t in ${GH_STUB_TRUSTED_USERS:-}; do
                [ "$_who" = "$_t" ] && { printf 'write\n'; exit 0; }
            done
            if [ -n "${GH_STUB_PERMISSION_ROLE:-}" ]; then printf '%s\n' "$GH_STUB_PERMISSION_ROLE"; exit 0; fi
            printf 'none\n'; exit 0 ;;
    esac
done
PERMSTUB
}

write_worker_timeout_stub_if_missing() {
    local bindir="$1"
    if command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    cat > "$bindir/timeout" <<'STUB'
#!/usr/bin/env bash
# Honours the leading `-k <grace>` (kill-after) the reviewer passes:
# SIGTERM at <dur>, then SIGKILL <grace> later — matches GNU timeout's
# escalation so wedged-worker / wedged-just-test scenarios reap on macOS too.
parse_dur() { case "$1" in *s) echo "${1%s}";; *m) echo $(( ${1%m} * 60 ));; *) echo "$1";; esac; }
kill_after=""
[ "$1" = "-k" ] && { kill_after="$(parse_dur "$2")"; shift 2; }
dur="$(parse_dur "$1")"; shift
# Job control (set -m) puts the command in its own process group (pgid=pid);
# signal the GROUP (negative pid) so same-group children are reaped too —
# matching GNU timeout's contract, not just the direct child PID.
set -m
"$@" &
pid=$!
set +m
(
    sleep "$dur"; kill -TERM "-$pid" 2>/dev/null
    [ -n "$kill_after" ] && { sleep "$kill_after"; kill -KILL "-$pid" 2>/dev/null; }
) &
sleeper=$!
wait "$pid" 2>/dev/null
rc=$?
kill "$sleeper" 2>/dev/null
exit "$rc"
STUB
    chmod +x "$bindir/timeout"
}
