# Reviewer image: everything review-one-pr.sh shells out to, plus the
# docker CLI to talk to the dind sidecar. Repo code is COPYed in; target
# repos are cloned at review time into the per-container REPOS_DIR.
FROM node:24.15.0-bookworm

# gh >= 2.65 required: review-one-pr.sh requests the closingIssuesReferences
# JSON field (install.sh enforces the same floor); older gh aborts the review.
ARG GH_VERSION=2.65.0
ARG JUST_VERSION=1.36.0
ARG DOCKER_CLI_VERSION=27.3.1

RUN apt-get update && apt-get install -y --no-install-recommends \
      git jq ca-certificates curl gnupg coreutils python3 python3-venv \
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

# codex CLI (npm global) — the gpt-5.5 reviewer agents
RUN npm install -g @openai/codex

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
