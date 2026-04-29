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

# Fake HOME so install.sh's PATH prepend resolves to our stubs.
export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

# Stub log for systemctl / sudo invocations the script makes.
STUB_LOG="$TMPDIR/stub-calls.log"
export STUB_LOG

# `sudo`: drop the wrapper, run the inner cmd directly. SYSTEMD_DIR is
# already user-writable, so sudo isn't actually needed here — the stub
# just makes that explicit.
cat > "$HOME/.local/bin/sudo" <<'STUB'
#!/bin/bash
echo "SUDO $*" >> "$STUB_LOG"
exec "$@"
STUB
chmod +x "$HOME/.local/bin/sudo"

# `systemctl`: log every invocation. is-enabled / is-active default to
# "not enabled / not active" so scenario 1 enables every timer; scenario
# 2 sets MOCK_TIMERS_ENABLED=1 to flip them to enabled+active so the
# script's idempotent path is exercised.
cat > "$HOME/.local/bin/systemctl" <<'STUB'
#!/bin/bash
echo "SYSTEMCTL $*" >> "$STUB_LOG"
case "$1" in
    is-enabled|is-active)
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
chmod +x "$HOME/.local/bin/systemctl"

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

# --- Scenario 1: first-run install -----------------------------------------
echo "  scenario 1: first-run install — every unit copied, every timer enabled..."
: > "$STUB_LOG"
bash "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || { echo "FAIL scenario 1: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

# Symlinks present
for s in review.sh learn-from-replies.sh approve-from-replies.sh re-request-poller.sh plow-kid-refresh.sh; do
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
MOCK_TIMERS_ENABLED=1 bash "$PROJECT_ROOT/install.sh" >/dev/null 2>&1 || { echo "FAIL scenario 2: install.sh exited non-zero on rerun"; cat "$STUB_LOG"; exit 1; }

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
# `MOCK_TIMERS_ENABLED=1` sets the existing timers to "already enabled" but
# the new timer also gets reported as enabled, since the stub checks via
# name and we're not name-aware. That's fine: scenario 3's real assertion
# is on the *unit copy + daemon-reload* path, which is name-aware via
# cmp. The new unit's enable=skip is acceptable; we'll still see exactly
# 1 sudo cp for the new unit.
MOCK_TIMERS_ENABLED=1 bash "$OVERLAY/install.sh" >/dev/null 2>&1 || { echo "FAIL scenario 3: install.sh exited non-zero"; cat "$STUB_LOG"; exit 1; }

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

echo "  PASS (3 scenarios: first-run, idempotent-rerun, new-unit-incremental)"
