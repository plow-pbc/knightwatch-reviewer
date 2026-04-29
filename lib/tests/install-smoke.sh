#!/bin/bash
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

# Discover the same script list install.sh now derives from the unit
# files' ExecStart= directives, so the assertion in scenario 1 stays
# in sync without a parallel hand-maintained list. Mirror install.sh's
# *.sh-existing-in-repo filter so both code paths agree on what counts
# as a "script that should be symlinked."
PROD_SCRIPTS=()
while IFS= read -r script; do
    [[ -n "$script" ]] || continue
    [[ "$script" == *.sh ]] || continue
    [[ -f "$PROJECT_ROOT/$script" ]] && PROD_SCRIPTS+=("$script")
done < <(grep -h "^ExecStart=" "$PROJECT_ROOT"/systemd/*.service | sed 's|^ExecStart=||;s|.*/||' | sort -u)
[[ ${#PROD_SCRIPTS[@]} -ge 1 ]] || { echo "FAIL setup: no scripts discovered from production unit files"; exit 1; }

# --- Scenario 1: first-run install -----------------------------------------
echo "  scenario 1: first-run install — every unit copied, every timer enabled..."
: > "$STUB_LOG"
run_install "$PROJECT_ROOT/install.sh" || { echo "FAIL scenario 1: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

# Symlinks present (script names sourced from the unit files, same as install.sh)
for s in "${PROD_SCRIPTS[@]}"; do
    [ -L "$INSTALL_DIR/$s" ] || { echo "FAIL scenario 1: $INSTALL_DIR/$s not a symlink"; exit 1; }
done
for d in lib contexts docs prompts; do
    [ -L "$INSTALL_DIR/$d" ] || { echo "FAIL scenario 1: $INSTALL_DIR/$d not a symlink"; exit 1; }
done

# Every unit file copied
for unit in "${PROD_UNITS[@]}"; do
    name="$(basename "$unit")"
    [ -f "$SYSTEMD_DIR/$name" ] || { echo "FAIL scenario 1: $SYSTEMD_DIR/$name missing"; exit 1; }
    cmp -s "$unit" "$SYSTEMD_DIR/$name" || { echo "FAIL scenario 1: $name content differs from source"; exit 1; }
done

# daemon-reload was called once (units actually changed)
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "1" ] || { echo "FAIL scenario 1: expected exactly 1 daemon-reload"; cat "$STUB_LOG"; exit 1; }

# enable --now called for every timer
n_enable="$(count_stub 'SYSTEMCTL enable --now')"
[ "$n_enable" = "${#PROD_TIMERS[@]}" ] || { echo "FAIL scenario 1: expected ${#PROD_TIMERS[@]} enable --now calls, got $n_enable"; cat "$STUB_LOG"; exit 1; }

# --- Scenario 2: idempotent re-run -----------------------------------------
echo "  scenario 2: re-run with everything already installed — no copy, no reload, no enable..."
: > "$STUB_LOG"
MOCK_TIMERS_ENABLED=1 run_install "$PROJECT_ROOT/install.sh" || { echo "FAIL scenario 2: install.sh exited non-zero on rerun"; cat "$STUB_LOG"; exit 1; }

# No sudo cp (units in sync)
[ "$(count_stub 'SUDO cp')" = "0" ] || { echo "FAIL scenario 2: expected 0 sudo cp on rerun, got $(count_stub 'SUDO cp')"; cat "$STUB_LOG"; exit 1; }
# No daemon-reload (nothing changed)
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "0" ] || { echo "FAIL scenario 2: expected 0 daemon-reloads on rerun"; cat "$STUB_LOG"; exit 1; }
# No enable --now (timers already enabled+active per stub)
[ "$(count_stub 'SYSTEMCTL enable --now')" = "0" ] || { echo "FAIL scenario 2: expected 0 enable --now on rerun"; cat "$STUB_LOG"; exit 1; }

# --- Scenario 3: new unit added → only that one installs+enables -----------
echo "  scenario 3: drop a new unit into systemd/ — only that one is copied + enabled..."
NEW_UNIT="$TMPDIR/repo-overlay-systemd"
mkdir -p "$NEW_UNIT"
# Copy current units into an overlay so the test doesn't mutate the real
# repo, then add a fake one and point install.sh at the overlay via a
# wrapper that swaps the systemd/ source dir. The cleanest way to do
# this without changing install.sh's contract is to symlink the entire
# repo into $TMPDIR and add the unit there.
OVERLAY="$TMPDIR/repo-overlay"
mkdir -p "$OVERLAY"
for entry in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do
    [ -e "$entry" ] || continue
    name="$(basename "$entry")"
    case "$name" in
        ".git"|".git/*") continue ;;  # skip git internals
    esac
    ln -sfn "$entry" "$OVERLAY/$name"
done
# Replace the systemd/ symlink with a real dir we can add a unit to
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

: > "$STUB_LOG"
# Name-aware stub: existing timers are already enabled+active (avoiding
# spurious enable --now calls), but the brand-new timer must still get
# enable+started. Without this, the stub would lie that the new timer
# was already enabled and the test couldn't tell whether
# `enable --now pr-reviewer-fakenew.timer` actually fired.
MOCK_TIMERS_ENABLED=1 \
MOCK_NEWLY_ADDED_TIMERS="pr-reviewer-fakenew.timer" \
    run_install "$OVERLAY/install.sh" || { echo "FAIL scenario 3: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

# Exactly one new unit copied (the fake one) — the existing ones are
# in sync because scenario 1 already copied them and SYSTEMD_DIR is
# preserved across scenarios.
n_cp="$(count_stub 'SUDO cp')"
# We added a service + a timer = 2 new units.
[ "$n_cp" = "2" ] || { echo "FAIL scenario 3: expected 2 sudo cp (new service + new timer), got $n_cp"; cat "$STUB_LOG"; exit 1; }
# daemon-reload called exactly once because something changed
[ "$(count_stub 'SYSTEMCTL daemon-reload')" = "1" ] || { echo "FAIL scenario 3: expected 1 daemon-reload"; cat "$STUB_LOG"; exit 1; }
# Both new files exist in the sandboxed SYSTEMD_DIR
[ -f "$SYSTEMD_DIR/pr-reviewer-fakenew.service" ] || { echo "FAIL scenario 3: new .service not copied"; exit 1; }
[ -f "$SYSTEMD_DIR/pr-reviewer-fakenew.timer" ] || { echo "FAIL scenario 3: new .timer not copied"; exit 1; }
# The KEY new assertion: the brand-new timer must have been enabled+started
# exactly once. Without name-aware stubbing this branch was untested — a
# regression that copied unit files but never enabled the new timer would
# have shipped green.
[ "$(count_stub 'SYSTEMCTL enable --now pr-reviewer-fakenew.timer')" = "1" ] || { echo "FAIL scenario 3 (newly-added-timer-enable regression): expected exactly 1 'enable --now pr-reviewer-fakenew.timer' call"; cat "$STUB_LOG"; exit 1; }
# Existing timers should NOT have been re-enabled (they were already
# enabled+active per MOCK_TIMERS_ENABLED).
[ "$(count_stub 'SYSTEMCTL enable --now pr-reviewer.timer')" = "0" ] || { echo "FAIL scenario 3: existing pr-reviewer.timer was re-enabled despite already being active"; cat "$STUB_LOG"; exit 1; }

echo "  PASS (3 scenarios: first-run, idempotent-rerun, new-unit-incremental-enables-new-timer)"
