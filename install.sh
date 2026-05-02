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

# Don't prepend $HOME/.local/bin to PATH. The script invokes `sudo` and
# `systemctl` (privilege-escalation surface), and a writable-home shim
# could intercept either. The smoke test sets PATH itself before
# invoking install.sh — that's the right seam for test-only command
# interception, not the production script's own PATH.

cd "$(dirname "${BASH_SOURCE[0]}")"
REPO_DIR="$PWD"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.pr-reviewer}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

fail() { echo "✗ $1" >&2; exit 1; }
info() { echo "→ $1"; }
ok()   { echo "✓ $1"; }

# Refuse to run as root. The systemd unit ExecStart= paths bake in
# /home/odio/.pr-reviewer/ — under sudo, $HOME becomes /root and
# INSTALL_DIR resolves to /root/.pr-reviewer/, so the install would
# write to a path systemd never reads. The internal `sudo cp` /
# `sudo systemctl` calls below escalate privilege only where needed.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    fail "run install.sh as the bot user, NOT root. Resolved INSTALL_DIR=$INSTALL_DIR — systemd units are pinned to /home/odio/.pr-reviewer/, so a sudo invocation would write to the wrong tree. The script's internal sudo cp / sudo systemctl handle the privileged bits."
fi

# --- 1. Symlinks into $INSTALL_DIR ------------------------------------------
# Discover the script list from the systemd unit files' ExecStart=
# directives — the units are the source of truth for what runs in
# production. A new poller landing as <name>.service (with its
# ExecStart=$INSTALL_DIR/<script>.sh) automatically gets symlinked here
# without a parallel manifest to keep in sync.
shopt -s nullglob
service_units=( systemd/*.service )
shopt -u nullglob
[[ ${#service_units[@]} -ge 1 ]] || fail "no systemd .service files in $REPO_DIR/systemd/"

SCRIPTS=()
while IFS= read -r execstart; do
    # An ExecStart= line is `ExecStart=/path/to/cmd [arg1] [arg2] ...`.
    # Strip the directive prefix, then split off everything after the
    # first whitespace so we ONLY take the command path. Without this
    # split, a future `ExecStart=/home/odio/.pr-reviewer/review.sh
    # --repo cncorp/plow` would basename to "plow" (greedy `.*/` eats
    # through the last `/` in `cncorp/plow`) and silently drop
    # review.sh from the managed list.
    cmd_path="${execstart#ExecStart=}"
    cmd_path="${cmd_path%% *}"   # everything before the first space
    script="${cmd_path##*/}"     # basename
    [[ -n "$script" ]] || continue
    if [[ -f "$REPO_DIR/$script" ]]; then
        SCRIPTS+=("$script")
    elif [[ "$script" == *.sh ]]; then
        # ExecStart points at a *.sh basename but the repo doesn't have it —
        # drift between the unit file and the repo. Fail loud rather than
        # silently dropping the symlink and shipping a broken install.
        fail "unit ExecStart references '$script' but $REPO_DIR/$script doesn't exist"
    fi
    # else: ExecStart points at a non-script path (e.g. /bin/true in test
    # fixtures, or a hypothetical absolute /usr/bin/something). Nothing
    # to symlink for those; skip without warning.
done < <(grep -h "^ExecStart=" "${service_units[@]}" | sort -u)
[[ ${#SCRIPTS[@]} -ge 1 ]] || fail "no scripts discovered from ExecStart= directives — check systemd/*.service shape"

DIRS=(lib docs prompts)
# Tracked-repo manifest. Sourced by every script that needs the REPOS
# array or KID_PATHS map — single source of truth, host-editable.
CONFIG_FILES=(repos.conf)

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
for f in "${CONFIG_FILES[@]}"; do
  src="$REPO_DIR/$f"
  [[ -f "$src" ]] || fail "missing repo config file: $src"
  ln -snf "$src" "$INSTALL_DIR/$f"
done
ok "symlinked ${#SCRIPTS[@]} scripts + ${#DIRS[@]} dirs + ${#CONFIG_FILES[@]} config file(s) into $INSTALL_DIR"

# --- 2. systemd units -------------------------------------------------------
shopt -s nullglob
units=( systemd/*.service systemd/*.timer )
shopt -u nullglob
[[ ${#units[@]} -ge 1 ]] || fail "no systemd unit files in $REPO_DIR/systemd/"

# Two render shapes from the same KID_PATHS source of truth, one per
# unit's actual access need:
#
#   @KID_RW_PATHS@        — full repo roots (e.g. /home/odio/Hacking/foo).
#                           Used by pr-reviewer-kid-refresh.service, which
#                           git-pulls and re-indexes the checkouts.
#
#   @KID_INDEX_RW_PATHS@  — `.keepitdry` subdirs only, prefixed with `-`
#                           so missing dirs don't fail systemd unit start
#                           (review code already skips when index is
#                           absent — see lib/review-one-pr.sh's kid block).
#                           Used by pr-reviewer.service, which only needs
#                           chromadb's SQLite WAL/journal writes inside
#                           the index dir.
#
# The narrower review render keeps Codex specialists (inner sandbox
# disabled) from getting writes to entire repo source trees.
[[ -f "$REPO_DIR/repos.conf" ]] || fail "repos.conf missing at $REPO_DIR/repos.conf — needed to render kid-refresh ReadWritePaths"
# shellcheck disable=SC1091
. "$REPO_DIR/repos.conf"
# Dedupe + sort for stable rendering across runs so cmp-based idempotency
# doesn't trigger spurious copies when bash hashing reorders the assoc
# array between runs.
KID_RW_PATHS=$(printf '%s\n' "${KID_PATHS[@]}" | sort -u | tr '\n' ' ')
KID_RW_PATHS="${KID_RW_PATHS% }"
KID_INDEX_RW_PATHS=$(printf '%s\n' "${KID_PATHS[@]}" | sort -u | sed 's|$|/.keepitdry|; s|^|-|' | tr '\n' ' ')
KID_INDEX_RW_PATHS="${KID_INDEX_RW_PATHS% }"

CHANGED=0
for unit in "${units[@]}"; do
  name="$(basename "$unit")"
  dst="$SYSTEMD_DIR/$name"
  rendered="$unit"
  if grep -qE '@KID_(RW|INDEX_RW)_PATHS@' "$unit"; then
    rendered="$(mktemp)"
    sed -e "s|@KID_INDEX_RW_PATHS@|$KID_INDEX_RW_PATHS|g" \
        -e "s|@KID_RW_PATHS@|$KID_RW_PATHS|g" \
        "$unit" > "$rendered"
  fi
  if [[ -f "$dst" ]] && cmp -s "$rendered" "$dst"; then
    [[ "$rendered" != "$unit" ]] && rm -f "$rendered"
    continue   # already in sync, no sudo needed
  fi
  info "installing $name (sudo cp)"
  sudo cp "$rendered" "$dst" || fail "cp failed for $name"
  [[ "$rendered" != "$unit" ]] && rm -f "$rendered"
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
