#!/usr/bin/env bash
# Render docker-compose.yml from the operator's fleet.conf.
#
# The fleet's topology is a pure function of (worker id, codex account dir):
# the netns peer, the scenario-shared bridge, the per-unit volumes, and the
# shared read-only mounts are all mechanical. Generating them means those
# invariants hold by construction — which is why the per-unit parity fences
# that used to live in container-state-split-smoke.sh were deleted rather than
# extended when the sixth unit was added.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="${SECRETS_DIR:-$REPO_ROOT/docker/secrets}"
FLEET_CONF="${FLEET_CONF:-$SECRETS_DIR/fleet.conf}"
CONFIG_ENV="${CONFIG_ENV:-$SECRETS_DIR/config.env}"
OUT="${OUT:-$REPO_ROOT/docker-compose.yml}"

die() { printf 'render-compose: FATAL: %s\n' "$*" >&2; exit 1; }

[ -f "$FLEET_CONF" ] \
    || die "no fleet.conf at $FLEET_CONF — copy docker/secrets.example/fleet.conf and edit it"

# KID_ROOT (clone root, mounted at /kwr — carries kid_dry_check.py) and the
# optional KID_EXTRA_MOUNTS (space-separated HOST paths for indices that live
# OUTSIDE the clone root, e.g. plow's) are the prior-art wiring. Each extra index
# mounts at the SAME path in the container, deliberately: KID_PATHS is consumed
# in BOTH namespaces (host-side plow-kid-refresh.sh git-pulls each value as a
# checkout, container-side review-one-pr.sh queries it), so a host≠container path
# would force the two same-named repos.conf manifests to diverge on that key.
# Read in a SUBSHELL: config.env also carries GH_TOKEN, and nothing
# from it is echoed or exported into the render.
# The trailing '.' is load-bearing: command substitution strips trailing
# newlines, so without it an empty KID_EXTRA_MOUNTS collapses the two fields
# into one and the second read yields KID_ROOT's value.
kid_cfg="$(
    set +u
    [ -f "$CONFIG_ENV" ] && . "$CONFIG_ENV" >/dev/null 2>&1
    printf '%s\n%s.' "${KID_ROOT:-}" "${KID_EXTRA_MOUNTS:-}"
)"
KID_ROOT="${kid_cfg%%$'\n'*}"
KID_EXTRA_MOUNTS="${kid_cfg#*$'\n'}"; KID_EXTRA_MOUNTS="${KID_EXTRA_MOUNTS%.}"

# A missing bind source is auto-created EMPTY by docker, so every reviewer would
# start clean and silently skip prior art instead of failing — hence -d, here.
[ -z "$KID_ROOT" ] || [ -d "$KID_ROOT" ] \
    || die "KID_ROOT=$KID_ROOT is not a directory — docker would auto-create it empty and every reviewer would silently skip prior art"
[ -z "$KID_EXTRA_MOUNTS" ] || [ -n "$KID_ROOT" ] \
    || die "KID_EXTRA_MOUNTS is set but KID_ROOT is empty — extra indices are unreachable without the clone root that carries kid_dry_check.py"
for extra in $KID_EXTRA_MOUNTS; do
    [ -d "$extra" ] \
        || die "KID_EXTRA_MOUNTS: $extra is not a directory — docker would auto-create it empty and every reviewer would silently skip prior art"
done

# --- parse + validate -------------------------------------------------------
ids=(); accounts=()
lineno=0
while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    id=""; acct=""; extra=""
    read -r id acct extra <<<"$line" || true
    [ -n "$id" ] || continue

    [ -n "$acct" ] && [ -z "$extra" ] \
        || die "$FLEET_CONF:$lineno: expected '<worker-id> <codex-account-dir>', got: ${line# }"
    case "$id" in
        ''|*[!0-9]*) die "$FLEET_CONF:$lineno: worker id must be a positive integer, got: $id" ;;
    esac
    for j in ${ids[@]+"${!ids[@]}"}; do
        [ "${ids[$j]}" = "$id" ] \
            && die "$FLEET_CONF:$lineno: duplicate worker id $id — two units would share /shared/pool/$id/ and corrupt each other's quota-pause and offline state"
        [ "${accounts[$j]}" = "$acct" ] \
            && die "$FLEET_CONF:$lineno: duplicate account dir $acct — two units would refresh one auth.json concurrently, and their quota-pause state would split across /shared/pool/, so one pausing wouldn't stop the other hammering the exhausted account"
    done
    [ -d "$SECRETS_DIR/$acct" ] \
        || die "$FLEET_CONF:$lineno: account dir not found: $SECRETS_DIR/$acct (a missing dir is auto-created EMPTY by docker's bind mount, so the unit would start and immediately fail its auth guard)"

    ids+=("$id"); accounts+=("$acct")
done < "$FLEET_CONF"

[ "${#ids[@]}" -gt 0 ] \
    || die "$FLEET_CONF: no enabled units — an empty services block takes the whole fleet down on the next 'compose up'"

# Same silent-degradation class as KID_ROOT, one mount over: docker auto-creates
# an absent claude-standards EMPTY, and conventions.sh stages the standards with
# `[ -f … ] && cat`, so every review would run with no standards and zero signal.
# (repo-env stays unguarded — absent is a documented no-op.)
[ -d "$SECRETS_DIR/claude-standards" ] \
    || die "$SECRETS_DIR/claude-standards not found — docker would auto-create it empty and every review would run with no coding/review standards"
# Worse for the mount sources the loader sources: docker auto-creates a missing
# one as a DIRECTORY, and the consumer loads it with `[ -f … ] && . …`
# (lib/tracked-repos.sh) — the -f test fails against that dir and the source is
# skipped without a word, so the fleet comes up with no GH_TOKEN and an empty
# ORGS/REPOS and every reviewer idles reviewing nothing.
# The CONFIG_ENV read above stays `-f`-tolerant on purpose: it is a separate
# override knob (the smokes point it at a sandbox file), while what must exist
# is the MOUNT SOURCE the render below emits — which is always $SECRETS_DIR's.
# Legacy flat layout, checked BEFORE the existence loop below. repos.conf used
# to mount as a FILE; docker pins a file bind-mount to the source INODE, so an
# ordinary editor's write-temp-then-rename left the host file looking edited
# while every container kept serving the pre-edit manifest — silently, until the
# containers were recreated. It is a DIRECTORY mount now. Refuse to render
# rather than fall back to the flat path: a fallback would reinstate that bug.
# Order is load-bearing: run this AFTER the loop and it is unreachable (the loop
# already died on the absent manifest/repos.conf), so an operator on the old
# layout would get the generic not-found message instead of the migration —
# and its natural remedy, touching an empty manifest/repos.conf, renders fine
# and brings the fleet up reviewing NOTHING with their real manifest stranded.
if [ -f "$SECRETS_DIR/repos.conf" ] && [ ! -f "$SECRETS_DIR/manifest/repos.conf" ]; then
    die "$SECRETS_DIR/repos.conf is the legacy flat layout — the manifest is a DIRECTORY mount now so operator edits apply within one enumerate window instead of needing every container recreated. Migrate with: mkdir -p $SECRETS_DIR/manifest && mv $SECRETS_DIR/repos.conf $SECRETS_DIR/manifest/repos.conf"
fi
for f in config.env manifest/repos.conf; do
    [ -f "$SECRETS_DIR/$f" ] \
        || die "$SECRETS_DIR/$f not found — docker mounts a DIRECTORY over the missing file, the loader's [ -f ] test then skips it silently, and the fleet comes up with no GH_TOKEN / an empty ORGS+REPOS"
done

# The secrets mounts must render from the SAME path the rows were validated
# against, or an overridden SECRETS_DIR validates dir A and mounts dir B (and
# the smokes then never exercise the string that ships). Compose resolves a
# relative source against the compose file's own dir, so express it that way
# when possible — the shipped default renders as ./docker/secrets.
OUT_DIR="$(cd "$(dirname "$OUT")" && pwd)"
SECRETS_ABS="$(cd "$SECRETS_DIR" && pwd)"
case "$SECRETS_ABS" in
    "$OUT_DIR"/*) SECRETS_REF="./${SECRETS_ABS#"$OUT_DIR"/}" ;;
    *)            SECRETS_REF="$SECRETS_ABS" ;;
esac

# --- render (temp file; only moved into place once fully written) -----------
TMP="$(mktemp "${OUT}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

cat >"$TMP" <<'STATIC_HEADER'
# GENERATED FILE — do not edit.
# Source:     docker/secrets/fleet.conf
# Regenerate: just fleet
#
# N reviewer units on one host. Each reviewer shares its dind sidecar's
# network namespace (network_mode: service:dind-K) so `just test`'s
# published scenario ports land on a localhost the reviewer shares with
# the daemon, and DOCKER_HOST can be tcp://127.0.0.1:2375.
#
# The `claims` volume is SHARED across ALL reviewers (STATE_DIR=/shared): it
# holds runs/ review-state, the per-PR locks, the just-test concurrency
# semaphore (a host-wide memory cap, deliberately shared — see
# review-one-pr.sh), the locks/__enumerator election flock, and the
# enumerate-once work-list queue.json. The non-blocking per-PR flock + KNOWN_SHA
# gate dedup reviews across containers; one container per ENUMERATE_SECS window
# runs the GraphQL enumerate and writes queue.json, and every reviewer consumes
# it and claims PRs via the per-PR flock. LOCAL_STATE_DIR is per-container and
# holds the canonical clone/fetch lock + ephemeral per-PR KID query copies;
# per-account codex quota-pause + fatal-auth offline state lives in the SHARED
# /shared/pool/<WORKER_ID>/ namespace (lib/state-io.sh) so any account can
# render pool status.
# repos/, workdirs/, ~/.codex are per-container too.
#
# Scale-out: units are generated from docker/secrets/fleet.conf — add a row
# there (`just fleet`) rather than hand-editing this file. See fleet.conf's
# own header for the format and the operational notes on parking a unit.
# Memory: the per-unit caps below are CEILINGS, not reservations, and they
# deliberately over-commit — summing every unit's (20g reviewer + 12g dind)
# cap routinely exceeds host RAM. What actually bounds the aggregate is the
# shared just-test semaphore (MAX_CONCURRENT_TESTS, default 3), which rations
# the dind side host-wide; the reviewer side is unbounded across containers,
# so a simultaneous fleet-wide codex peak is arbitrated by the host OOM killer
# rather than by any cgroup — and it can reap prod Plow instead of a reviewer.
# Per-unit caps stay high so a single legitimate review isn't killed
# mid-flight. Revisit (lower the caps, or add a reviewer-side reservation) if
# real peaks ever approach the box.

x-dind: &dind
  image: docker:27-dind
  privileged: true
  environment:
    DOCKER_TLS_CERTDIR: ""          # plaintext daemon within the shared netns only
  # Bind loopback ONLY. reviewer-K shares dind-K's netns (network_mode below), so
  # 127.0.0.1 reaches its own daemon — but a sibling pair's netns can't, so a
  # 0.0.0.0 bind (reachable across the compose network) would let one reviewer
  # drive another account's daemon. Keep DOCKER_HOST=tcp://127.0.0.1:2375.
  #
  # `dockerd` MUST be the first token. dockerd-entrypoint.sh injects its own
  # default `--host=tcp://0.0.0.0:2375` whenever argv is empty or starts with `-`
  # (its line ~100). A bare `--host=…` first token trips that, so the entrypoint
  # ALSO appends 0.0.0.0:2375 — which both defeats the loopback-only intent and
  # collides on the port, so dockerd dies with "bind: address already in use".
  # Leading with `dockerd` skips the injection, binding ONLY the hosts below.
  command: ["dockerd", "--host=unix:///var/run/docker.sock", "--host=tcp://127.0.0.1:2375"]
  mem_limit: 12g

# Shared reviewer service contract (everything identical across accounts).
x-reviewer: &reviewer
  image: knightwatch-reviewer:dev
  restart: unless-stopped
  mem_limit: 20g

# Shared reviewer env; per-service blocks merge this and add WORKER_ID.
x-reviewer-env: &reviewer-env
  STATE_DIR: /shared              # per-PR lock + runs/ (SHARED across containers)
  REPOS_DIR: /local/repos         # per-container
  WORKDIRS_DIR: /local/workdirs   # per-container
  LOCAL_STATE_DIR: /local/state   # canonical clone/fetch lock + ephemeral KID query copies (per-container; quota-pause + fatal-auth offline live in shared STATE_DIR/pool/<WORKER_ID>/, just-test semaphore in shared STATE_DIR)
  DOCKER_HOST: tcp://127.0.0.1:2375
  CONFIG_ENV_FILE: /root/.kwr/config.env  # root-only path → reviewer-test (just test) can't read the token file
  REPOS_CONF_FILE: /shared/manifest/repos.conf  # read out of a DIRECTORY mount, not a file mount: docker pins a file bind-mount to the source inode, so an editor's write-temp-then-rename would leave every container serving the pre-edit manifest with no error. config.env stays a file mount above — it carries GH_TOKEN and must stay on the root-only path, off world-readable /shared.
  KWR_CONFIG_DIR: /root/.kwr-config       # mount point of the host-pulled kwr-config cache (read-only; see the per-reviewer volume). KWR_CONFIG_REPO lives in config.env — unset = no-op.
  REPO_ENV_DIR: /root/.kwr/repo-env       # root-only mount of operator per-repo secret env files (e.g. plow-pbc_plow/api/.env.test-live — live test-scenario creds CI has but a fresh container lacks). review-one-pr.sh seeds them into the canonical clone so the trusted-author .env mirror copies them into the per-PR test dir. Empty/absent = no-op.

# Per-unit mount notes (apply identically to every reviewer-N below; stated
# once here rather than repeated on each generated block):
#   - The codex-account mount is writable (NOT :ro): codex loads/migrates
#     config and refreshes its OAuth token inside its home — a read-only
#     mount makes every codex call die with "Error loading configuration:
#     Read-only file system". The creds stay protected by /root's 0700 perms
#     (the unprivileged test user can't reach /root at all), so dropping :ro
#     doesn't widen test-user access.
#   - The kwr-config mount's ${HOME} is left UNEXPANDED (unquoted heredoc,
#     literal `\${HOME}`): it resolves at `compose up` time, giving one
#     source of truth with the rendered systemd unit's path instead of
#     baking the generating user's $HOME in at render time.

services:
STATIC_HEADER

for i in "${!ids[@]}"; do
    n="${ids[$i]}"; acct="${accounts[$i]}"
    cat >>"$TMP" <<EOF
  dind-$n:
    <<: *dind
    volumes:
      - dind$n-lib:/var/lib/docker
      - scenario-shared$n:/scenario-shared   # token bridge; same path as reviewer-$n (PR #161)

  reviewer-$n:
    <<: *reviewer
    network_mode: "service:dind-$n"
    depends_on: [dind-$n]
    environment:
      <<: *reviewer-env
      WORKER_ID: "$n"
EOF
    [ -n "$KID_ROOT" ] && printf '      KWR_CLONE_ROOT: /kwr\n' >>"$TMP"
    cat >>"$TMP" <<EOF
    volumes:
      - claims:/shared
      - reviewer$n-local:/local
      - scenario-shared$n:/scenario-shared
      - $SECRETS_REF/$acct:/root/.codex          # writable: codex refreshes its OAuth token in-home
      - $SECRETS_REF/manifest:/shared/manifest:ro
      - $SECRETS_REF/config.env:/root/.kwr/config.env:ro
      - $SECRETS_REF/repo-env:/root/.kwr/repo-env:ro
      - $SECRETS_REF/claude-standards:/root/.claude:ro
      - \${HOME}/services/kwr-config:/root/.kwr-config:ro
EOF
    if [ -n "$KID_ROOT" ]; then
        printf '      - %s:/kwr:ro\n' "$KID_ROOT" >>"$TMP"
        for extra in $KID_EXTRA_MOUNTS; do printf '      - %s:%s:ro\n' "$extra" "$extra" >>"$TMP"; done
    fi
    printf '\n' >>"$TMP"
done

cat >>"$TMP" <<'EOF'
volumes:
  # EXTERNAL fixed-name so the shared review state (runs/ — the KNOWN_SHA dedup
  # history) survives project rename / down -v / prune. Setup + migration:
  # README § Containerized deployment. (reviewerN-local / dindN-lib stay
  # compose-managed — rebuildable state, not dedup history.)
  claims:
    external: true
    name: kwr_claims
EOF
for n in "${ids[@]}"; do printf '  reviewer%s-local:\n' "$n" >>"$TMP"; done
for n in "${ids[@]}"; do printf '  dind%s-lib:\n' "$n" >>"$TMP"; done
printf '  # Per-pair token-passing bridge for nested-dind scenario stacks (see dind-%s).\n' "${ids[0]}" >>"$TMP"
for n in "${ids[@]}"; do printf '  scenario-shared%s:\n' "$n" >>"$TMP"; done

mv "$TMP" "$OUT"
trap - EXIT
printf 'render-compose: wrote %s (%d units: %s)\n' "$OUT" "${#ids[@]}" "${ids[*]}"
