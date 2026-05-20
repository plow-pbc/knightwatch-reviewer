#!/usr/bin/env bash
# Smoke test for install.sh.
#
# Runs the installer against a sandboxed INSTALL_DIR + SYSTEMD_DIR with
# stubbed `sudo` (drops the sudo wrapper, runs the inner cmd directly)
# and `systemctl` (logs is-enabled/is-active/daemon-reload/enable
# invocations to a stub log) so the test exercises the real install
# logic without touching /etc/systemd/system or requiring real privilege.
#
# Scenarios:
#   1. First-run install: every script + dir symlinked into INSTALL_DIR;
#      every systemd unit copied to SYSTEMD_DIR; daemon-reload called;
#      every timer enable+start'd.
#   2. Idempotent re-run: nothing changes — no unit copy, no
#      daemon-reload, no enable (because all timers already-enabled
#      according to the systemctl stub).
#   3. New-unit re-run: drop a fake new unit into systemd/ and re-run;
#      the new unit copies + enables, the unchanged ones don't.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t install-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandboxed install destinations — install.sh honors these env vars.
export INSTALL_DIR="$TMPDIR/pr-reviewer"
export SYSTEMD_DIR="$TMPDIR/etc-systemd-system"
mkdir -p "$SYSTEMD_DIR"

# Fake HOME so the test's stub binaries live under a path we control.
# install.sh no longer prepends $HOME/.local/bin to PATH (security:
# privilege-escalation surface), so the test sets PATH itself when it
# invokes install.sh — see run_install() below.
export HOME="$TMPDIR/home"
export STUB_BIN="$HOME/.local/bin"
mkdir -p "$STUB_BIN"

# Stub log for systemctl / sudo invocations the script makes.
STUB_LOG="$TMPDIR/stub-calls.log"
export STUB_LOG

# `sudo`: drop the wrapper, run the inner cmd directly. SYSTEMD_DIR is
# already user-writable, so sudo isn't actually needed here — the stub
# just makes that explicit.
cat > "$STUB_BIN/sudo" <<'STUB'
#!/bin/bash
echo "SUDO $*" >> "$STUB_LOG"
exec "$@"
STUB
chmod +x "$STUB_BIN/sudo"

# `systemctl`: log every invocation. is-enabled / is-active default to
# "not enabled / not active" so scenario 1 enables every timer; scenario
# 2 sets MOCK_TIMERS_ENABLED=1 to flip them to enabled+active so the
# script's idempotent path is exercised. MOCK_NEWLY_ADDED_TIMERS is a
# space-separated list of timer names that should ALWAYS report
# "not enabled" even when MOCK_TIMERS_ENABLED is set — used by
# scenario 3 to model "the existing timers are already enabled, but a
# brand-new timer just landed and still needs `enable --now`."
cat > "$STUB_BIN/systemctl" <<'STUB'
#!/bin/bash
echo "SYSTEMCTL $*" >> "$STUB_LOG"
case "$1" in
    is-enabled|is-active)
        unit="$2"
        for newly in ${MOCK_NEWLY_ADDED_TIMERS:-}; do
            if [ "$unit" = "$newly" ]; then exit 1; fi  # not enabled
        done
        if [ -n "${MOCK_TIMERS_ENABLED:-}" ]; then
            exit 0  # enabled + active
        fi
        exit 1  # not enabled / not active
        ;;
    daemon-reload|enable)
        exit 0  # always succeed (the call itself is what we assert on)
        ;;
    *)
        exit 0
        ;;
esac
STUB
chmod +x "$STUB_BIN/systemctl"

# `uv`: stub fail-louds on unexpected argv and synthesizes `vulture`
# on `tool install`, so smoke can only pass when install.sh fires it.
# shellcheck source=lib/tests/uv-stub.sh
. "$SCRIPT_DIR/tests/uv-stub.sh"
write_uv_stub "$STUB_BIN"

# Wrapper that runs install.sh with PATH set to find our stubs. The
# script itself doesn't manipulate PATH (no privilege-escalation seam),
# so test interception is the test's responsibility.
run_install() {
    PATH="$STUB_BIN:$PATH" bash "$@" >/dev/null 2>&1
}

# Count helpers — read $STUB_LOG for assertions. grep -c prints the
# count even when the count is 0, but exits non-zero on no-match;
# `|| true` keeps the function single-valued instead of double-printing.
count_stub() {
    local n
    n=$(grep -c "^$1" "$STUB_LOG" 2>/dev/null || true)
    echo "${n:-0}"
}

# Pre-count the units in the repo so assertions can scale if more are
# added without re-counting by hand.
shopt -s nullglob
PROD_UNITS=( "$PROJECT_ROOT"/systemd/*.service "$PROJECT_ROOT"/systemd/*.timer )
PROD_TIMERS=( "$PROJECT_ROOT"/systemd/*.timer )
shopt -u nullglob

# Discover the same script list install.sh derives from the unit files'
# ExecStart= directives, via the shared parser in lib/systemd-units.sh.
# A new poller landing as <name>.service picks up coverage here without
# a parallel hand-maintained list to keep in sync.
# shellcheck source=lib/systemd-units.sh
. "$PROJECT_ROOT/lib/systemd-units.sh"
mapfile -t PROD_SCRIPTS < <(list_execstart_shell_scripts "$PROJECT_ROOT" "$PROJECT_ROOT"/systemd/*.service)
[[ ${#PROD_SCRIPTS[@]} -ge 1 ]] || { echo "FAIL setup: no scripts discovered from production unit files"; exit 1; }

# All scenarios run install.sh from a temp overlay (symlinks of the
# project tree + a divergent repos.conf written into the overlay only),
# never against $PROJECT_ROOT directly. The boundary rule: tests must
# never write to a path that real install.sh treats as live operator
# config. $PROJECT_ROOT/repos.conf is gitignored but install.sh treats
# it as the operator's manifest; a smoke fixture written there leaks
# into a subsequent direct ./install.sh invocation.
#
# Helper: build an overlay containing a divergent repos.conf install.sh
# will accept (i.e., not byte-identical to .example, so it skips the
# bootstrap-exit path).
make_install_overlay() {
    local overlay="$1"
    mkdir -p "$overlay"
    for entry in "$PROJECT_ROOT"/*; do
        local name="$(basename "$entry")"
        [ "$name" = "repos.conf" ] && continue   # tests own this in the overlay
        ln -snf "$entry" "$overlay/$name"
    done
    cat > "$overlay/repos.conf" <<'CONF'
# Smoke fixture — divergent from repos.conf.example so install.sh skips
# the bootstrap-exit guard. Confined to the overlay so it never lands
# in $PROJECT_ROOT.
REPOS=("smoke-org/smoke-repo")
declare -A KID_PATHS=(["smoke-org/smoke-repo"]="$HOME/Hacking/smoke-checkout")
declare -A SOURCE_PATHS=(["smoke-org/smoke-repo"]="$HOME/Hacking/smoke-checkout")
CONF
}

# Shared overlay for scenarios 1+2 (idempotent re-run depends on
# scenario 1's INSTALL_DIR/SYSTEMD_DIR state, so they reuse the same
# REPO_DIR too).
SHARED_OVERLAY="$TMPDIR/repo-overlay-shared"
make_install_overlay "$SHARED_OVERLAY"

# --- Scenario 1: first-run install -----------------------------------------
echo "  scenario 1: first-run install — every unit copied, every timer enabled..."
: > "$STUB_LOG"
run_install "$SHARED_OVERLAY/install.sh" || { echo "FAIL scenario 1: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

# Symlinks present (script names sourced from the unit files, same as install.sh)
for s in "${PROD_SCRIPTS[@]}"; do
    [ -L "$INSTALL_DIR/$s" ] || { echo "FAIL scenario 1: $INSTALL_DIR/$s not a symlink"; exit 1; }
done
for d in lib docs prompts; do
    [ -L "$INSTALL_DIR/$d" ] || { echo "FAIL scenario 1: $INSTALL_DIR/$d not a symlink"; exit 1; }
done

# Render the same @KID_RW_PATHS@ / @KID_INDEX_RW_PATHS@ / @KWR_CLONE_ROOT@
# values install.sh derives from the overlay's repos.conf, so the cmp
# below compares against what install.sh actually wrote (post-
# substitution). Sources in a subshell so the smoke's own REPOS /
# KID_PATHS state isn't perturbed.
EXPECTED_KID_RW_PATHS=$(
    REPOS=( ); declare -A KID_PATHS=( )
    # shellcheck disable=SC1091
    . "$SHARED_OVERLAY/repos.conf"
    # Both render shapes prefix paths with `-` so a missing checkout
    # doesn't fail systemd unit start (matches install.sh).
    paths=$(printf '%s\n' "${KID_PATHS[@]}" | sort -u | sed 's|^|-|' | tr '\n' ' ')
    printf '%s' "${paths% }"
)
EXPECTED_KID_INDEX_RW_PATHS=$(
    REPOS=( ); declare -A KID_PATHS=( )
    # shellcheck disable=SC1091
    . "$SHARED_OVERLAY/repos.conf"
    paths=$(printf '%s\n' "${KID_PATHS[@]}" | sort -u | sed 's|$|/.keepitdry|; s|^|-|' | tr '\n' ' ')
    printf '%s' "${paths% }"
)
# KWR_CLONE_ROOT defaults to $HOME/services/kwr-repos in
# lib/tracked-repos.sh. The sandboxed HOME is $TMPDIR/home; install.sh
# substitutes the resolved literal path into the unit template.
EXPECTED_KWR_CLONE_ROOT="$HOME/services/kwr-repos"

# Every unit file copied
for unit in "${PROD_UNITS[@]}"; do
    name="$(basename "$unit")"
    [ -f "$SYSTEMD_DIR/$name" ] || { echo "FAIL scenario 1: $SYSTEMD_DIR/$name missing"; exit 1; }
    if grep -qE '@(KID_(RW|INDEX_RW)_PATHS|KWR_CLONE_ROOT)@' "$unit"; then
        # Templated unit — compare against rendered version.
        rendered_expected="$TMPDIR/${name}.expected"
        sed -e "s|@KID_INDEX_RW_PATHS@|$EXPECTED_KID_INDEX_RW_PATHS|g" \
            -e "s|@KID_RW_PATHS@|$EXPECTED_KID_RW_PATHS|g" \
            -e "s|@KWR_CLONE_ROOT@|$EXPECTED_KWR_CLONE_ROOT|g" \
            "$unit" > "$rendered_expected"
        cmp -s "$rendered_expected" "$SYSTEMD_DIR/$name" || { echo "FAIL scenario 1: $name rendered content differs from installed"; diff "$rendered_expected" "$SYSTEMD_DIR/$name"; exit 1; }
        # Verbose check: no placeholder leaks into the installed unit.
        grep -qE '@(KID_(RW|INDEX_RW)_PATHS|KWR_CLONE_ROOT)@' "$SYSTEMD_DIR/$name" && { echo "FAIL scenario 1: installed $name still contains a @...@ placeholder (substitution broke)"; exit 1; }
    else
        cmp -s "$unit" "$SYSTEMD_DIR/$name" || { echo "FAIL scenario 1: $name content differs from source"; exit 1; }
    fi
done

# Regression pin: pr-reviewer.service and pr-reviewer-kid-refresh.service
# both run kid prior-art queries (or build the index), and chromadb's
# SQLite backend writes WAL/journal files even on read-only queries. If
# either unit drops the placeholder from its actual ReadWritePaths=
# directive, kid lookups fail with "attempt to write a readonly
# database" under ProtectHome=read-only and reviews silently degrade
# to kid-less. The grep targets the live `ReadWritePaths=` line (no
# leading `#`) so a placeholder-only-in-comment edit can't sneak past
# the assertion while the actual directive ships broken — that was the
# exact gap knightwatch flagged on PR #41 round 1.
declare -A REQUIRED_PLACEHOLDER=(
    [pr-reviewer.service]='@KID_INDEX_RW_PATHS@'
    [pr-reviewer-kid-refresh.service]='@KID_RW_PATHS@'
)
for required in "${!REQUIRED_PLACEHOLDER[@]}"; do
    placeholder="${REQUIRED_PLACEHOLDER[$required]}"
    grep -E "^ReadWritePaths=.*${placeholder}" "$PROJECT_ROOT/systemd/$required" >/dev/null \
        || { echo "FAIL scenario 1: $required's ReadWritePaths= line is missing $placeholder — kid queries will hit chromadb readonly errors"; exit 1; }
done

# daemon-reload was called once (units actually changed)
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "1" ] || { echo "FAIL scenario 1: expected exactly 1 daemon-reload"; cat "$STUB_LOG"; exit 1; }

# enable --now called for every timer
n_enable="$(count_stub 'SYSTEMCTL enable --now')"
[ "$n_enable" = "${#PROD_TIMERS[@]}" ] || { echo "FAIL scenario 1: expected ${#PROD_TIMERS[@]} enable --now calls, got $n_enable"; cat "$STUB_LOG"; exit 1; }

# --- Scenario 2: idempotent re-run -----------------------------------------
echo "  scenario 2: re-run with everything already installed — no copy, no reload, no enable..."
: > "$STUB_LOG"
MOCK_TIMERS_ENABLED=1 run_install "$SHARED_OVERLAY/install.sh" || { echo "FAIL scenario 2: install.sh exited non-zero on rerun"; cat "$STUB_LOG"; exit 1; }

# No sudo cp (units in sync)
[ "$(count_stub 'SUDO cp')" = "0" ] || { echo "FAIL scenario 2: expected 0 sudo cp on rerun, got $(count_stub 'SUDO cp')"; cat "$STUB_LOG"; exit 1; }
# No daemon-reload (nothing changed)
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "0" ] || { echo "FAIL scenario 2: expected 0 daemon-reloads on rerun"; cat "$STUB_LOG"; exit 1; }
# No enable --now (timers already enabled+active per stub)
[ "$(count_stub 'SYSTEMCTL enable --now')" = "0" ] || { echo "FAIL scenario 2: expected 0 enable --now on rerun"; cat "$STUB_LOG"; exit 1; }
# No restarts (CHANGED=0 when nothing differs — the [[ $CHANGED -gt 0 ]] gate holds)
[ "$(count_stub 'SYSTEMCTL restart')" = "0" ] || { echo "FAIL scenario 2: expected 0 restarts on no-op rerun, got $(count_stub 'SYSTEMCTL restart')"; cat "$STUB_LOG"; exit 1; }

# --- Scenario 3: new unit added → only that one installs+enables -----------
echo "  scenario 3: drop a new unit into systemd/ — only that one is copied + enabled..."
# Build a fresh overlay (project tree symlinks + divergent repos.conf
# fixture, same shape as scenarios 1+2's SHARED_OVERLAY), then replace
# the systemd/ symlink with a real dir we can add new units to.
OVERLAY="$TMPDIR/repo-overlay-newunit"
make_install_overlay "$OVERLAY"
rm -f "$OVERLAY/systemd"
mkdir -p "$OVERLAY/systemd"
for unit in "$PROJECT_ROOT"/systemd/*; do
    ln -sfn "$unit" "$OVERLAY/systemd/$(basename "$unit")"
done
# Add a brand-new unit + timer that didn't exist before
cat > "$OVERLAY/systemd/pr-reviewer-fakenew.service" <<'NEWUNIT'
[Unit]
Description=Fake new unit for install-smoke scenario 3

[Service]
Type=oneshot
ExecStart=/bin/true
NEWUNIT
cat > "$OVERLAY/systemd/pr-reviewer-fakenew.timer" <<'NEWTIMER'
[Unit]
Description=Fake new timer for install-smoke scenario 3

[Timer]
OnCalendar=*:*:00
Unit=pr-reviewer-fakenew.service

[Install]
WantedBy=timers.target
NEWTIMER

# Argv-bearing fixture for the parser. Without the command-token split
# in install.sh's ExecStart= parser, `s|.*/||` would greedy-eat through
# `/cncorp/` and basename to "plow" instead of "argv-fakenew.sh", and
# argv-fakenew.sh would silently drop out of the symlinked list. The
# script needs to actually exist in the overlay so install.sh's
# `[[ -f "$REPO_DIR/$script" ]]` check passes — a missing file would
# trigger the fail-loud path instead.
echo '#!/bin/bash' > "$OVERLAY/argv-fakenew.sh"
chmod +x "$OVERLAY/argv-fakenew.sh"
cat > "$OVERLAY/systemd/pr-reviewer-argv-fakenew.service" <<'ARGVUNIT'
[Unit]
Description=Argv-bearing fixture for install-smoke parser regression

[Service]
Type=oneshot
ExecStart=/home/odio/.pr-reviewer/argv-fakenew.sh --some-flag value --repo cncorp/plow
ARGVUNIT

: > "$STUB_LOG"
# Name-aware stub: existing timers are already enabled+active (avoiding
# spurious enable --now calls), but the brand-new timer must still get
# enable+started. Without this, the stub would lie that the new timer
# was already enabled and the test couldn't tell whether
# `enable --now pr-reviewer-fakenew.timer` actually fired.
MOCK_TIMERS_ENABLED=1 \
MOCK_NEWLY_ADDED_TIMERS="pr-reviewer-fakenew.timer" \
    run_install "$OVERLAY/install.sh" || { echo "FAIL scenario 3: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

# Three new units copied (fakenew .service + fakenew .timer +
# argv-fakenew .service) — every existing unit is in sync because
# scenario 1 already copied them and SYSTEMD_DIR is preserved across
# scenarios.
n_cp="$(count_stub 'SUDO cp')"
[ "$n_cp" = "3" ] || { echo "FAIL scenario 3: expected 3 sudo cp (new .service + new .timer + argv .service), got $n_cp"; cat "$STUB_LOG"; exit 1; }
# daemon-reload called exactly once because something changed
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "1" ] || { echo "FAIL scenario 3: expected 1 daemon-reload"; cat "$STUB_LOG"; exit 1; }
# All three new files exist in the sandboxed SYSTEMD_DIR
[ -f "$SYSTEMD_DIR/pr-reviewer-fakenew.service" ] || { echo "FAIL scenario 3: new .service not copied"; exit 1; }
[ -f "$SYSTEMD_DIR/pr-reviewer-fakenew.timer" ] || { echo "FAIL scenario 3: new .timer not copied"; exit 1; }
[ -f "$SYSTEMD_DIR/pr-reviewer-argv-fakenew.service" ] || { echo "FAIL scenario 3: argv-bearing .service not copied"; exit 1; }
# Argv-parser regression test: argv-fakenew.sh must be symlinked into
# INSTALL_DIR despite the ExecStart= line carrying argv args. A regression
# to greedy-basename parsing would silently drop it.
[ -L "$INSTALL_DIR/argv-fakenew.sh" ] || { echo "FAIL scenario 3 (argv-parser regression): argv-fakenew.sh not symlinked into $INSTALL_DIR"; ls -la "$INSTALL_DIR"; exit 1; }
# The KEY new assertion: the brand-new timer must have been enabled+started
# exactly once. Without name-aware stubbing this branch was untested — a
# regression that copied unit files but never enabled the new timer would
# have shipped green.
[ "$(count_stub 'SYSTEMCTL enable --now pr-reviewer-fakenew.timer')" = "1" ] || { echo "FAIL scenario 3 (newly-added-timer-enable regression): expected exactly 1 'enable --now pr-reviewer-fakenew.timer' call"; cat "$STUB_LOG"; exit 1; }
# Existing timers should NOT have been re-enabled (they were already
# enabled+active per MOCK_TIMERS_ENABLED).
[ "$(count_stub 'SYSTEMCTL enable --now pr-reviewer.timer')" = "0" ] || { echo "FAIL scenario 3: existing pr-reviewer.timer was re-enabled despite already being active"; cat "$STUB_LOG"; exit 1; }
# All already-active production timers (PROD_TIMERS) must have been restarted
# because CHANGED > 0 (3 new unit files were copied). The new fakenew.timer
# took the enable --now path (not yet active per MOCK_NEWLY_ADDED_TIMERS), so
# it does NOT contribute a restart — only the existing active timers do.
EXPECTED_RESTARTS="${#PROD_TIMERS[@]}"
[ "$(count_stub 'SYSTEMCTL restart')" = "$EXPECTED_RESTARTS" ] || { echo "FAIL scenario 3: expected $EXPECTED_RESTARTS restarts (all existing active timers), got $(count_stub 'SYSTEMCTL restart')"; cat "$STUB_LOG"; exit 1; }

echo "  PASS (3 scenarios: first-run, idempotent-rerun, new-unit-incremental-enables-new-timer)"
