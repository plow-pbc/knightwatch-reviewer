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
# Manifest split (PR #75 round 3): org-sync writes
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
export LOCK="$TMPDIR/lock"
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
    rm -f "$LOCK"
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

# Production-shaped resolution: source repos.conf THEN repos.conf.auto
# in a sub-shell, same order as lib/tracked-repos.sh. Verifies the
# bash-visible contract end-to-end, not just text shape.
resolved_repos() {
    (
        declare -a REPOS=() ORGS=()
        declare -A KID_PATHS=() SOURCE_PATHS=()
        # shellcheck disable=SC1090
        [ -f "$CONF" ] && . "$CONF"
        # shellcheck disable=SC1090
        [ -f "$AUTO_CONF" ] && . "$AUTO_CONF"
        printf '%s\n' "${REPOS[@]}" | sort
    )
}
resolved_kid_path() {
    (
        declare -a REPOS=() ORGS=()
        declare -A KID_PATHS=() SOURCE_PATHS=()
        # shellcheck disable=SC1090
        [ -f "$CONF" ] && . "$CONF"
        # shellcheck disable=SC1090
        [ -f "$AUTO_CONF" ] && . "$AUTO_CONF"
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

echo "  PASS (9 scenarios: empty-orgs-truncates-stale, discover+clone, idempotent-rerun, existing-checkout-reuse, wrong-origin-fail-loud, spoof-host-fail-loud, gh-list-failure-no-mutation, auto-prune, same-org-manual-excluded)"
