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
