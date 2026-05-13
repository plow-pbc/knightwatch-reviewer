#!/usr/bin/env bash
# Smoke test for org-sync.sh.
#
# Closes the runtime-coverage gap on the manifest *producer* — the
# hourly poller that folds GitHub orgs into repos.conf. Same shape as
# the per-consumer smokes: sandbox STATE_DIR + a tmpdir-rooted
# SOURCE_BASE, stub `gh` (list + clone) via PATH, run org-sync.sh
# end-to-end, assert on the rewritten file shape + which `gh`
# invocations fired.
#
# Scenarios:
#   1. Empty ORGS → no-op. No gh calls. repos.conf byte-identical.
#   2. New repo discovered + missing checkout → `gh repo clone` fired,
#      auto-block regenerated with REPOS+=/KID_PATHS/SOURCE_PATHS
#      entries, manual section preserved verbatim, sourced manifest
#      contains (manual ∪ auto).
#   3. Idempotent re-run after #2 → cmp-skip, no rewrite, no new clones.
#   4. Existing matching checkout → reused (no clone), still listed
#      in auto-block.
#   5. Existing checkout with WRONG origin → fail loud, repos.conf
#      unchanged, no credential leak in log.
#   6. `gh repo list` failure → fail loud, repos.conf unchanged
#      (silently emptying the auto-block on a transient API error
#      would erase coverage).
#   7. Repo that was in the auto-block disappears from gh (archived,
#      deleted, fork-converted) → auto-prune: next rewrite drops it.
#   8. Spoof-host origin (git@evilgithub.com:...) → exact-match case
#      patterns reject the substring spoof.
#   9. Same-org manual entry with custom KID_PATHS → preserved, NOT
#      shadowed by an auto-block entry.
#  10. Malformed repos.conf (bash syntax error) → abort before mv;
#      manifest erasure prevented.
#  11. Concurrent operator edit during gh call → TOCTOU SHA recheck
#      aborts the rewrite, operator's edit survives.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t org-sync-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export STATE_DIR="$TMPDIR/state"
export LOG="$STATE_DIR/org-sync.log"
export LOCK="$TMPDIR/lock"
export SOURCE_BASE="$TMPDIR/Hacking"
export CONF="$STATE_DIR/repos.conf"
mkdir -p "$STATE_DIR" "$SOURCE_BASE"

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
# Stubs first; system PATH after.
export PATH="$HOME/.local/bin:$PATH"

# Sandbox lib dir — exact same shape as the production install (the
# loader is what consumers source; we run from the same dir layout).
export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"

export STUB_GH_LOG="$STATE_DIR/gh-calls.log"

# `gh` stub:
#   - `gh repo list <org> ... --jq '.[].name'` emits repo names from
#     MOCK_GH_LIST_<ORG> (newline-separated). Exit code controlled by
#     MOCK_GH_LIST_EXIT_<ORG> (default 0). The stub ALSO asserts the
#     invocation carries the behavior-bearing filters `--source` and
#     `--no-archived` — dropping either would silently let archived
#     repos / forks slip into the auto-block, and a stub that accepts
#     any args would mask that regression.
#   - MOCK_GH_LIST_MUTATE_CONF: if set, the stub appends a line to
#     that file during the list call to simulate a concurrent operator
#     edit of repos.conf mid-sync. Used by the TOCTOU scenario.
#   - `gh repo clone <full> <dest>` creates <dest> as a real git repo
#     with origin = git@github.com:<full>.git. Real `git` is used so
#     the script's remote-validation check exercises actual git
#     plumbing.
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
        if [ -n "${MOCK_GH_LIST_MUTATE_CONF:-}" ]; then
            echo "# concurrent operator edit" >> "$MOCK_GH_LIST_MUTATE_CONF"
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
    rm -f "$LOCK"
    bash "$PROJECT_ROOT/org-sync.sh" >/dev/null 2>&1
    return $?
}

count_gh() { grep -c "^GH $1" "$STUB_GH_LOG" 2>/dev/null || true; }

# Manifest fixture helpers — keep scenario bodies focused on the
# scenario-specific shape, not the manifest boilerplate.
write_baseline_conf() {
    local orgs="${1:-}"
    cat > "$CONF" <<CONF
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=($orgs)
CONF
}
conf_sha() { sha1sum "$CONF" | awk '{print $1}'; }
assert_conf_unchanged() {
    local before="$1" after
    after=$(conf_sha)
    if [ "$before" != "$after" ]; then
        echo "FAIL: repos.conf mutated unexpectedly ($before → $after)"
        exit 1
    fi
}

# Resolve the manifest a la production: source the rewritten repos.conf
# in a sub-shell to verify REPOS / KID_PATHS / SOURCE_PATHS roundtrip
# through the file shape. Asserts the *bash-visible* contract, not just
# the text shape, so a future quoting regression in the rewrite block
# surfaces here.
resolved_repos() {
    (
        declare -a REPOS=() ORGS=()
        declare -A KID_PATHS=() SOURCE_PATHS=()
        # shellcheck disable=SC1090
        . "$CONF"
        printf '%s\n' "${REPOS[@]}" | sort
    )
}
resolved_kid_path() {
    (
        declare -a REPOS=() ORGS=()
        declare -A KID_PATHS=() SOURCE_PATHS=()
        # shellcheck disable=SC1090
        . "$CONF"
        echo "${KID_PATHS[$1]:-}"
    )
}

# --- Scenario 1: empty ORGS --------------------------------------------------
echo "  scenario 1: empty ORGS — no-op, no gh calls, file unchanged..."
write_baseline_conf
SHA=$(conf_sha)
run_sync || { echo "FAIL scenario 1: org-sync exited non-zero"; cat "$LOG"; exit 1; }
assert_conf_unchanged "$SHA"
n=$(count_gh "repo list")
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 gh repo list calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 2: discover + clone --------------------------------------------
echo "  scenario 2: new repo discovered → cloned, auto-block regenerated, manual preserved..."
write_baseline_conf '"acme"'
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 2: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 2 ] || { echo "FAIL scenario 2: expected 2 clone calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }
[ -d "$SOURCE_BASE/foo/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/foo not cloned"; exit 1; }
[ -d "$SOURCE_BASE/bar/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/bar not cloned"; exit 1; }
grep -q '"manual/keep"' "$CONF" || { echo "FAIL scenario 2: manual entry erased"; cat "$CONF"; exit 1; }
grep -q '/var/manual' "$CONF" || { echo "FAIL scenario 2: manual KID_PATHS erased"; cat "$CONF"; exit 1; }
grep -q '^# === BEGIN AUTO-SYNC ===$' "$CONF" || { echo "FAIL scenario 2: BEGIN marker missing"; cat "$CONF"; exit 1; }
grep -q '^# === END AUTO-SYNC ===$' "$CONF" || { echo "FAIL scenario 2: END marker missing"; cat "$CONF"; exit 1; }
expected=$'acme/bar\nacme/foo\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 2: resolved REPOS mismatch"; echo "$got"; exit 1; }
got=$(resolved_kid_path "acme/foo")
[ "$got" = "$HOME/Hacking/foo" ] || { echo "FAIL scenario 2: KID_PATHS[acme/foo] = '$got'"; exit 1; }

# --- Scenario 3: idempotent re-run -------------------------------------------
echo "  scenario 3: rerun with same gh state — cmp-skip, no rewrite, no new clones..."
SHA=$(conf_sha)
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 3: org-sync exited non-zero"; cat "$LOG"; exit 1; }
assert_conf_unchanged "$SHA"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 3: expected 0 clones on rerun, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 4: existing matching checkout reused ---------------------------
echo "  scenario 4: existing checkout with matching origin — reused, no clone..."
write_baseline_conf '"acme"'
rm -rf "$SOURCE_BASE/baz"
mkdir -p "$SOURCE_BASE/baz"
git -C "$SOURCE_BASE/baz" init -q
git -C "$SOURCE_BASE/baz" remote add origin "git@github.com:acme/baz.git"
MOCK_GH_LIST_acme="baz" run_sync || { echo "FAIL scenario 4: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 clones (existing checkout), got $n"; cat "$STUB_GH_LOG"; exit 1; }
grep -q '"acme/baz"' "$CONF" || { echo "FAIL scenario 4: acme/baz not in rewritten repos.conf"; cat "$CONF"; exit 1; }

# --- Scenario 5: wrong-origin checkout fails loud + no credential leak -------
echo "  scenario 5: existing checkout with WRONG origin — fail loud, no rewrite, no log leak..."
write_baseline_conf '"acme"'
SHA=$(conf_sha)
rm -rf "$SOURCE_BASE/evil"
mkdir -p "$SOURCE_BASE/evil"
git -C "$SOURCE_BASE/evil" init -q
git -C "$SOURCE_BASE/evil" remote add origin "git@github.com:attacker/evil.git"
if MOCK_GH_LIST_acme="evil" run_sync; then
    echo "FAIL scenario 5: org-sync returned 0 on wrong-origin checkout"
    cat "$LOG"; exit 1
fi
assert_conf_unchanged "$SHA"
grep -q 'origin does not match github.com/acme/evil' "$LOG" || { echo "FAIL scenario 5: expected origin-mismatch log line"; cat "$LOG"; exit 1; }
if grep -q 'attacker/evil' "$LOG"; then
    echo "FAIL scenario 5: raw remote URL leaked into log — credential exposure risk"
    cat "$LOG"; exit 1
fi

# --- Scenario 6: gh list failure aborts cleanly ------------------------------
echo "  scenario 6: gh repo list failure — fail loud, no rewrite, no clone..."
write_baseline_conf '"flakyorg"'
SHA=$(conf_sha)
if MOCK_GH_LIST_EXIT_flakyorg=1 run_sync; then
    echo "FAIL scenario 6: org-sync returned 0 on gh repo list failure"
    cat "$LOG"; exit 1
fi
assert_conf_unchanged "$SHA"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 6: expected 0 clones on listing failure, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 7: auto-prune --------------------------------------------------
echo "  scenario 7: repo disappears from gh — auto-block regenerated WITHOUT it..."
write_baseline_conf '"acme"'
MOCK_GH_LIST_acme=$'alpha\nbeta' run_sync || { echo "FAIL scenario 7 setup: org-sync exited non-zero"; cat "$LOG"; exit 1; }
expected=$'acme/alpha\nacme/beta\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 7 setup: seed REPOS mismatch — got $got"; exit 1; }
MOCK_GH_LIST_acme="alpha" run_sync || { echo "FAIL scenario 7: org-sync exited non-zero on prune tick"; cat "$LOG"; exit 1; }
expected=$'acme/alpha\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 7: auto-prune failed — got $got"; exit 1; }
if grep -q 'acme/beta' "$CONF"; then echo "FAIL scenario 7: 'acme/beta' still referenced"; cat "$CONF"; exit 1; fi

# --- Scenario 8: spoof-host origin (substring vs exact) ---------------------
echo "  scenario 8: spoof-host origin (evilgithub.com) — fail loud, no rewrite..."
write_baseline_conf '"acme"'
SHA=$(conf_sha)
rm -rf "$SOURCE_BASE/spoof"
mkdir -p "$SOURCE_BASE/spoof"
git -C "$SOURCE_BASE/spoof" init -q
git -C "$SOURCE_BASE/spoof" remote add origin "git@evilgithub.com:acme/spoof.git"
if MOCK_GH_LIST_acme="spoof" run_sync; then
    echo "FAIL scenario 8: org-sync accepted evilgithub.com spoof"
    cat "$LOG"; exit 1
fi
assert_conf_unchanged "$SHA"

# --- Scenario 9: same-org manual entry preserved -----------------------------
# Custom manual section (not the baseline) so write_baseline_conf doesn't apply.
echo "  scenario 9: same-org manual entry — auto-block must NOT shadow it..."
cat > "$CONF" <<'CONF'
REPOS=("acme/special")
declare -A KID_PATHS=(["acme/special"]="/var/operator/custom-special")
declare -A SOURCE_PATHS=(["acme/special"]="/var/operator/custom-special")
ORGS=("acme")
CONF
MOCK_GH_LIST_acme=$'special\nother' run_sync || { echo "FAIL scenario 9: org-sync exited non-zero"; cat "$LOG"; exit 1; }
got=$(resolved_kid_path "acme/special")
[ "$got" = "/var/operator/custom-special" ] || { echo "FAIL scenario 9: KID_PATHS[acme/special] = '$got', expected '/var/operator/custom-special'"; exit 1; }
got=$(resolved_kid_path "acme/other")
[ "$got" = "$HOME/Hacking/other" ] || { echo "FAIL scenario 9: KID_PATHS[acme/other] = '$got'"; exit 1; }
auto_block_specials=$(awk '/^# === BEGIN AUTO-SYNC ===/,/^# === END AUTO-SYNC ===/' "$CONF" | grep -c 'acme/special' || true)
[ "$auto_block_specials" -eq 0 ] || { echo "FAIL scenario 9: 'acme/special' appears in auto-block ($auto_block_specials times)"; awk '/^# === BEGIN AUTO-SYNC ===/,/^# === END AUTO-SYNC ===/' "$CONF"; exit 1; }

# --- Scenario 10: malformed repos.conf aborts before rewrite -----------------
# Intentionally-broken manual section, not the baseline.
echo "  scenario 10: malformed repos.conf — abort, no rewrite, no clone..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep"
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
SHA=$(conf_sha)
if MOCK_GH_LIST_acme="foo" run_sync; then
    echo "FAIL scenario 10: org-sync returned 0 on malformed repos.conf"
    cat "$LOG"; exit 1
fi
assert_conf_unchanged "$SHA"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 10: expected 0 clones on malformed source, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 11: TOCTOU — concurrent operator edit during sync --------------
# org-sync.sh snapshots a SHA of CONF_REAL after sourcing, runs `gh
# repo list` (slow — seconds-to-minutes on a large org), then `mv`s a
# tmp file over CONF_REAL. An operator edit in that window would be
# silently clobbered unless the rewrite branch re-checks the SHA. The
# gh stub's MOCK_GH_LIST_MUTATE_CONF hook simulates that edit.
echo "  scenario 11: concurrent operator edit during gh call — TOCTOU recheck aborts the mv..."
write_baseline_conf '"acme"'
if MOCK_GH_LIST_MUTATE_CONF="$CONF" MOCK_GH_LIST_acme="foo" run_sync; then
    echo "FAIL scenario 11: org-sync returned 0 despite concurrent operator edit"
    cat "$LOG"; exit 1
fi
grep -q 'changed during sync' "$LOG" || { echo "FAIL scenario 11: expected TOCTOU log line"; cat "$LOG"; exit 1; }
grep -q '# concurrent operator edit' "$CONF" || { echo "FAIL scenario 11: operator's appended edit was erased — TOCTOU recheck failed"; cat "$CONF"; exit 1; }

echo "  PASS (11 scenarios: empty-orgs-noop, discover+clone, idempotent-rerun, existing-checkout-reuse, wrong-origin-fail-loud, gh-list-failure-no-mutation, auto-prune-on-disappear, spoof-host-fail-loud, same-org-manual-preserved, malformed-conf-abort, toctou-concurrent-edit-abort)"
