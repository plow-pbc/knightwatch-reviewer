#!/bin/bash
# Refresh the docker registry credential the reviewers' `just test` pulls with
# (every 6h via systemd; the token lives 12h). Without it every dind daemon
# pulls public.ecr.aws anonymously from this one IP, and a base-image bump that
# ten daemons each fetch trips ECR Public's anonymous throttle — the test step
# then fails with `toomanyrequests: Rate exceeded` before any test runs.
#
# The key is a dedicated IAM user allowed only ecr-public:GetAuthorizationToken
# + sts:GetServiceBearerToken, because the written config.json is readable by
# the PR-controlled test user: what leaks is a 12h pull credential, nothing more.
# Written to a DIRECTORY bind (not a file bind) so the temp+rename below swaps
# the file the containers see.
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO_DIR="$(dirname "$(readlink -f "$0")")"
KEY_FILE="${ECR_PUBLIC_ENV:-$REPO_DIR/docker/secrets/ecr-public.env}"
AUTH_DIR="${DOCKER_AUTH_DIR:-$HOME/.pr-reviewer/docker-auth}"

[ -f "$KEY_FILE" ] || { echo "FATAL: $KEY_FILE missing — it holds the pull-only IAM key (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
. "$KEY_FILE"
set +a
tmp=$(mktemp "$AUTH_DIR/.config.json.XXXXXX")
trap 'rm -f "$tmp"' EXIT
# The token flows stdin-to-stdin, never through argv or the journal.
{ printf 'AWS:'; AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null \
    aws ecr-public get-login-password --region us-east-1; } \
    | base64 -w0 | jq -Rc '{auths: {"public.ecr.aws": {auth: .}}}' >"$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$AUTH_DIR/config.json"
echo "refreshed public.ecr.aws credential in $AUTH_DIR/config.json"
