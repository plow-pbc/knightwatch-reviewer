#!/usr/bin/env bash
# Smoke test for org-sync.sh — the hourly producer that writes
# $STATE_DIR/repos.conf.auto from `gh repo list <ORGS>` minus the
# operator's manual REPOS in repos.conf. Each scenario's echo line
# names the business requirement; read the scenarios for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t org-sync-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# HOME first so $HOME/services/kwr-repos lands inside the sandbox. Clone
# path is always $HOME/services/kwr-repos/<name> in production (no
# SOURCE_BASE knob), so the smoke and prod share one path contract — no
# risk of cloning to one place while asserting another. The org-sync.sh
# `mkdir -p` for the base dir is the script's own responsibility; the
# .local/bin mkdir below is just the gh-stub install location.
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

export STATE_DIR="$TMPDIR/state"
export LOG="$STATE_DIR/org-sync.log"
# LOCK NOT overridden — production default $STATE_DIR/org-sync.lock
# flows through (STATE_DIR is sandboxed), exercising the shared-lock
# path systemd uses.
# Fixture path only — org-sync no longer takes a CONF override; it reads
# REPOS_CONF_FILE, whose single owner is lib/tracked-repos.sh. This is just
# where the scenarios write the manifest, and it matches that default.
MANIFEST="$STATE_DIR/repos.conf"
# Deployment-env scrub lives once in the justfile's `test` recipe.
export AUTO_CONF="$STATE_DIR/repos.conf.auto"
mkdir -p "$STATE_DIR"

export REVIEWER_LIB_DIR="$TMPDIR/lib"
mkdir -p "$REVIEWER_LIB_DIR"
cp "$PROJECT_ROOT/lib/tracked-repos.sh" "$REVIEWER_LIB_DIR/tracked-repos.sh"
# org-sync.sh sources conventions.sh (kwr-config pull helper) before tracked-repos.
cp "$PROJECT_ROOT/lib/conventions.sh" "$REVIEWER_LIB_DIR/conventions.sh"
cp "$PROJECT_ROOT/lib/gh-retry.sh"      "$REVIEWER_LIB_DIR/gh-retry.sh"    # org-sync sources it (gh_retry + the pause)
cp "$PROJECT_ROOT/lib/state-io.sh"      "$REVIEWER_LIB_DIR/state-io.sh"    # gh-retry.sh sources it

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
        # Each flag pair is behavior-bearing AT ITS VALUE — not just
        # presence. --jq '.[].nameWithOwner' would still trigger a
        # presence-only check and pass, but it returns "org/name"
        # which org-sync would prefix again into "org/org/name".
        argv=" $* "
        for needle in "--source" "--no-archived" "--limit 1000" "--json name" "--jq .[].name"; do
            case "$argv" in
                *" $needle "*) ;;
                *)
                    echo "STUB FAIL: gh repo list missing '$needle': $*" >&2
                    exit 2
                    ;;
            esac
        done
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
    # Do NOT rm the lock file — flock releases on FD close.
    bash "$PROJECT_ROOT/org-sync.sh" >/dev/null 2>&1
}

count_gh() { grep -c "^GH $1" "$STUB_GH_LOG" 2>/dev/null || true; }

# Manifest fixture helpers. Per ~/.claude/TESTING.md: one factory with
# overrides, customize only what matters per scenario.
write_baseline_conf() {
    local orgs="${1:-}"
    cat > "$MANIFEST" <<CONF
REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=($orgs)
CONF
}
auto_sha() { [ -f "$AUTO_CONF" ] && sha1sum "$AUTO_CONF" | awk '{print $1}' || echo "absent"; }
make_checkout() {
    local dest="$HOME/services/kwr-repos/$1"
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$2"
}
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
[ -d "$HOME/services/kwr-repos/foo/.git" ] || { echo "FAIL scenario 2: $HOME/services/kwr-repos/foo not cloned"; exit 1; }
[ -d "$HOME/services/kwr-repos/bar/.git" ] || { echo "FAIL scenario 2: $HOME/services/kwr-repos/bar not cloned"; exit 1; }
# repos.conf MUST NOT be modified — that's the structural promise of
# the split-file design. Bit-exact assert beats the prior marker-block
# grep (which only proved the markers existed).
expected_conf='REPOS=("manual/keep")
declare -A KID_PATHS=(["manual/keep"]="/var/manual")
declare -A SOURCE_PATHS=(["manual/keep"]="/var/manual")
ORGS=("acme")'
[ "$(cat "$MANIFEST")" = "$expected_conf" ] || { echo "FAIL scenario 2: repos.conf was modified — split-file boundary breached"; diff <(echo "$expected_conf") "$MANIFEST"; exit 1; }
[ -f "$AUTO_CONF" ] || { echo "FAIL scenario 2: $AUTO_CONF not created"; exit 1; }
expected=$'acme/bar\nacme/foo\nmanual/keep'
got=$(resolved_repos)
[ "$got" = "$expected" ] || { echo "FAIL scenario 2: resolved REPOS mismatch — got"; echo "$got"; exit 1; }
got=$(resolved_kid_path "acme/foo")
[ "$got" = "$HOME/services/kwr-repos/foo" ] || { echo "FAIL scenario 2: KID_PATHS[acme/foo] = '$got'"; exit 1; }
# SOURCE_PATHS regression fence: cross-repo grep surface stays an
# explicit operator opt-in. Auto-discovered repos MUST NOT appear in
# SOURCE_PATHS — re-introducing them re-opens the private-sibling
# exposure path through materialize_sibling_symlinks.
if grep -q '^SOURCE_PATHS\[' "$AUTO_CONF"; then
    echo "FAIL scenario 2: auto file emits SOURCE_PATHS — re-opens cross-repo source exposure"
    grep '^SOURCE_PATHS\[' "$AUTO_CONF"; exit 1
fi
got=$(
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
make_checkout baz "git@github.com:acme/baz.git"
MOCK_GH_LIST_acme="baz" run_sync || { echo "FAIL scenario 4: org-sync exited non-zero"; cat "$LOG"; exit 1; }
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 4: expected 0 clones (existing checkout), got $n"; cat "$STUB_GH_LOG"; exit 1; }
grep -q '"acme/baz"' "$AUTO_CONF" || { echo "FAIL scenario 4: acme/baz not in $AUTO_CONF"; cat "$AUTO_CONF"; exit 1; }

# --- Scenario 5: wrong-origin checkout fails loud + no credential leak --------
echo "  scenario 5: existing checkout with WRONG origin — fail loud, auto unchanged, no log leak..."
write_baseline_conf '"acme"'
rm -f "$AUTO_CONF"
SHA=$(auto_sha)
make_checkout evil "git@github.com:attacker/evil.git"
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
make_checkout spoof "git@evilgithub.com:acme/spoof.git"
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
cat > "$MANIFEST" <<'CONF'
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
[ "$got" = "$HOME/services/kwr-repos/other" ] || { echo "FAIL scenario 9: KID_PATHS[acme/other] = '$got'"; exit 1; }
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
rm -rf "$HOME/services/kwr-repos/cant-clone"
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
[ ! -e "$HOME/services/kwr-repos/cant-clone" ] || { echo "FAIL scenario 10: partial clone left behind at $HOME/services/kwr-repos/cant-clone"; ls -la "$HOME/services/kwr-repos/cant-clone"; exit 1; }
# Recovery tick: with MOCK_GH_CLONE_EXIT unset, clone succeeds; auto
# file gains the new entry. The dest is fresh — no smuggled state
# from the prior failed attempt.
MOCK_GH_LIST_acme="cant-clone" run_sync || { echo "FAIL scenario 10 recovery: org-sync exited non-zero"; cat "$LOG"; exit 1; }
[ -d "$HOME/services/kwr-repos/cant-clone/.git" ] || { echo "FAIL scenario 10 recovery: clone didn't happen on recovery tick"; exit 1; }
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

# ---- scenario 12: kwr-config overlay — cache pulled + config.json org enumerated
# Exercises the production KWR_CONFIG_REPO path end-to-end: org-sync clones the
# operator's kwr-config (inside the sync lock), and tracked-repos.sh unions its
# config.json orgs onto repos.conf's, so the overlay org is discovered.
echo "  scenario 12: kwr-config overlay — cache cloned + config.json org enumerated..."
KCFG_SRC="$TMPDIR/kwr-config-src"; git init -q -b main "$KCFG_SRC"
(
    cd "$KCFG_SRC"; git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf '{ "orgs": ["overlayorg"], "repos": [] }\n' > config.json
    git add config.json; git commit -qm init
)
KCFG_BARE="$TMPDIR/kwr-config.git"; git clone -q --bare "$KCFG_SRC" "$KCFG_BARE"
git -C "$KCFG_SRC" remote add origin "$KCFG_BARE"   # so a later commit can push an update
KCFG_CACHE="$TMPDIR/kwr-config-cache"
cat > "$STATE_DIR/config.env" <<ENV
export KWR_CONFIG_REPO="$KCFG_BARE"
export KWR_CONFIG_DIR="$KCFG_CACHE"
ENV
write_baseline_conf "baseorg"
export MOCK_GH_LIST_baseorg="baseorg/a" MOCK_GH_LIST_overlayorg="overlayorg/b"
run_sync || { echo "FAIL scenario 12: sync exited non-zero"; cat "$LOG"; exit 1; }
[ -f "$KCFG_CACHE/config.json" ] || { echo "FAIL scenario 12: kwr-config cache not cloned"; cat "$LOG"; exit 1; }
grep -q "^GH repo list overlayorg" "$STUB_GH_LOG" || { echo "FAIL scenario 12: config.json overlay org not enumerated"; cat "$STUB_GH_LOG"; exit 1; }
grep -q "^GH repo list baseorg"   "$STUB_GH_LOG" || { echo "FAIL scenario 12: repos.conf base org not enumerated"; exit 1; }
grep -q 'overlayorg/b' "$AUTO_CONF" || { echo "FAIL scenario 12: overlay repo not written to auto file"; cat "$AUTO_CONF"; exit 1; }

# 12b: steady-state `git pull --ff-only` — operator edits to kwr-config (here a
# new org) must reach the cache on the next tick, not just first-clone.
(
    cd "$KCFG_SRC"
    printf '{ "orgs": ["overlayorg", "overlay2"], "repos": [] }\n' > config.json
    git add config.json; git commit -qm "add overlay2"; git push -q origin main
)
export MOCK_GH_LIST_overlay2="overlay2/c"
run_sync || { echo "FAIL scenario 12b: re-sync exited non-zero"; cat "$LOG"; exit 1; }
grep -q '"overlay2"' "$KCFG_CACHE/config.json" || { echo "FAIL scenario 12b: cache not refreshed by ff-only pull"; cat "$KCFG_CACHE/config.json"; exit 1; }
grep -q "^GH repo list overlay2" "$STUB_GH_LOG" || { echo "FAIL scenario 12b: steady-state pull did not enumerate the newly-added org"; cat "$STUB_GH_LOG"; exit 1; }

# 12c: transient pull failure → WARN-and-continue on the last-good cache. Remove
# the remote so the same-origin ff-pull fails; the cached config.json (last-good)
# must still drive enumeration, and the tick must exit 0 (not fatal).
echo "  scenario 12c: pull failure → WARN, last-good cache reused (zero exit, overlay still enumerated)..."
rm -rf "$KCFG_BARE"
export MOCK_GH_LIST_baseorg="baseorg/a" MOCK_GH_LIST_overlayorg="overlayorg/b" MOCK_GH_LIST_overlay2="overlay2/c"
run_sync || { echo "FAIL scenario 12c: sync must exit 0 on transient pull failure (last-good cache)"; cat "$LOG"; exit 1; }
grep -q 'kwr-config sync failed' "$LOG" || { echo "FAIL scenario 12c: expected WARN log on pull failure"; cat "$LOG"; exit 1; }
grep -q "^GH repo list overlay2" "$STUB_GH_LOG" || { echo "FAIL scenario 12c: last-good cached overlay org not enumerated after pull failure"; cat "$STUB_GH_LOG"; exit 1; }
unset MOCK_GH_LIST_overlayorg MOCK_GH_LIST_overlay2

# ---- scenario 13: active-but-broken kwr-config → fail loud, no auto mutation
# A set KWR_CONFIG_REPO whose config.json is malformed must abort BEFORE the
# ORGS-empty prune can erase a valid repos.conf.auto (data-integrity probe).
echo "  scenario 13: KWR_CONFIG_REPO set + malformed config.json → fail loud, auto file untouched..."
KCFG_BAD_SRC="$TMPDIR/kwr-bad-src"; git init -q -b main "$KCFG_BAD_SRC"
(
    cd "$KCFG_BAD_SRC"; git config user.email t@t; git config user.name t; git config commit.gpgsign false
    printf '{ not json\n' > config.json; git add config.json; git commit -qm bad
)
KCFG_BAD_BARE="$TMPDIR/kwr-bad.git"; git clone -q --bare "$KCFG_BAD_SRC" "$KCFG_BAD_BARE"
cat > "$STATE_DIR/config.env" <<ENV
export KWR_CONFIG_REPO="$KCFG_BAD_BARE"
export KWR_CONFIG_DIR="$TMPDIR/kwr-bad-cache"
ENV
SHA_BEFORE=$(auto_sha)
if MOCK_GH_LIST_baseorg="baseorg/a" run_sync; then
    echo "FAIL scenario 13: sync should have failed loud on malformed config.json"; cat "$LOG"; exit 1
fi
grep -q 'FATAL: KWR_CONFIG_REPO set but' "$LOG" || { echo "FAIL scenario 13: expected FATAL log line"; cat "$LOG"; exit 1; }
[ "$(auto_sha)" = "$SHA_BEFORE" ] || { echo "FAIL scenario 13: auto file mutated despite fail-loud abort"; exit 1; }
rm -f "$STATE_DIR/config.env"

# --- Scenario 14: REPOS_CONF_FILE is the manifest owner, not $STATE_DIR ------
# org-sync computes its MANUAL set from the manifest AND sources the loader. If
# those two resolve different files the manual set comes back empty, every
# manually listed repo falls into AUTO, and org-sync clones it (or dies on a
# non-canonical origin) every hour. Pin it with a DIVERGENT pair: the override
# lists acme/pinned as manual, the stale default does not. Reading the wrong one
# puts pinned in the auto file AND clones it — "pinned" is deliberately a name no
# earlier scenario checked out, so the clone probe is reachable (reusing "foo"
# made it vacuous: scenario 2 already left a matching-origin checkout behind).
echo "  scenario 14: REPOS_CONF_FILE overrides the default manifest path..."
write_baseline_conf '"acme"'                      # stale default: no acme/foo
MANIFEST_DIR="$TMPDIR/manifest"; mkdir -p "$MANIFEST_DIR"
cat > "$MANIFEST_DIR/repos.conf" <<'CONF'
REPOS=("acme/pinned")
declare -A KID_PATHS=(["acme/pinned"]="/var/pinned")
declare -A SOURCE_PATHS=(["acme/pinned"]="/var/pinned")
ORGS=("acme")
CONF
rm -f "$AUTO_CONF"
# Deliver the override through config.env, NOT the command env. This is the
# shape that discriminates: the bug was an ORDERING one — org-sync resolved the
# manifest path at the top of the file, before config.env was sourced — so a
# per-command REPOS_CONF_FILE was already bound by then and passed on the broken
# code too. Only a config.env-delivered value is unset at that point.
cat > "$STATE_DIR/config.env" <<ENV
export REPOS_CONF_FILE="$MANIFEST_DIR/repos.conf"
ENV
MOCK_GH_LIST_acme="pinned" run_sync \
    || { echo "FAIL scenario 14: org-sync exited non-zero"; cat "$LOG"; exit 1; }
if grep -q '"acme/pinned"' "$AUTO_CONF" 2>/dev/null; then
    echo "FAIL scenario 14: acme/pinned landed in the auto file — org-sync read the stale default manifest, not REPOS_CONF_FILE"
    cat "$AUTO_CONF"; exit 1
fi
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 14: manual repo was cloned ($n) — manifest path owners diverged"; cat "$STUB_GH_LOG"; exit 1; }
rm -f "$AUTO_CONF" "$STATE_DIR/config.env"
# --- Scenario 15: GitHub rate-limit pause — skip the tick, touch nothing -------
# The manifest rewrite below the discovery loop is unconditional, so a paused
# tick must not reach it: a short or empty DISCOVERED would be published as the
# org's full coverage and erase every repo that was never listed. Same
# no-mutation contract as scenario 7's listing failure.
echo "  scenario 15: github rate-limited — tick skipped, auto file untouched, no clone..."
write_baseline_conf '"acme"'
echo 'REPOS+=("prior/auto")' > "$AUTO_CONF"
SHA_BEFORE=$(auto_sha)
: > "$LOG"
printf '%s\n' "$(( $(date +%s) + 300 ))" > "$STATE_DIR/gh-rate-limited-until"
MOCK_GH_LIST_acme=$'alpha\nbeta' run_sync || { echo "FAIL scenario 15: org-sync must exit 0 on a paused tick (a back-off is not a failure)"; cat "$LOG"; exit 1; }
rm -f "$STATE_DIR/gh-rate-limited-until"
assert_auto_unchanged "$SHA_BEFORE"
n=$(count_gh "repo clone")
[ "$n" -eq 0 ] || { echo "FAIL scenario 15: expected 0 clones while rate-limited, got $n"; exit 1; }
grep -q 'github rate-limited — skipping org sync' "$LOG" || { echo "FAIL scenario 15: expected the rate-limit skip log line"; cat "$LOG"; exit 1; }


echo "  PASS (15 scenarios: empty-orgs-truncates-stale, discover+clone, idempotent-rerun, existing-checkout-reuse, wrong-origin-fail-loud, spoof-host-fail-loud, gh-list-failure-no-mutation, auto-prune, same-org-manual-excluded, clone-failure-no-mutation, lock-held-defers, kwr-config-overlay, broken-config-fail-loud, repos-conf-file-override, rate-limit-skips-tick)"
