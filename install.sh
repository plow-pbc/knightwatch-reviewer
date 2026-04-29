#!/bin/bash
# Idempotent install / re-install for the knightwatch-reviewer bot host.
# Run from the repo root: ./install.sh
#
# What it does:
#   1. Symlinks repo scripts + dirs into $INSTALL_DIR (default
#      ~/.pr-reviewer/), the path the systemd ExecStart= lines point at.
#   2. Copies every systemd/*.{service,timer} into $SYSTEMD_DIR (default
#      /etc/systemd/system/) — only when content differs from the
#      installed copy. Uses sudo because the destination is root-owned
#      under the existing install pattern.
#   3. daemon-reloads systemd if anything changed.
#   4. Enables + starts every timer that isn't already enabled+active.
#
# Idempotent. Re-running after merging a new poller (e.g. the
# pr-reviewer-approve work that motivated this script) installs only the
# new bits; existing units are left alone unless their content drifted.
#
# Host-specific by design: the systemd unit ExecStart= paths bake in
# /home/odio/.pr-reviewer/ and the User= line bakes in `odio`. Running
# this on a different box / user requires editing the unit files first.
#
# $INSTALL_DIR and $SYSTEMD_DIR can be overridden for sandboxed smoke
# tests (see lib/tests/install-smoke.sh).

set -euo pipefail

# Match the PATH prepend in review.sh / learn-from-replies.sh /
# approve-from-replies.sh so sandboxed smoke tests can intercept `sudo`
# and `systemctl` via $HOME/.local/bin/ stubs.
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_DIR="$PWD"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.pr-reviewer}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

fail() { echo "✗ $1" >&2; exit 1; }
info() { echo "→ $1"; }
ok()   { echo "✓ $1"; }

# --- 1. Symlinks into $INSTALL_DIR ------------------------------------------
# Each script the systemd ExecStart= lines point at, plus the directories
# the scripts themselves source via $INSTALL_DIR/lib etc.
SCRIPTS=(
  review.sh
  learn-from-replies.sh
  approve-from-replies.sh
  re-request-poller.sh
  plow-kid-refresh.sh
)
DIRS=(lib contexts docs prompts)

mkdir -p "$INSTALL_DIR"
for script in "${SCRIPTS[@]}"; do
  src="$REPO_DIR/$script"
  [[ -f "$src" ]] || fail "missing repo script: $src"
  ln -snf "$src" "$INSTALL_DIR/$script"
done
for d in "${DIRS[@]}"; do
  src="$REPO_DIR/$d"
  [[ -d "$src" ]] || fail "missing repo dir: $src"
  ln -snf "$src" "$INSTALL_DIR/$d"
done
ok "symlinked ${#SCRIPTS[@]} scripts + ${#DIRS[@]} dirs into $INSTALL_DIR"

# --- 2. systemd units -------------------------------------------------------
shopt -s nullglob
units=( systemd/*.service systemd/*.timer )
shopt -u nullglob
[[ ${#units[@]} -ge 1 ]] || fail "no systemd unit files in $REPO_DIR/systemd/"

CHANGED=0
for unit in "${units[@]}"; do
  name="$(basename "$unit")"
  dst="$SYSTEMD_DIR/$name"
  if [[ -f "$dst" ]] && cmp -s "$unit" "$dst"; then
    continue   # already in sync, no sudo needed
  fi
  info "installing $name (sudo cp)"
  sudo cp "$unit" "$dst" || fail "cp failed for $name"
  CHANGED=$((CHANGED + 1))
done
ok "systemd units: ${#units[@]} present, $CHANGED updated"

# --- 3. daemon-reload if any unit changed -----------------------------------
if [[ "$CHANGED" -gt 0 ]]; then
  info "daemon-reload (sudo)"
  sudo systemctl daemon-reload
fi

# --- 4. enable + start each timer that isn't already enabled+active ---------
shopt -s nullglob
timers=( systemd/*.timer )
shopt -u nullglob

ENABLED=0
for timer in "${timers[@]}"; do
  name="$(basename "$timer")"
  if systemctl is-enabled "$name" --quiet 2>/dev/null \
      && systemctl is-active "$name" --quiet 2>/dev/null; then
    continue   # already enabled+running
  fi
  info "enable --now $name (sudo)"
  sudo systemctl enable --now "$name"
  ENABLED=$((ENABLED + 1))
done
ok "timers: ${#timers[@]} present, $ENABLED newly enabled+started"

echo
ok "install complete"
