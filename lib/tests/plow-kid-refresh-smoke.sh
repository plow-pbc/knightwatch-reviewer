#!/usr/bin/env bash
# Smoke test for plow-kid-refresh.sh.
#
# Closes the runtime-coverage gap on the manifest consumer that
# bootstraps + maintains kid prior-art indexes for tracked repos.
# Same shape as the other per-consumer smokes: sandbox STATE_DIR,
# stub `git` and `kid` via PATH, exercise the script end-to-end,
# assert log lines + which `kid` invocations fired.
#
# Scenarios:
#   1. KID_PATHS empty (no repos to refresh) → no-op, no errors.
#   2. KID_PATHS entry whose checkout doesn't exist → "checkout missing"
#      log line, no `kid index` call.
#   3. KID_PATHS entry pointing to a .git dir with NO .keepitdry → bootstrap
#      `kid index` call (initial-index path).
#   4. Index already recorded as built from HEAD → no `kid index` call.
#   4b. Index fails → the SHA marker is NOT advanced, so the next tick retries
#      even though LOCAL == REMOTE (the stale-index seam: gating on the
#      CHECKOUT's SHA stranded a failed index silently, because the pull had
#      already advanced HEAD).
#   5. KID_PATHS entry pointing to .git + .keepitdry, new commits
#      (LOCAL != REMOTE) → `git pull` then `kid index` call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t kid-refresh-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export LOG_FILE="$STATE_DIR/plow-kid-refresh.log"
STDOUT_CAP="$STATE_DIR/stdout-capture.log"
export LOCK="$TMPDIR/lock"
mkdir -p "$STATE_DIR"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
# Production no longer prepends $HOME/.local/bin to PATH (writable-PATH
# attack vector). Smoke prepends here so its stubs (kid, git) resolve.
export PATH="$HOME/.local/bin:$PATH"

export STUB_KID_LOG="$STATE_DIR/kid-calls.log"
export STUB_GIT_LOG="$STATE_DIR/git-calls.log"

# Stub `kid` — log every invocation.
cat > "$HOME/.local/bin/kid" <<'STUB'
#!/bin/bash
echo "KID $*" >> "${STUB_KID_LOG:-/dev/null}"
# What a reviewer copying the index mid-run would see: the marker's reason.
[ -f "$2/.keepitdry/.stale" ] && echo "MARKER-DURING-INDEX $(grep '^reason=' "$2/.keepitdry/.stale")" >> "${STUB_KID_LOG:-/dev/null}"
# MOCK_KID_SLEEP simulates an index that cannot finish inside its budget, so
# the timeout scenarios exercise a real SIGTERM rather than a fast exit code.
[ -n "${MOCK_KID_SLEEP:-}" ] && sleep "$MOCK_KID_SLEEP"
exit "${MOCK_KID_EXIT:-0}"
STUB
chmod +x "$HOME/.local/bin/kid"

# Stub `git` — log every invocation; behavior driven by env vars.
# `MOCK_GIT_LOCAL_SHA` / `MOCK_GIT_REMOTE_SHA` simulate the rev-parse
# outputs the script compares to decide "new commits or no-op".
cat > "$HOME/.local/bin/git" <<'STUB'
#!/bin/bash
echo "GIT $*" >> "${STUB_GIT_LOG:-/dev/null}"
case "$1" in
    fetch)        exit "${MOCK_GIT_FETCH_EXIT:-0}" ;;
    pull)         exit "${MOCK_GIT_PULL_EXIT:-0}" ;;
    symbolic-ref) echo "refs/remotes/origin/${MOCK_GIT_DEFAULT:-main}" ;;
    rev-list)     echo "${MOCK_GIT_BEHIND:-3}" ;;
    rev-parse)
        # Two callers: HEAD (LOCAL), origin/<branch> (REMOTE).
        case "$2" in
            HEAD)        echo "${MOCK_GIT_LOCAL_SHA:-aaaaaaaa}" ;;
            origin/*)    echo "${MOCK_GIT_REMOTE_SHA:-aaaaaaaa}" ;;
            --short)
                # `git rev-parse --short HEAD` is used in log strings
                # after a successful index. Emit a stub short SHA.
                echo "abc1234"
                ;;
            *) echo "${MOCK_GIT_LOCAL_SHA:-aaaaaaaa}" ;;
        esac
        ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$HOME/.local/bin/git"

# Sandbox lib dir + repos.conf. Each scenario rewrites repos.conf.
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"
# plow-kid-refresh.sh uses state-io's log() now, instead of the non-teeing
# one-liner it used to define — that shadow hid this unit's whole hourly run from
# journalctl despite StandardOutput=journal.
cp "$PROJECT_ROOT/lib/state-io.sh" "$REVIEWER_LIB_DIR/state-io.sh"

run_refresh() {
    : > "$STUB_KID_LOG"
    : > "$STUB_GIT_LOG"
    : > "$LOG_FILE"
    rm -f "$LOCK"
    # Capture stdout instead of discarding it: state-io's log() TEES to both, and
    # the tee is the property three commits exist to establish — a non-teeing
    # shadow writes $LOG_FILE identically, so every assertion that reads only the
    # file passes with the shadow reintroduced. Asserting on both pins the
    # behaviour rather than a regex over how the shadow happens to be spelled.
    # The exit status is captured rather than swallowed for the same reason the
    # output is: scenarios assert on it, and a bare non-zero would trip the
    # suite's `set -e`.
    : > "$STDOUT_CAP"
    REFRESH_RC=0
    bash "$PROJECT_ROOT/plow-kid-refresh.sh" >"$STDOUT_CAP" 2>&1 || REFRESH_RC=$?
}

count_kid() { grep -c '^KID ' "$STUB_KID_LOG" 2>/dev/null || true; }

# Scenario 1: empty KID_PATHS → no-op.
echo "  scenario 1: empty KID_PATHS — no-op, no kid calls..."
cat > "$STATE_DIR/repos.conf" <<'CONF'
REPOS=()
declare -A KID_PATHS=()
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 kid calls, got $n"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 2: KID_PATHS entry whose path doesn't exist → log "checkout missing".
echo "  scenario 2: missing checkout — log + skip..."
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/foo")
declare -A KID_PATHS=([acme/foo]="$TMPDIR/nonexistent")
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 2: expected 0 kid calls (missing checkout), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q 'checkout missing or not a git repo' "$LOG_FILE" || { echo "FAIL scenario 2: expected 'checkout missing' log line"; cat "$LOG_FILE"; exit 1; }
# ...and on STDOUT too. The unit is StandardOutput=journal, so this is what an
# operator running `journalctl -u pr-reviewer-kid-refresh` actually sees; a
# non-teeing log() would satisfy the file assertion above and fail this one.
grep -q 'checkout missing or not a git repo' "$STDOUT_CAP" \
    || { echo "FAIL scenario 2: the log line never reached stdout — this unit is StandardOutput=journal, so a non-teeing log() makes its whole run invisible to journalctl"; cat "$STDOUT_CAP"; exit 1; }
# Tolerated on purpose: a partial-org repo or a kwr-config .repos[] entry is
# tracked for review but never cloned on this host, so a missing checkout must
# NOT redden the unit — a permanent alarm would bury the repos that actually
# went stale, which is the signal this unit exists to carry. org-sync owns the
# "no mirror" condition and alarms there.
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 2: a missing checkout reddened the unit — permanent alarm buries real staleness"; cat "$LOG_FILE"; exit 1; }

# Scenario 3: .git but no .keepitdry → bootstrap kid index.
echo "  scenario 3: bootstrap (no .keepitdry yet) — initial kid index call..."
PROJ="$TMPDIR/proj-bootstrap"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/bootstrap")
declare -A KID_PATHS=([acme/bootstrap]="$PROJ")
CONF
run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 3: expected 1 kid call (bootstrap), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q "KID index $PROJ" "$STUB_KID_LOG" || { echo "FAIL scenario 3: kid index call shape wrong"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 4: .git + .keepitdry, no new commits (LOCAL == REMOTE) → no-op.
# Scenario 4: the index is already recorded as built from HEAD → nothing to do.
echo "  scenario 4: index already current for HEAD — no kid call..."
PROJ="$TMPDIR/proj-current"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
echo "samesame" > "$PROJ/.keepitdry/.indexed-sha"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/current")
declare -A KID_PATHS=([acme/current]="$PROJ")
CONF
MOCK_GIT_LOCAL_SHA=samesame MOCK_GIT_REMOTE_SHA=samesame run_refresh
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 kid calls (index already at HEAD), got $n"; cat "$STUB_KID_LOG"; exit 1; }
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 4: healthy no-op tick reported failure"; cat "$LOG_FILE"; exit 1; }

# Scenario 4b: the stale-index seam. A failed index must not advance the marker,
# so the NEXT tick retries even though the pull already made LOCAL == REMOTE.
# Gating on the checkout's SHA (what this replaced) stranded such a repo stale
# forever while the unit exited 0.
echo "  scenario 4b: failed index doesn't advance the marker — retries next tick..."
PROJ="$TMPDIR/proj-retry"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/retry")
declare -A KID_PATHS=([acme/retry]="$PROJ")
CONF
# Tick 1: new commits, pull succeeds (advancing HEAD), index FAILS.
MOCK_GIT_LOCAL_SHA=oldsha MOCK_GIT_REMOTE_SHA=newsha MOCK_KID_EXIT=1 run_refresh
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 4b: failed index reported success"; cat "$LOG_FILE"; exit 1; }
[ ! -f "$PROJ/.keepitdry/.indexed-sha" ] || { echo "FAIL scenario 4b: marker advanced despite a FAILED index — the retry is lost"; exit 1; }
# Tick 2: HEAD has advanced, so LOCAL == REMOTE and the old checkout-SHA gate
# would skip — but the marker is still absent, so this must retry.
MOCK_GIT_LOCAL_SHA=newsha MOCK_GIT_REMOTE_SHA=newsha run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 4b: index not retried on an unchanged tick — stranded stale forever"; cat "$STUB_KID_LOG"; exit 1; }
[ "$REFRESH_RC" -eq 0 ] || { echo "FAIL scenario 4b: recovery tick still reported failure"; cat "$LOG_FILE"; exit 1; }
[ "$(cat "$PROJ/.keepitdry/.indexed-sha")" = "newsha" ] || { echo "FAIL scenario 4b: marker not written after a successful index"; exit 1; }

# Scenario 5: .git + .keepitdry, new commits (LOCAL != REMOTE) → pull + index.
echo "  scenario 5: new commits — pull + kid index..."
PROJ="$TMPDIR/proj-fresh"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/fresh")
declare -A KID_PATHS=([acme/fresh]="$PROJ")
CONF
MOCK_GIT_LOCAL_SHA=oldsha MOCK_GIT_REMOTE_SHA=newsha run_refresh
n=$(count_kid)
[ "$n" -eq 1 ] || { echo "FAIL scenario 5: expected 1 kid call (incremental), got $n"; cat "$STUB_KID_LOG"; exit 1; }
grep -q '^GIT pull --ff-only' "$STUB_GIT_LOG" || { echo "FAIL scenario 5: expected 'git pull' before index"; cat "$STUB_GIT_LOG"; exit 1; }
grep -q "KID index $PROJ" "$STUB_KID_LOG" || { echo "FAIL scenario 5: kid index call shape wrong"; cat "$STUB_KID_LOG"; exit 1; }

# Scenario 6: project dir not writable → skipped with an actionable line, kid
# never invoked, unit exits non-zero.
# The regression this pins: this unit runs under ProtectHome=read-only with a
# per-repo ReadWritePaths allowlist that install.sh renders from repos.conf at
# INSTALL time, while org-sync grows the tracked set hourly. A repo discovered
# since the last install is outside the sandbox, so kid's chromadb bootstrap
# died with a bare "Read-only file system (os error 30)" traceback under a log
# line that only said the index failed — 43 of 79 PRs reviewed in 24h
# had no semantic index and nothing said so.
echo "  scenario 6: project outside the sandbox — skipped loudly, no kid call, non-zero exit..."
PROJ="$TMPDIR/proj-readonly"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/readonly")
declare -A KID_PATHS=([acme/readonly]="$PROJ")
CONF
chmod a-w "$PROJ"
run_refresh
chmod -R u+w "$PROJ"   # restore before the trap cleans up
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 6: kid was invoked on an unwritable project ($n calls) — the doomed bootstrap wasn't skipped"; cat "$STUB_KID_LOG"; exit 1; }
grep -q 'not writable under this unit.s sandbox' "$LOG_FILE" || { echo "FAIL scenario 6: expected the sandbox-drift log line"; cat "$LOG_FILE"; exit 1; }
grep -q 'install.sh' "$LOG_FILE" || { echo "FAIL scenario 6: log line must name the remedy (re-run install.sh)"; cat "$LOG_FILE"; exit 1; }
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 6: refresh exited 0 despite a repo it could never index"; cat "$LOG_FILE"; exit 1; }
# No marker is possible on an unwritable project — the log line + red unit carry it.
[ ! -e "$PROJ/.keepitdry/.stale" ] || { echo "FAIL scenario 6: a .stale marker was written into an unwritable project"; exit 1; }

# Scenario 7: kid itself fails → the repo has no fresh index, so the unit must
# not report success. A missing index is invisible at review time (reviews just
# silently lose semantic context), which is the whole failure mode being fixed —
# the read-only sandbox was only one cause of it.
echo "  scenario 7: kid index fails — counted as degraded, non-zero exit..."
PROJ="$TMPDIR/proj-kidfail"
mkdir -p "$PROJ/.git"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/kidfail")
declare -A KID_PATHS=([acme/kidfail]="$PROJ")
CONF
MOCK_KID_EXIT=1 run_refresh
grep -q 'kid index failed' "$LOG_FILE" || { echo "FAIL scenario 7: expected the index-failure log line"; cat "$LOG_FILE"; exit 1; }
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 7: refresh exited 0 with a repo left un-indexed"; cat "$LOG_FILE"; exit 1; }

# Scenario 8: a repo whose index cannot finish must not strand the ones after
# it — the failure isolation this script exists to provide. Both repos hang so
# the assertion is independent of KID_PATHS' (hash-ordered) iteration: seeing
# TWO kid calls proves the loop continued past the first SIGTERM.
echo "  scenario 8: index exceeds its budget — loop continues to the next repo..."
PROJ_A="$TMPDIR/proj-hang-a"; PROJ_B="$TMPDIR/proj-hang-b"
mkdir -p "$PROJ_A/.git" "$PROJ_A/.keepitdry" "$PROJ_B/.git" "$PROJ_B/.keepitdry"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/hang-a" "acme/hang-b")
declare -A KID_PATHS=([acme/hang-a]="$PROJ_A" [acme/hang-b]="$PROJ_B")
CONF
KID_INDEX_TIMEOUT=1 MOCK_KID_SLEEP=5 run_refresh
n=$(count_kid)
[ "$n" -eq 2 ] || { echo "FAIL scenario 8: expected both repos attempted (loop continued past the timeout), got $n"; cat "$STUB_KID_LOG"; exit 1; }
[ ! -f "$PROJ_A/.keepitdry/.indexed-sha" ] && [ ! -f "$PROJ_B/.keepitdry/.indexed-sha" ] || { echo "FAIL scenario 8: a timed-out index advanced its marker — the retry is lost"; exit 1; }
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 8: timed-out indexes reported success"; cat "$LOG_FILE"; exit 1; }

# Scenarios 9-12: the .keepitdry/.stale marker. A repo this sweep left without
# a fresh index carries reason/indexed/behind/since through the same read-only
# mount the reviewer already has, so the posted header can say STALE and why.
echo "  scenario 9: index failure writes .stale (reason, indexed, since) — since survives later sweeps..."
PROJ="$TMPDIR/proj-stale"
mkdir -p "$PROJ/.git" "$PROJ/.keepitdry"
STALE="$PROJ/.keepitdry/.stale"
cat > "$STATE_DIR/repos.conf" <<CONF
REPOS=("acme/stale")
declare -A KID_PATHS=([acme/stale]="$PROJ")
CONF
MOCK_KID_EXIT=1 run_refresh
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 9: expected exit 1"; exit 1; }
[ -f "$STALE" ] || { echo "FAIL scenario 9: .stale not written"; exit 1; }
grep -q '^reason=index-failed$' "$STALE" || { echo "FAIL scenario 9: reason"; cat "$STALE"; exit 1; }
grep -q '^indexed=never$' "$STALE" || { echo "FAIL scenario 9: indexed"; cat "$STALE"; exit 1; }
grep -q '^behind=?$' "$STALE" || { echo "FAIL scenario 9: behind unknown when never indexed"; cat "$STALE"; exit 1; }
grep -q '^since=20' "$STALE" || { echo "FAIL scenario 9: since"; cat "$STALE"; exit 1; }
first_since=$(grep '^since=' "$STALE")
MOCK_KID_EXIT=1 run_refresh
[ "$(grep '^since=' "$STALE")" = "$first_since" ] || { echo "FAIL scenario 9: since must be preserved across sweeps"; cat "$STALE"; exit 1; }

echo "  scenario 9b: committed .stale.tmp / .indexed-sha symlinks are never followed; non-sha content never reaches the marker..."
VICTIM="$TMPDIR/victim.env"; printf 'KEEP=me\n' > "$VICTIM"
ln -s "$VICTIM" "$PROJ/.keepitdry/.stale.tmp"
ln -s "$VICTIM" "$PROJ/.keepitdry/.indexed-sha"     # reads as "KEEP=me": not a sha
MOCK_KID_EXIT=1 run_refresh
[ "$(cat "$VICTIM")" = "KEEP=me" ] || { echo "FAIL scenario 9b: marker write followed a committed symlink"; cat "$VICTIM"; exit 1; }
grep -q '^indexed=never$' "$STALE" || { echo "FAIL scenario 9b: a non-sha .indexed-sha must render as never"; cat "$STALE"; exit 1; }
[ "$(grep -c '^reason=' "$STALE")" -eq 1 ] || { echo "FAIL scenario 9b: injected line reached the marker"; cat "$STALE"; exit 1; }
run_refresh   # successful index publishes .indexed-sha — through the symlink would truncate the victim to a sha
[ "$(cat "$VICTIM")" = "KEEP=me" ] || { echo "FAIL scenario 9b: .indexed-sha write followed a committed symlink"; cat "$VICTIM"; exit 1; }
[ ! -L "$PROJ/.keepitdry/.indexed-sha" ] && [ "$(cat "$PROJ/.keepitdry/.indexed-sha")" = "aaaaaaaa" ] \
    || { echo "FAIL scenario 9b: .indexed-sha should be a regular file holding HEAD"; ls -la "$PROJ/.keepitdry"; exit 1; }
rm -f "$PROJ/.keepitdry/.stale.tmp" "$PROJ/.keepitdry/.indexed-sha"

echo "  scenario 10: a successful index — or one already current — clears .stale; the marker reads refreshing while kid runs..."
: > "$STUB_KID_LOG"
run_refresh
[ ! -e "$STALE" ] || { echo "FAIL scenario 10: .stale should be removed after a successful index"; exit 1; }
grep -q '^MARKER-DURING-INDEX reason=refreshing$' "$STUB_KID_LOG" || { echo "FAIL scenario 10: no refreshing marker while kid index ran"; cat "$STUB_KID_LOG"; exit 1; }
printf 'reason=index-failed\nindexed=never\nbehind=?\nsince=2026-01-01T00:00:00Z\n' > "$STALE"
run_refresh   # .indexed-sha already == HEAD → the no-op short-circuit must still clear it
n=$(count_kid)
[ "$n" -eq 0 ] || { echo "FAIL scenario 10: expected the index-current no-op, got $n kid calls"; exit 1; }
[ ! -e "$STALE" ] || { echo "FAIL scenario 10: leftover .stale survived an index-current sweep"; exit 1; }

echo "  scenario 11: diverged mirror is reported (behind counted), never reset; fetch failure reported too..."
MOCK_GIT_LOCAL_SHA=aaaaaaaa MOCK_GIT_REMOTE_SHA=bbbbbbbb MOCK_GIT_PULL_EXIT=1 MOCK_GIT_BEHIND=7 run_refresh
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 11: expected exit 1 on a diverged mirror"; exit 1; }
grep -q '^reason=diverged$' "$STALE" || { echo "FAIL scenario 11: diverged reason"; cat "$STALE"; exit 1; }
grep -q '^indexed=aaaaaaaa$' "$STALE" || { echo "FAIL scenario 11: indexed sha from .indexed-sha"; cat "$STALE"; exit 1; }
grep -q '^behind=7$' "$STALE" || { echo "FAIL scenario 11: behind from rev-list"; cat "$STALE"; exit 1; }
grep -q '^GIT reset' "$STUB_GIT_LOG" && { echo "FAIL scenario 11: refresh must never reset a mirror"; exit 1; }
MOCK_GIT_FETCH_EXIT=1 run_refresh
[ "$REFRESH_RC" -ne 0 ] || { echo "FAIL scenario 11: expected exit 1 on a fetch failure"; exit 1; }
grep -q '^reason=fetch-failed$' "$STALE" || { echo "FAIL scenario 11: fetch-failed reason"; cat "$STALE"; exit 1; }

echo "  scenario 12: default branch comes from origin/HEAD, not a hardcoded main..."
MOCK_GIT_DEFAULT=master run_refresh
grep -q '^GIT fetch origin master' "$STUB_GIT_LOG" || { echo "FAIL scenario 12: expected fetch of origin master"; cat "$STUB_GIT_LOG"; exit 1; }
grep -q '^GIT rev-parse origin/master' "$STUB_GIT_LOG" || { echo "FAIL scenario 12: expected rev-parse of origin/master"; cat "$STUB_GIT_LOG"; exit 1; }

echo "  PASS (14 scenarios: empty-noop, missing-checkout-tolerated-not-alarmed, bootstrap-on-no-.keepitdry, index-current-is-a-noop, failed-index-retries-next-tick, new-commits-pull-then-index, unwritable-project-skipped-loudly, index-failure-is-not-success, per-repo-timeout-does-not-strand-the-sweep, stale-marker-written-with-since-preserved, marker-write-never-follows-a-committed-symlink, stale-marker-cleared-on-success, diverged-and-fetch-failure-reported-never-reset, default-branch-from-origin-HEAD)"
