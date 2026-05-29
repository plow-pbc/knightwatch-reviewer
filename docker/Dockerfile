# Reviewer image: everything review-one-pr.sh shells out to, plus the
# docker CLI to talk to the dind sidecar. Repo code is COPYed in; target
# repos are cloned at review time into the per-container REPOS_DIR.
FROM node:24.15.0-bookworm

# gh 2.90.0: review-one-pr.sh requests the `closingIssuesReferences` field on
# `gh pr view --json`. Despite an earlier claim that 2.65 added it, 2.65.0
# actually rejects it ("Unknown JSON field") — it lands in a later release. Pin
# a version verified to speak it (install.sh enforces the same floor); a too-old
# gh makes every PR_DATA fetch return empty and aborts the review before posting.
ARG GH_VERSION=2.90.0
ARG JUST_VERSION=1.36.0
ARG DOCKER_CLI_VERSION=27.3.1
ARG CODEX_CLI_VERSION=0.134.0

# sqlite3 + shellcheck: a target repo whose `just test` runs directly in THIS
# container (no docker-compose-in-dind — e.g. knightwatch-reviewer reviewing
# itself) needs its own dev test deps. The reviewer's smoke suite shells out to
# sqlite3 (the bakeoff.db store) and shellcheck (12 smokes); without them
# `just test` aborts at exit 127 and reviews post "🧪 Tests not run".
RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq ca-certificates curl gnupg coreutils procps python3 python3-venv \
      sqlite3 shellcheck \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.deb" -o /tmp/gh.deb \
 && apt-get install -y /tmp/gh.deb && rm /tmp/gh.deb \
 && curl -fsSL https://just.systems/install.sh | bash -s -- --tag "${JUST_VERSION}" --to /usr/local/bin \
 && rm -rf /var/lib/apt/lists/*

# docker CLI (client only — the daemon lives in the dind sidecar)
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/d.tgz \
 && tar -xzf /tmp/d.tgz -C /usr/local/bin --strip-components=1 docker/docker \
 && rm /tmp/d.tgz

# uv (python tool runner used by plow `just test`)
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# codex CLI (npm global) — the gpt-5.5 reviewer agents. Pinned so a rebuild
# can't change reviewer behavior outside the PR diff (matches GH/JUST/DOCKER pins).
RUN npm install -g "@openai/codex@${CODEX_CLI_VERSION}"

# Authenticate HTTPS git clone/fetch via gh's credential helper (root's global
# config). The helper shells out to `gh auth git-credential`, which reads
# GH_TOKEN at runtime — sourced from the root-only config.env by
# tracked-repos.sh — so canonical clones of PRIVATE repos succeed without baking
# a token into the image. `gh pr view` already worked off GH_TOKEN, but git over
# HTTPS does NOT read it on its own (clones failed: "could not read Username").
# The unprivileged reviewer-test user has its own $HOME and no GH_TOKEN, so it
# can't reuse this helper to read private code.
RUN git config --global credential."https://github.com".helper '!gh auth git-credential'

# Unprivileged user that PR-controlled `just test` runs as (REVIEWER_TEST_USER).
# It owns its own $HOME but cannot read root-owned /root/.codex or the reviewer
# tokens — see run_just_test in lib/run-dir.sh. `just test` reaches the dind
# daemon over DOCKER_HOST (tcp), so no docker-group / socket access is needed.
RUN useradd --create-home --uid 10001 reviewer-test

WORKDIR /app
COPY . /app
RUN chmod +x review.sh review-loop.sh lib/*.sh

# State dirs (STATE_DIR / REPOS_DIR / WORKDIRS_DIR / LOCAL_STATE_DIR) and
# DOCKER_HOST are provided at runtime by docker-compose.yml.
ENTRYPOINT ["./review-loop.sh"]
