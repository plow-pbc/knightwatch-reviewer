#!/usr/bin/env bash
# Smoke test for org-sync.sh.
#
# Closes the runtime-coverage gap on the manifest *producer* — the
# hourly poller that folds GitHub orgs into a tool-owned auto file.
# Same shape as the per-consumer smokes: sandbox STATE_DIR + a
# tmpdir-rooted SOURCE_BASE, stub `gh` (list + clone) via PATH, run
# org-sync.sh end-to-end, assert on the rewritten auto file shape +
# which `gh` invocations fired.
#
# Manifest split: org-sync writes
# $STATE_DIR/repos.conf.auto, never touches $STATE_DIR/repos.conf.
# Multiple failure modes that the rewriting-in-place variant carried
# are now structurally impossible (no TOCTOU on a shared file, no
# malformed-conf erasure, no marker-block management), so the smoke is
# lighter than it was at HEAD~1.
#
# Scenarios — each maps to a clear business requirement:
#   1. Empty ORGS → no-op + truncate stale auto file. (Feature disabled
#      drops coverage instead of silently retaining a prior tick's set.)
#   2. New repo discovered + missing checkout → cloned, auto file
#      contains expected entries, sourced manifest = (manual ∪ auto).
#   3. Idempotent re-run → cmp-skip, no new clones, no file churn.
#   4. Existing matching checkout → reused, no clone.
#   5. Wrong-origin checkout → fail loud, auto file unchanged, no
#      credential leak in log.
#   6. Spoof-host origin (git@evilgithub.com:...) → exact-match case
#      patterns reject the substring spoof.
#   7. `gh repo list` failure → fail loud, auto file unchanged
#      (transient API errors mustn't erase coverage).
#   8. Auto-prune → repo disappears from gh, next rewrite drops it.
#   9. Same-org manual entry → org-sync's exclusion logic keeps it
#      out of the auto file, so the operator's KID_PATHS wins.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t org-sync-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export LOG="$STATE_DIR/org-sync.log"
# LOCK is intentionally NOT overridden — the production default is
# $STATE_DIR/org-sync.lock, and $STATE_DIR is already sandboxed to
# $TMPDIR/state, so leaving the default flow means the smoke exercises
# the exact shared-lock path systemd uses. Overriding to e.g.
# /$TMPDIR/lock would bypass the very shape the round-6 fix
# established (PrivateTmp-vs-shell shared lock).
export SOURCE_BASE="$TMPDIR/Hacking"
export CONF="$STATE_DIR/repos.conf"
export AUTO_CONF="$STATE_DIR/repos.conf.auto"
mkdir -p "$STATE_DIR" "$SOURCE_BASE"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"

# Provide a flock(1) stub on platforms where the binary is missing
# (notably brew on macOS, which excludes flock from util-linux). The
# stub uses python3 + fcntl.flock(2) so OFD-tied lock semantics match
# Linux production. Inlined-then-shared pattern, same as the worker
# smokes — see lib/tests/worker-smoke-helpers.sh.
. "$PROJECT_ROOT/lib/tests/worker-smoke-helpers.sh"
write_worker_flock_stub_if_missing "$HOME/.local/bin"

export STUB_GH_LOG="$STATE_DIR/gh-calls.log"

# `gh` stub:
#   - `gh repo list <org> ... --jq '.[].name'` emits repo names from
#     MOCK_GH_LIST_<ORG> (newline-separated). The stub ALSO asserts
#     the behavior-bearing filters `--source` and `--no-archived` are
#     present; dropping either would silently let archived/fork repos
#     slip into the auto set.
#   - `gh repo clone <full> <dest>` creates <dest> as a real git repo
#     with origin = git@github.com:<full>.git. Real `git` is used so
#     origin validation exercises actual git plumbing.
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
echo "GH $*" >> "${STUB_GH_LOG:-/dev/null}"
case "$1 $2" in
    "repo list")
        org="$3"
        has_source=0; has_no_archived=0
        for a in "$@"; do
            [ "$a" = "--source" ] && has_source=1
            [ "$a" = "--no-archived" ] && has_no_archived=1
        done
        if [ "$has_source" -eq 0 ] || [ "$has_no_archived" -eq 0 ]; then
            echo "STUB FAIL: gh repo list missing --source or --no-archived: $*" >&2
            exit 2
        fi
        sanitized="${org//[^a-zA-Z0-9]/_}"
        list_var="MOCK_GH_LIST_${sanitized}"
        exit_var="MOCK_GH_LIST_EXIT_${sanitized}"
        printf '%s\n' "${!list_var:-}" | sed '/^$/d'
        exit "${!exit_var:-0}"
        ;;
    "repo clone")
        full="$3"
        dest="$4"
        mkdir -p "$dest"
        git -C "$dest" init -q
        git -C "$dest" remote add origin "git@github.com:${full}.git"
        exit "${MOCK_GH_CLONE_EXIT:-0}"
        ;;
esac
exit 0
STUB
chmod +x "$HOME/.local/bin/gh"

run_sync() {
    : > "$STUB_GH_LOG"
    # Do NOT rm the lock file — flock releases on FD close (process
    # exit), so successive runs don't conflict. Production never
    # touches the lock file's presence; the smoke shouldn't either.
    bash "$PROJECT_ROOT/org-sync.sh" >/dev/null 2>&1
    return $?
}

count_gh() { grep -c "^GH $1" "$STUB_GH_LOG" 2>/dev/null || true; }

# Manifest fixture helpers. Per ~/.claude/TESTING.md: one factory with
# overrides, customize only what matters per scenario.
write_baseline_conf() {
    local orgs="${1:-}"
    cat > "$CONF" <<CONF
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=($orgs)
CONF
}
auto_sha() { [ -f "$AUTO_CONF" ] && sha1sum "$AUTO_CONF" | awk '{print $1}' || echo "absent"; }
assert_auto_unchanged() {
    local before="$1" after
    after=$(auto_sha)
    if [ "$before" != "$after" ]; then
        echo "FAIL: repos.conf.auto mutated unexpectedly ($before → $after)"
        exit 1
    fi
}

# Source the REAL loader in a sub-shell to verify end-to-end contract.
# Pinning at the loader (not a smoke-private duplicate that hand-sources
# repos.conf + repos.conf.auto) means future loader changes — source
# order, dedup, dedup algorithm — propagate to this smoke automatically
# instead of needing parallel updates here.
resolved_repos() {
    (
        # shellcheck disable=SC1090
        . "$REVIEWER_LIB_DIR/tracked-repos.sh"
        printf '%s\n' "${REPOS[@]}" | sort
    )
}
resolved_kid_path() {
    (
        # shellcheck disable=SC1090
        . "$REVIEWER_LIB_DIR/tracked-repos.sh"
        echo "${KID_PATHS[$1]:-}"
    )
}

# --- Scenario 1: empty ORGS = feature disabled --------------------------------
echo "  scenario 1: empty ORGS — no gh calls + stale auto file truncated..."
# Pre-stage an auto file as if a prior tick had populated it; emptying
# ORGS should drop that coverage on the next tick.
echo 'REPOS+=("stale/auto")' > "$AUTO_CONF"
write_baseline_conf
run_sync || { echo "FAIL scenario 1: org-sync exited non-zero"; cat "$LOG"; exit 1; }
[ ! -f "$AUTO_CONF" ] || { echo "FAIL scenario 1: stale auto file not removed"; cat "$AUTO_CONF"; exit 1; }
n=$(count_gh "repo list")
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 gh repo list calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 2: discover + clone ---------------------------------------------
echo "  scenario 2: new repo discovered → cloned, auto file populated, manual preserved..."
write_baseline_conf '"acme"'
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 2: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 2 ] || { echo "FAIL scenario 2: expected 2 clone calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }
[ -d "$SOURCE_BASE/foo/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/foo not cloned"; exit 1; }
[ -d "$SOURCE_BASE/bar/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/bar not cloned"; exit 1; }
# repos.conf MUST NOT be modified — that's the structural promise of
# the split-file design. Bit-exact assert beats the prior marker-block
# grep (which only proved the markers existed).
expected_conf='REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")'
[ "$(cat "$CONF")" = "$expected_conf" ] || { echo "FAIL scenario 2: repos.conf was modified — split-file boundary breached"; diff <(echo "$expected_conf") "$CONF"; exit 1; }
[ -f "$AUTO_CONF" ] || { echo "FAIL scenario 2: $AUTO_CONF not created"; exit 1; }
expected=$'acme/bar\nacme/foo\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 2: resolved REPOS mismatch — got"; echo "$got"; exit 1; }
got=$(resolved_kid_path "acme/foo")
[ "$got" = "$HOME/Hacking/foo" ] || { echo "FAIL scenario 2: KID_PATHS[acme/foo] = '$got'"; exit 1; }
# SOURCE_PATHS regression fence: cross-repo grep surface stays an
# explicit operator opt-in. Auto-discovered repos MUST NOT appear in
# SOURCE_PATHS — re-introducing them re-opens the private-sibling
# exposure path through materialize_sibling_symlinks.
if grep -q '^SOURCE_PATHS\[' "$AUTO_CONF"; then
    echo "FAIL scenario 2: auto file emits SOURCE_PATHS — re-opens cross-repo source exposure"
    grep '^SOURCE_PATHS\[' "$AUTO_CONF"; exit 1
fi
got=$(
    declare -a REPOS=() ORGS=()
    declare -A KID_PATHS=() SOURCE_PATHS=()
    # shellcheck disable=SC1090
    . "$REVIEWER_LIB_DIR/tracked-repos.sh"
    echo "${SOURCE_PATHS[acme/foo]:-}"
)
[ -z "$got" ] || { echo "FAIL scenario 2: resolved SOURCE_PATHS[acme/foo] = '$got' (expected empty)"; exit 1; }

# --- Scenario 3: idempotent re-run --------------------------------------------
echo "  scenario 3: rerun with same gh state — cmp-skip, no rewrite, no new clones..."
SHA=$(auto_sha)
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 3: org-sync exited non-zero"; cat "$LOG"; exit 1; }
assert_auto_unchanged "$SHA"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 3: expected 0 clones on rerun, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 4: existing matching checkout reused ----------------------------
echo "  scenario 4: existing checkout with matching origin — reused, no clone..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
rm -rf "$SOURCE_BASE/baz"
mkdir -p "$SOURCE_BASE/baz"
git -C "$SOURCE_BASE/baz" init -q
git -C "$SOURCE_BASE/baz" remote add origin "git@github.com:acme/baz.git"
MOCK_GH_LIST_acme="baz" run_sync || { echo "FAIL scenario 4: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 clones (existing checkout), got $n"; cat "$STUB_GH_LOG"; exit 1; }
grep -q '"acme/baz"' "$AUTO_CONF" || { echo "FAIL scenario 4: acme/baz not in $AUTO_CONF"; cat "$AUTO_CONF"; exit 1; }

# --- Scenario 5: wrong-origin checkout fails loud + no credential leak --------
echo "  scenario 5: existing checkout with WRONG origin — fail loud, auto unchanged, no log leak..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
SHA=$(auto_sha)
rm -rf "$SOURCE_BASE/evil"
mkdir -p "$SOURCE_BASE/evil"
git -C "$SOURCE_BASE/evil" init -q
git -C "$SOURCE_BASE/evil" remote add origin "git@github.com:attacker/evil.git"
if MOCK_GH_LIST_acme="evil" run_sync; then
    echo "FAIL scenario 5: org-sync returned 0 on wrong-origin checkout"; cat "$LOG"; exit 1
fi
assert_auto_unchanged "$SHA"
grep -q 'origin does not match github.com/acme/evil' "$LOG" || { echo "FAIL scenario 5: expected origin-mismatch log line"; cat "$LOG"; exit 1; }
if grep -q 'attacker/evil' "$LOG"; then
    echo "FAIL scenario 5: raw remote URL leaked into log — credential exposure risk"
    cat "$LOG"; exit 1
fi

# --- Scenario 6: spoof-host origin (substring vs exact) -----------------------
echo "  scenario 6: spoof-host origin (evilgithub.com) — fail loud, auto unchanged..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
SHA=$(auto_sha)
rm -rf "$SOURCE_BASE/spoof"
mkdir -p "$SOURCE_BASE/spoof"
git -C "$SOURCE_BASE/spoof" init -q
git -C "$SOURCE_BASE/spoof" remote add origin "git@evilgithub.com:acme/spoof.git"
if MOCK_GH_LIST_acme="spoof" run_sync; then
    echo "FAIL scenario 6: org-sync accepted evilgithub.com spoof"; cat "$LOG"; exit 1
fi
assert_auto_unchanged "$SHA"

# --- Scenario 7: gh list failure aborts cleanly -------------------------------
echo "  scenario 7: gh repo list failure — fail loud, no rewrite, no clone..."
write_baseline_conf '"flakyorg"'
echo 'REPOS+=("prior/auto")' > "$AUTO_CONF"  # pre-stage a known auto file
SHA=$(auto_sha)
if MOCK_GH_LIST_EXIT_flakyorg=1 run_sync; then
    echo "FAIL scenario 7: org-sync returned 0 on gh repo list failure"; cat "$LOG"; exit 1
fi
assert_auto_unchanged "$SHA"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 7: expected 0 clones on listing failure, got $n"; exit 1; }

# --- Scenario 8: auto-prune ---------------------------------------------------
echo "  scenario 8: repo disappears from gh — auto file regenerated WITHOUT it..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
MOCK_GH_LIST_acme=$'alpha\nbeta' run_sync || { echo "FAIL scenario 8 setup: org-sync exited non-zero"; cat "$LOG"; exit 1; }
expected=$'acme/alpha\nacme/beta\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 8 setup: seed REPOS mismatch — got $got"; exit 1; }
MOCK_GH_LIST_acme="alpha" run_sync || { echo "FAIL scenario 8: org-sync exited non-zero on prune tick"; cat "$LOG"; exit 1; }
expected=$'acme/alpha\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 8: auto-prune failed — got $got"; exit 1; }
if grep -q 'acme/beta' "$AUTO_CONF"; then echo "FAIL scenario 8: 'acme/beta' still referenced after prune"; cat "$AUTO_CONF"; exit 1; fi

# --- Scenario 9: same-org manual entry preserved ------------------------------
# Operator pins `acme/special` with a custom KID_PATHS. ORGS=("acme"),
# `gh repo list acme` includes "special". The producer-side exclusion
# must keep `acme/special` out of the auto file so the operator's
# custom KID_PATHS wins (no shadow-on-source-order).
echo "  scenario 9: same-org manual entry — auto file excludes it, custom KID_PATHS wins..."
cat > "$CONF" <<'CONF'
REPOS=("acme/special")
declare -A KID_PATHS=(["acme/special"]="/var/operator/custom-special")
declare -A SOURCE_PATHS=(["acme/special"]="/var/operator/custom-special")
ORGS=("acme")
CONF
rm -f "$AUTO_CONF"
MOCK_GH_LIST_acme=$'special\nother' run_sync || { echo "FAIL scenario 9: org-sync exited non-zero"; cat "$LOG"; exit 1; }
got=$(resolved_kid_path "acme/special")
[ "$got" = "/var/operator/custom-special" ] || { echo "FAIL scenario 9: KID_PATHS[acme/special] = '$got'"; exit 1; }
got=$(resolved_kid_path "acme/other")
[ "$got" = "$HOME/Hacking/other" ] || { echo "FAIL scenario 9: KID_PATHS[acme/other] = '$got'"; exit 1; }
if grep -q 'acme/special' "$AUTO_CONF"; then
    echo "FAIL scenario 9: 'acme/special' appears in auto file — would shadow operator's custom path"
    cat "$AUTO_CONF"; exit 1
fi

# --- Scenario 10: clone failure aborts before rewrite ------------------------
# The clone branch is wired to abort on `gh repo clone` failure.
# Without this scenario, a regression that swallowed clone errors
# would silently ship — auto file would still get written referencing
# a non-existent local checkout, and kid-refresh would index-fail
# forever after.
echo "  scenario 10: gh repo clone failure — fail loud + no partial left + recovery on next tick..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
SHA=$(auto_sha)
rm -rf "$SOURCE_BASE/cant-clone"
# The smoke `gh` stub creates $dest with .git + origin BEFORE honoring
# MOCK_GH_CLONE_EXIT, faithfully simulating production gh's failure
# behavior. Without org-sync's rm -rf $dest on failure, next tick's
# branches would treat the partial as a complete clone and silently
# publish an empty checkout into the auto manifest.
if MOCK_GH_LIST_acme="cant-clone" MOCK_GH_CLONE_EXIT=1 run_sync; then
    echo "FAIL scenario 10: org-sync returned 0 on clone failure"; cat "$LOG"; exit 1
fi
assert_auto_unchanged "$SHA"
grep -q 'gh repo clone acme/cant-clone failed' "$LOG" || { echo "FAIL scenario 10: expected clone-failure log line"; cat "$LOG"; exit 1; }
# Partial-clone cleanup pin: $dest MUST be gone after failure.
[ ! -e "$SOURCE_BASE/cant-clone" ] || { echo "FAIL scenario 10: partial clone left behind at $SOURCE_BASE/cant-clone"; ls -la "$SOURCE_BASE/cant-clone"; exit 1; }
# Recovery tick: with MOCK_GH_CLONE_EXIT unset, clone succeeds; auto
# file gains the new entry. The dest is fresh — no smuggled state
# from the prior failed attempt.
MOCK_GH_LIST_acme="cant-clone" run_sync || { echo "FAIL scenario 10 recovery: org-sync exited non-zero"; cat "$LOG"; exit 1; }
[ -d "$SOURCE_BASE/cant-clone/.git" ] || { echo "FAIL scenario 10 recovery: clone didn't happen on recovery tick"; exit 1; }
grep -q '"acme/cant-clone"' "$AUTO_CONF" || { echo "FAIL scenario 10 recovery: auto file missing recovered repo"; cat "$AUTO_CONF"; exit 1; }

# --- Scenario 11: lock contention — concurrent run defers ------------------
# When the systemd timer fires while an operator's shell-launched run
# is mid-clone (or vice-versa), the second invocation must skip cleanly
# instead of racing on the same checkout. flock on $STATE_DIR/org-sync.lock
# is the seam — both runs see the same lock file (no PrivateTmp split).
echo "  scenario 11: lock held by concurrent run — sync exits 0, no gh calls, no file change..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
# Hold the lock on a background FD. flock blocks on FD close — keep
# the background shell alive long enough to span our sync attempt.
exec 8>"$STATE_DIR/org-sync.lock"
flock -n 8 || { echo "FAIL scenario 11 setup: could not acquire lock pre-test"; exit 1; }
SHA=$(auto_sha)
# Foreground sync should detect the held lock and exit 0.
MOCK_GH_LIST_acme="held" run_sync || { echo "FAIL scenario 11: sync exited non-zero despite lock-held"; cat "$LOG"; exit 1; }
n=$(count_gh "repo list")
[ "$n" -eq 0 ] || { echo "FAIL scenario 11: sync made $n gh repo list calls while lock held"; cat "$STUB_GH_LOG"; exit 1; }
assert_auto_unchanged "$SHA"
grep -q 'sync already running' "$LOG" || { echo "FAIL scenario 11: expected 'sync already running' log line"; cat "$LOG"; exit 1; }
exec 8>&-  # Release the background lock.

echo "  PASS (11 scenarios: empty-orgs-truncates-stale, discover+clone, idempotent-rerun, existing-checkout-reuse, wrong-origin-fail-loud, spoof-host-fail-loud, gh-list-failure-no-mutation, auto-prune, same-org-manual-excluded, clone-failure-no-mutation, lock-held-defers)"
