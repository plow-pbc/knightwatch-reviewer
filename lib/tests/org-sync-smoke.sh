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
#      unchanged.
#   6. `gh repo list` failure → fail loud, repos.conf unchanged
#      (silently emptying the auto-block on a transient API error
#      would erase coverage).
#   7. Repo that was in the auto-block disappears from gh (archived,
#      deleted, fork-converted) → auto-prune: next rewrite drops it.

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
#     any args would mask that regression (probe 5, PR #75 round 1).
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
        # Required filter contract — drop either and archived/fork
        # repos pollute coverage on real gh state.
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
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=()
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
run_sync || { echo "FAIL scenario 1: org-sync exited non-zero"; cat "$LOG"; exit 1; }
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 1: file changed despite empty ORGS"; diff <(echo "$SHA_BEFORE") <(echo "$SHA_AFTER"); exit 1; }
n=$(count_gh "repo list")
[ "$n" -eq 0 ] || { echo "FAIL scenario 1: expected 0 gh repo list calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 2: discover + clone --------------------------------------------
echo "  scenario 2: new repo discovered → cloned, auto-block regenerated, manual preserved..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 2: org-sync exited non-zero"; cat "$LOG"; exit 1; }
# Two new repos cloned, neither pre-existed under SOURCE_BASE.
n=$(count_gh "repo clone")
[ "$n" -eq 2 ] || { echo "FAIL scenario 2: expected 2 clone calls, got $n"; cat "$STUB_GH_LOG"; exit 1; }
[ -d "$SOURCE_BASE/foo/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/foo not cloned"; exit 1; }
[ -d "$SOURCE_BASE/bar/.git" ] || { echo "FAIL scenario 2: $SOURCE_BASE/bar not cloned"; exit 1; }
# Manual entry survives.
grep -q '"manual/keep"' "$CONF" || { echo "FAIL scenario 2: manual entry erased from repos.conf"; cat "$CONF"; exit 1; }
grep -q '/var/manual' "$CONF" || { echo "FAIL scenario 2: manual KID_PATHS erased"; cat "$CONF"; exit 1; }
# Auto-block markers present (they MUST be — next tick's rewrite finds them by anchor).
grep -q '^# === BEGIN AUTO-SYNC ===$' "$CONF" || { echo "FAIL scenario 2: BEGIN marker missing"; cat "$CONF"; exit 1; }
grep -q '^# === END AUTO-SYNC ===$' "$CONF" || { echo "FAIL scenario 2: END marker missing"; cat "$CONF"; exit 1; }
# Sourced view: REPOS = manual ∪ auto, sorted.
expected=$'acme/bar\nacme/foo\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 2: resolved REPOS mismatch — got:"; echo "$got"; echo "expected:"; echo "$expected"; exit 1; }
# Sourced KID_PATHS for an auto entry expands $HOME/Hacking/<name>.
got=$(resolved_kid_path "acme/foo")
[ "$got" = "$HOME/Hacking/foo" ] || { echo "FAIL scenario 2: KID_PATHS[acme/foo] = '$got', expected '$HOME/Hacking/foo'"; exit 1; }

# --- Scenario 3: idempotent re-run -------------------------------------------
echo "  scenario 3: rerun with same gh state — cmp-skip, no rewrite, no new clones..."
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
MOCK_GH_LIST_acme=$'foo\nbar' run_sync || { echo "FAIL scenario 3: org-sync exited non-zero"; cat "$LOG"; exit 1; }
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 3: file changed on idempotent rerun"; diff <(echo "$SHA_BEFORE") <(echo "$SHA_AFTER"); exit 1; }
# No new clone calls — existing checkouts reused.
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 3: expected 0 clones on rerun, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 4: existing matching checkout reused ---------------------------
echo "  scenario 4: existing checkout with matching origin — reused, no clone..."
# Reset to baseline + pre-stage a matching checkout for a brand-new repo.
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
rm -rf "$SOURCE_BASE/baz"
mkdir -p "$SOURCE_BASE/baz"
git -C "$SOURCE_BASE/baz" init -q
git -C "$SOURCE_BASE/baz" remote add origin "git@github.com:acme/baz.git"
MOCK_GH_LIST_acme="baz" run_sync || { echo "FAIL scenario 4: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 clones (existing checkout), got $n"; cat "$STUB_GH_LOG"; exit 1; }
grep -q '"acme/baz"' "$CONF" || { echo "FAIL scenario 4: acme/baz not in rewritten repos.conf"; cat "$CONF"; exit 1; }

# --- Scenario 5: wrong-origin checkout fails loud ----------------------------
echo "  scenario 5: existing checkout with WRONG origin — fail loud, no rewrite..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
rm -rf "$SOURCE_BASE/evil"
mkdir -p "$SOURCE_BASE/evil"
git -C "$SOURCE_BASE/evil" init -q
git -C "$SOURCE_BASE/evil" remote add origin "git@github.com:attacker/evil.git"
if MOCK_GH_LIST_acme="evil" run_sync; then
    echo "FAIL scenario 5: org-sync returned 0 on wrong-origin checkout"
    cat "$LOG"; exit 1
fi
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 5: repos.conf was mutated despite fail-loud abort"; exit 1; }
grep -q 'origin does not match github.com/acme/evil' "$LOG" || { echo "FAIL scenario 5: expected origin-mismatch log line"; cat "$LOG"; exit 1; }
# Credential-bearing URLs MUST NOT leak into the log on mismatch.
# attacker-controlled remote stays out of the operator's log surface
# regardless of whether it carried inline credentials (probe 3, PR #75).
if grep -q 'attacker/evil' "$LOG"; then
    echo "FAIL scenario 5: raw remote URL leaked into log — credential exposure risk"
    cat "$LOG"; exit 1
fi

# --- Scenario 6: gh list failure aborts cleanly ------------------------------
echo "  scenario 6: gh repo list failure — fail loud, no rewrite, no clone..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("flakyorg")
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
if MOCK_GH_LIST_EXIT_flakyorg=1 run_sync; then
    echo "FAIL scenario 6: org-sync returned 0 on gh repo list failure"
    cat "$LOG"; exit 1
fi
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 6: repos.conf mutated despite gh failure — would erase prior auto-block on a transient API hiccup"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 6: expected 0 clones on listing failure, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 7: auto-prune --------------------------------------------------
echo "  scenario 7: repo disappears from gh — auto-block regenerated WITHOUT it..."
# First, seed the auto-block with two repos.
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
MOCK_GH_LIST_acme=$'alpha\nbeta' run_sync || { echo "FAIL scenario 7 setup: org-sync exited non-zero"; cat "$LOG"; exit 1; }
got=$(resolved_repos)
expected=$'acme/alpha\nacme/beta\nmanual/keep'
[ "$got" = "$expected" ] || { echo "FAIL scenario 7 setup: seed REPOS mismatch — got:"; echo "$got"; exit 1; }
# Now drop `beta` from the gh listing (archived / deleted / fork-converted).
MOCK_GH_LIST_acme="alpha" run_sync || { echo "FAIL scenario 7: org-sync exited non-zero on prune tick"; cat "$LOG"; exit 1; }
got=$(resolved_repos)
expected=$'acme/alpha\nmanual/keep'
[ "$got" = "$expected" ] || { echo "FAIL scenario 7: auto-prune failed — got:"; echo "$got"; echo "expected:"; echo "$expected"; exit 1; }
# `beta` entries must NOT appear anywhere in the file (no stale KID_PATHS).
if grep -q 'acme/beta' "$CONF"; then
    echo "FAIL scenario 7: 'acme/beta' still referenced in repos.conf after prune"
    cat "$CONF"; exit 1
fi

# --- Scenario 8: spoof-host origin (substring vs exact) ---------------------
# Probe 2, PR #75 round 1: a `*"github.com:$full"` glob would let
# `git@evilgithub.com:$full.git` pass — the substring is contained in
# the spoof URL. Exact canonical-form match closes that.
echo "  scenario 8: spoof-host origin (evilgithub.com) — fail loud, no rewrite..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
rm -rf "$SOURCE_BASE/spoof"
mkdir -p "$SOURCE_BASE/spoof"
git -C "$SOURCE_BASE/spoof" init -q
git -C "$SOURCE_BASE/spoof" remote add origin "git@evilgithub.com:acme/spoof.git"
if MOCK_GH_LIST_acme="spoof" run_sync; then
    echo "FAIL scenario 8: org-sync accepted evilgithub.com spoof"
    cat "$LOG"; exit 1
fi
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 8: repos.conf mutated after spoof-host rejection"; exit 1; }

# --- Scenario 9: same-org manual entry preserved -----------------------------
# Probe 6, PR #75 round 1: existing scenarios only cover manual entries
# in a DIFFERENT org from the synced one. The contract that matters is
# "manual wins for the same org" — operator can pin a custom KID_PATHS
# for `acme/foo` and have org-sync of `acme` skip adding it to AUTO.
echo "  scenario 9: same-org manual entry — auto-block must NOT shadow it..."
cat > "$CONF" <<'CONF'
REPOS=("acme/special")
declare -A KID_PATHS=(["acme/special"]="/var/operator/custom-special")
declare -A SOURCE_PATHS=(["acme/special"]="/var/operator/custom-special")
ORGS=("acme")
CONF
MOCK_GH_LIST_acme=$'special\nother' run_sync || { echo "FAIL scenario 9: org-sync exited non-zero"; cat "$LOG"; exit 1; }
# `acme/special` stays in MANUAL section with the operator's custom path.
got=$(resolved_kid_path "acme/special")
[ "$got" = "/var/operator/custom-special" ] || { echo "FAIL scenario 9: KID_PATHS[acme/special] = '$got', expected '/var/operator/custom-special' — auto-block shadowed manual entry"; exit 1; }
# `acme/other` got added to the auto-block.
got=$(resolved_kid_path "acme/other")
[ "$got" = "$HOME/Hacking/other" ] || { echo "FAIL scenario 9: KID_PATHS[acme/other] = '$got', expected '$HOME/Hacking/other'"; exit 1; }
# No duplicate `acme/special` entry inside the auto-block (would resolve
# last-wins under bash and silently overwrite the manual custom path).
auto_block_specials=$(awk '/^# === BEGIN AUTO-SYNC ===/,/^# === END AUTO-SYNC ===/' "$CONF" | grep -c 'acme/special' || true)
[ "$auto_block_specials" -eq 0 ] || { echo "FAIL scenario 9: 'acme/special' appears in auto-block ($auto_block_specials times) — would shadow manual custom path"; awk '/^# === BEGIN AUTO-SYNC ===/,/^# === END AUTO-SYNC ===/' "$CONF"; exit 1; }

# --- Scenario 10: malformed repos.conf aborts before rewrite -----------------
# Probe 1, PR #75 round 1: a bash syntax error in repos.conf must abort
# org-sync.sh BEFORE the manual-fragment source produces a clipped REPOS
# view that erases legitimate manual entries on rewrite.
echo "  scenario 10: malformed repos.conf — abort, no rewrite, no clone..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep"
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
if MOCK_GH_LIST_acme="foo" run_sync; then
    echo "FAIL scenario 10: org-sync returned 0 on malformed repos.conf"
    cat "$LOG"; exit 1
fi
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 10: repos.conf mutated despite malformed source"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 10: expected 0 clones on malformed source, got $n"; cat "$STUB_GH_LOG"; exit 1; }

# --- Scenario 11: config.env REPOS override conflict -------------------------
# Probe 7, PR #75 round 1: lib/tracked-repos.sh sources config.env AFTER
# repos.conf so config.env's REPOS=(...) wins. Letting org-sync rewrite
# repos.conf while a config.env override is in force would calcify a
# split source of truth (consumers resolve to override; operators read
# rewritten manifest). Fail loud.
echo "  scenario 11: config.env defines REPOS — abort, no rewrite..."
cat > "$CONF" <<'CONF'
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")
CONF
cat > "$STATE_DIR/config.env" <<'CONF'
REPOS=("legacy/override")
CONF
SHA_BEFORE=$(sha1sum "$CONF" | awk '{print $1}')
if MOCK_GH_LIST_acme="foo" run_sync; then
    echo "FAIL scenario 11: org-sync returned 0 with config.env REPOS override active"
    cat "$LOG"; exit 1
fi
SHA_AFTER=$(sha1sum "$CONF" | awk '{print $1}')
[ "$SHA_BEFORE" = "$SHA_AFTER" ] || { echo "FAIL scenario 11: repos.conf mutated despite config.env REPOS override"; exit 1; }
grep -q 'config.env defines REPOS' "$LOG" || { echo "FAIL scenario 11: expected config.env-override log line"; cat "$LOG"; exit 1; }
rm -f "$STATE_DIR/config.env"

echo "  PASS (11 scenarios: empty-orgs-noop, discover+clone, idempotent-rerun, existing-checkout-reuse, wrong-origin-fail-loud, gh-list-failure-no-mutation, auto-prune-on-disappear, spoof-host-fail-loud, same-org-manual-preserved, malformed-conf-abort, config.env-override-abort)"
