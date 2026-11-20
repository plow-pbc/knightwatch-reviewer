#!/bin/bash
# Runs as codex-reviewer with the same allowlisted environment as review agents.
# Any success here is a credential-boundary failure, so container startup stops.
set -uo pipefail

fail() { echo "[codex-isolation] FATAL: $*" >&2; exit 1; }

token_env=$(env | grep -i token || true)
[ -z "$token_env" ] || fail "token-bearing environment reached Codex"

for protected in \
    /root/.kwr/config.env \
    /root/.kwr/repo-env \
    '/root/.config/gh' \
    /home/reviewer-test/.docker; do
    [ ! -r "$protected" ] || fail "Codex can read protected credential path: $protected"
done

# This is an offline credential-presence probe, not an API call; bypass the
# fleet rate-limit wrapper so a missing credential cannot stamp shared state.
command gh auth status >/dev/null 2>&1 \
    && fail "GitHub CLI found credentials in the Codex child context"

echo "[codex-isolation] PASS: token env empty; protected paths and gh auth unavailable"
