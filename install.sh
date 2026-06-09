#!/usr/bin/env bash
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
# Idempotent. Re-running after merging a poller change (e.g. the
# pr-reviewer-poll consolidation) installs only the new bits and disables any
# retired units; existing units are left alone unless their content drifted.
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

# pipeline.py runs under python3; fail loud here if unavailable rather
# than at the first review tick. No pip dependencies — stdlib only —
# so a `python3 --version` check is sufficient.
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not on PATH — required by lib/pipeline.py (apt install python3 or pyenv setup)"
fi
PY_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
ok "python3: $PY_VERSION"

# gh CLI: review-one-pr.sh requests the `closingIssuesReferences` field on
# `gh pr view --json`. 2.65 does NOT support it (rejects with "Unknown JSON
# field" — the field lands in a later release); too-old gh returns empty and
# aborts the entire pr-view call. 2.90.0 is verified to speak it (matches the
# container Dockerfile pin).
if ! command -v gh >/dev/null 2>&1; then
    fail "gh not on PATH — required by review-one-pr.sh / review.sh / etc. (apt install gh)"
fi
GH_VERSION=$(gh --version 2>&1 | head -1 | awk '{print $3}')
GH_MAJ="${GH_VERSION%%.*}"
GH_REST="${GH_VERSION#*.}"
GH_MIN="${GH_REST%%.*}"
if [ "${GH_MAJ:-0}" -lt 2 ] || { [ "${GH_MAJ:-0}" -eq 2 ] && [ "${GH_MIN:-0}" -lt 90 ]; }; then
    fail "gh CLI is $GH_VERSION; need >= 2.90 for the closingIssuesReferences field used in lib/review-one-pr.sh (2.65 rejects it as an unknown JSON field). Update via: 'sudo apt install gh' (or download a newer .deb from https://github.com/cli/cli/releases) and re-run install.sh."
fi
ok "gh: $GH_VERSION"

# vulture: invoked by .knightwatch/dead-code.sh in tracked repos.
command -v uv >/dev/null || fail "uv not on PATH — install via 'curl -LsSf https://astral.sh/uv/install.sh | sh'"
uv tool install 'vulture==2.16' >/dev/null

# --- 0. Bootstrap repos.conf from .example on a fresh clone -----------------
# repos.conf is per-operator and gitignored; the tracked template lives at
# repos.conf.example. On first run we copy the template into place and
# exit — the placeholder REPOS would otherwise enable systemd timers that
# spin on `gh pr list --repo your-org/example-repo`, wasting API quota and
# polluting logs until the operator edits the file. Fail-fast at the
# install boundary instead: tell the operator what to do and stop.
#
# Two unconfigured states fail-fast here, both with the same message:
#   1. repos.conf doesn't exist — bootstrap from .example, then exit.
#   2. repos.conf exists but is byte-for-byte identical to .example — the
#      operator hasn't edited yet (e.g., re-ran install.sh on a fresh
#      clone, or a tool raw-cp'd the template). Reject the same way; the
#      operator hitting "already configured" silently is the bug.
info "NOTE: this installs the auxiliary host timers (bake-off, org-sync, learn, poll [merged /srosro-approve + re-request], kid-refresh). The review loop itself runs in the containerized multi-account fleet — see README.md § Containerized (multi-account) deployment and docker-compose.yml."

if [[ ! -f "$REPO_DIR/repos.conf" ]]; then
    [[ -f "$REPO_DIR/repos.conf.example" ]] || fail "neither repos.conf nor repos.conf.example present at $REPO_DIR"
    cp "$REPO_DIR/repos.conf.example" "$REPO_DIR/repos.conf"
    info "bootstrapped repos.conf from repos.conf.example"
    info "edit $REPO_DIR/repos.conf to track real repos, then re-run ./install.sh — exiting now without enabling timers on the placeholder manifest"
    exit 0
fi
if [[ -f "$REPO_DIR/repos.conf.example" ]] && cmp -s "$REPO_DIR/repos.conf" "$REPO_DIR/repos.conf.example"; then
    info "$REPO_DIR/repos.conf is byte-for-byte identical to repos.conf.example — placeholder manifest, not edited yet"
    info "edit $REPO_DIR/repos.conf to track real repos, then re-run ./install.sh — exiting now without enabling timers on the placeholder manifest"
    exit 0
fi

# --- 1. Symlinks into $INSTALL_DIR ------------------------------------------
# Discover the script list from the systemd unit files' ExecStart=
# directives — the units are the source of truth for what runs in
# production. A new poller landing as <name>.service (with its
# ExecStart=$INSTALL_DIR/<script>.sh) automatically gets symlinked here
# without a parallel manifest to keep in sync. Parser lives in
# lib/systemd-units.sh and is shared with install-smoke +
# prompt-contracts-smoke so the contract has one definition, not three.
# shellcheck source=lib/systemd-units.sh
. "$REPO_DIR/lib/systemd-units.sh"

shopt -s nullglob
service_units=( systemd/*.service )
shopt -u nullglob
[[ ${#service_units[@]} -ge 1 ]] || fail "no systemd .service files in $REPO_DIR/systemd/"

# Drift check first (fail-loud surfaces missing .sh before we build
# the symlink list); then the list itself.
assert_execstart_shell_scripts_present "$REPO_DIR" "${service_units[@]}" || exit 1
mapfile -t SCRIPTS < <(list_execstart_shell_scripts "$REPO_DIR" "${service_units[@]}")
[[ ${#SCRIPTS[@]} -ge 1 ]] || fail "no scripts discovered from ExecStart= directives — check systemd/*.service shape"

DIRS=(lib docs prompts)
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

# @KID_RW_PATHS@ renders from the KID_PATHS source of truth: full repo
# roots (e.g. /home/odio/Hacking/foo), used by pr-reviewer-kid-refresh.service
# to git-pull + re-index the checkouts. Paths are prefixed with `-` so a
# missing checkout (operator hasn't cloned a tracked repo yet) doesn't fail
# systemd unit start — plow-kid-refresh.sh's checkout check skips them.
#
# Source the shared loader (lib/tracked-repos.sh) for both KID_PATHS
# population AND the KWR_CLONE_ROOT constant. The loader sources
# config.env → repos.conf → repos.conf.auto in order (manual entries
# win, auto twins prune), then convention-defaults any unset
# KID_PATHS entry from $KWR_CLONE_ROOT. Single seam — install.sh
# templates units from the same KID_PATHS values the runtime
# consumers see. ProtectHome=read-only systemd units require their
# ReadWritePaths to exist at namespace setup (before ExecStart runs),
# so the mkdir below has to run at install time, not first-clone time.
STATE_DIR="$INSTALL_DIR"
CONFIG_ENV_FILE="${CONFIG_ENV_FILE:-$INSTALL_DIR/config.env}"

# kwr-config cache — the PRODUCER, and it MUST run BEFORE tracked-repos.sh below:
# that loader's overlay fail-louds on a cold cache when KWR_CONFIG_REPO is set, so
# the cache has to exist first (the cold-cache first-activation ordering). Source
# config.env (for KWR_CONFIG_REPO) + conventions.sh (for sync_kwr_config), create +
# populate the cache, THEN source tracked-repos.sh — its overlay now sees a valid
# config.json. HOME-relative (sibling of $KWR_CLONE_ROOT, NOT clone-path-relative)
# so the rendered systemd ReadWritePaths is stable across prod-clone moves. Created
# unconditionally so the org-sync unit's ReadWritePaths target exists at namespace
# setup; populated now (before the containers come up) when KWR_CONFIG_REPO is set
# — a missing cache would make the containers fail loud.
if [ -f "$CONFIG_ENV_FILE" ]; then . "$CONFIG_ENV_FILE"; fi
# shellcheck disable=SC1091
. "$REPO_DIR/lib/conventions.sh"
KWR_CONFIG_DIR="$HOME/services/kwr-config"
export KWR_CONFIG_DIR
mkdir -p "$KWR_CONFIG_DIR"
# Serialize cache mutation + the tracked-repos overlay read against the hourly
# org-sync writer, which already guards the SAME kwr-config checkout + the
# repos.conf.auto rewrite behind this exact lock (org-sync.sh:31). Without it an
# org-sync tick firing mid-install would race install's clone/rm/pull and the
# auto-file rewrite. Blocking with a bound (not org-sync's -n skip): a deploy
# should wait a tick out, not skip the activation — but fail loud if it can't
# acquire (a stuck org-sync run), rather than block forever. Released right after
# the overlay source; the remaining systemd render is install-local.
command -v flock >/dev/null 2>&1 || fail "flock not on PATH (util-linux) — needed to serialize kwr-config sync against org-sync"
# Same var org-sync.sh derives its lock from (STATE_DIR, =INSTALL_DIR here) so the
# two stay the SAME file by construction, not by coincident literals. Timeout is
# overridable so the contended fail-loud path is testable (install-smoke pre-holds
# the lock with ORG_SYNC_LOCK_WAIT=1).
exec 9>"$STATE_DIR/org-sync.lock"
flock -w "${ORG_SYNC_LOCK_WAIT:-120}" 9 || fail "could not acquire $STATE_DIR/org-sync.lock within ${ORG_SYNC_LOCK_WAIT:-120}s — an org-sync run may be stuck; investigate before re-running install"
if [ -n "${KWR_CONFIG_REPO:-}" ]; then
  # Deploy-time origin swap (install.sh OWNS this; the hourly org-sync path keeps
  # last-good on a mismatch). If the cache is from a DIFFERENT repo, drop it so
  # sync_kwr_config's fresh-clone path adopts the new origin — safe here because the
  # deploy restarts the reviewer fleet right after, so the cache dir inode swap
  # doesn't strand running containers.
  if [ -d "$KWR_CONFIG_DIR/.git" ]; then
    cache_origin="$(git -C "$KWR_CONFIG_DIR" remote get-url origin 2>/dev/null || echo "")"
    # if/then over `[ … ] && rm` — matches org-sync.sh's documented set -e idiom.
    if [ "$cache_origin" != "$KWR_CONFIG_REPO" ]; then rm -rf "$KWR_CONFIG_DIR"; fi
  fi
  if sync_kwr_config; then
    ok "kwr-config cache synced ($KWR_CONFIG_DIR)"
  elif kwr_config_valid; then
    info "kwr-config sync failed — proceeding on last-good cache"
  else
    fail "kwr-config sync failed and no cache present — the reviewer containers fail loud on a missing cache; fix KWR_CONFIG_REPO/creds and re-run"
  fi
fi

# shellcheck disable=SC1091
. "$REPO_DIR/lib/tracked-repos.sh"
exec 9>&-   # release the org-sync lock — the remaining systemd render is install-local
mkdir -p "$KWR_CLONE_ROOT"

# Dedupe + sort for stable rendering across runs so cmp-based idempotency
# doesn't trigger spurious copies when bash hashing reorders the assoc
# array between runs.
KID_RW_PATHS=$(printf '%s\n' "${KID_PATHS[@]}" | sort -u | sed 's|^|-|' | tr '\n' ' ')
KID_RW_PATHS="${KID_RW_PATHS% }"

CHANGED=0
for unit in "${units[@]}"; do
  name="$(basename "$unit")"
  dst="$SYSTEMD_DIR/$name"
  rendered="$unit"
  if grep -qE '@(KID_RW_PATHS|KWR_CLONE_ROOT|KWR_CONFIG_DIR)@' "$unit"; then
    rendered="$(mktemp)"
    sed -e "s|@KID_RW_PATHS@|$KID_RW_PATHS|g" \
        -e "s|@KWR_CLONE_ROOT@|$KWR_CLONE_ROOT|g" \
        -e "s|@KWR_CONFIG_DIR@|$KWR_CONFIG_DIR|g" \
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

# --- 2b. Remove retired legacy units ----------------------------------------
# Units whose files are gone from systemd/ but a prior install left copies in
# $SYSTEMD_DIR. Disable + remove so the orphans don't linger. Idempotent.
#   - pr-reviewer.{timer,service}: single-account host reviewer, retired for the
#     containerized fleet (docker-compose.yml).
#   - pr-reviewer-approve.* / pr-reviewer-re-request.*: the separate /srosro-approve
#     (60s) + re-request (120s) pollers, merged into pr-reviewer-poll.* (every 2min,
#     one shared enumerate) to cut the shared-budget fetch rate.
for legacy in pr-reviewer.timer pr-reviewer.service \
              pr-reviewer-approve.timer pr-reviewer-approve.service \
              pr-reviewer-re-request.timer pr-reviewer-re-request.service; do
  if [[ -f "$SYSTEMD_DIR/$legacy" ]]; then
    info "removing retired legacy unit $legacy (sudo)"
    sudo systemctl disable --now "$legacy" 2>/dev/null || true
    sudo rm -f "$SYSTEMD_DIR/$legacy"
    CHANGED=$((CHANGED + 1))
  fi
done

# --- 3. daemon-reload if any unit changed -----------------------------------
if [[ "$CHANGED" -gt 0 ]]; then
  info "daemon-reload (sudo)"
  sudo systemctl daemon-reload
fi

# --- 4. enable + start each timer (restart already-active timers when any
#        unit file changed — daemon-reload alone doesn't apply schedule
#        changes to running timers) -------------------------------------
shopt -s nullglob
timers=( systemd/*.timer )
shopt -u nullglob

ENABLED=0
RESTARTED=0
for timer in "${timers[@]}"; do
  name="$(basename "$timer")"
  if ! systemctl is-enabled "$name" --quiet 2>/dev/null \
      || ! systemctl is-active "$name" --quiet 2>/dev/null; then
    info "enable --now $name (sudo)"
    sudo systemctl enable --now "$name"
    ENABLED=$((ENABLED + 1))
  elif [[ "$CHANGED" -gt 0 ]]; then
    # Already enabled+active, but a unit file changed this install — restart
    # so the new schedule takes effect. Cheap and idempotent (stop+start of
    # the timer unit, no service trigger).
    info "restart $name (sudo) — unit files changed"
    sudo systemctl restart "$name"
    RESTARTED=$((RESTARTED + 1))
  fi
done
ok "timers: ${#timers[@]} present, $ENABLED newly enabled+started, $RESTARTED restarted"

echo
ok "install complete"
