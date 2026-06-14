# Reviewer container secrets (NEVER COMMITTED)

Copy this directory to `docker/secrets/` and populate it. `docker/secrets/`
is gitignored — the live account credentials and tokens live there and must
never be committed.

```
cp -r docker/secrets.example docker/secrets
# then populate the files below
```

## Files

| Path | Shared / per-account | Contents |
| --- | --- | --- |
| `config.env` | shared | Ops knobs + child-process tokens, **shell-sourced** by `review.sh` (via `CONFIG_ENV_FILE`). Mounted at the **root-only** path `/root/.kwr/config.env` so the unprivileged `reviewer-test` user that runs `just test` can't read the token *file* (the `env -i` scrub only covers its environment). Use `export GH_TOKEN=…` so `gh` and the worker inherit it. `ANTHROPIC_API_KEY` does NOT belong here — it's a `just test` dependency delivered via the `.env` mirror below, not the reviewer env. **Operator-managed review config (optional):** to activate it set `export KWR_CONFIG_REPO=https://github.com/<you>/kwr-config.git` here **and** in the host `~/.pr-reviewer/config.env` (both are sourced — host `install.sh`/org-sync pull the `${HOME}/services/kwr-config` cache, the containers read it via the read-only `/root/.kwr-config` mount). Unset = the config layer is a no-op. Use a credential helper / ssh key for a private repo — never an inline-credential URL (the worker rejects userinfo/token-bearing URLs). |
| `repos.conf` | shared | The tracked-target manifest. For whole-org coverage set `ORGS=(...)` (every non-archived open PR in the org is reviewed, new repos included, via one batched search per org per tick); reserve `REPOS=(...)` for specific repos in partially-tracked orgs (kept OUT of ORGS). Also holds `KID_PATHS`/`SOURCE_PATHS`. Mounted into the shared volume at `/shared/repos.conf`. Start from the repo-root `repos.conf.example`. |
| `claude-standards/` | shared | The four review-standards files the worker stages into the prompt: `CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`, `COMMENT_REVIEW_MISTAKES.md`. Mounted read-only at `/root/.claude`. Copy just these four from your `~/.claude` — NOT the whole dir, so prompt-injectable review agents can't read global config/secrets. |
| `codex-account-a/` | reviewer-1's OpenAI account | A full `~/.codex` directory for account A (must contain `auth.json`). Mounted **writable** at reviewer-1's `/root/.codex` — codex rotates its own tokens/session state, and fatal-auth recovery keys on a newer `auth.json` mtime. If a worker goes offline on invalid auth, re-login that account's dir (`CODEX_HOME=docker/secrets/codex-account-a codex login --device-auth`, or copy in a fresh `auth.json`); the newer mtime auto-clears the offline marker. |
| `codex-account-b/` | reviewer-2's OpenAI account | Same, for account B → reviewer-2. |

## Live-credential `just test` (trusted-author scenario suites)

There is **no single `.env.test-live` mount**. The worker mirrors real env
files into each PR checkout by, for every `.env*.example` the target repo
ships, copying the matching real file (name minus `.example`) **from that
repo's canonical clone working tree** — see `lib/review-one-pr.sh` §"mirror
.env from canonical". For plow that means `api/.env.test-live`,
`cli/.env.test-live`, etc., must exist inside the canonical clone at
`$REPOS_DIR/<repo-slug>/...` (a per-container volume).

Wiring that seeding into the container lifecycle is a **bring-up step**
(see the plan's Task 7): place each repo's real env files into its canonical
clone after the first clone. Until then, trusted-author scenario suites that
require live keys trip their `${VAR:?}` guards — the same graceful behavior
untrusted PRs already get. Non-scenario tests are unaffected.

## Generating a codex account directory

Run `codex login` once on any machine logged into that OpenAI/ChatGPT account,
then copy its `~/.codex` here:

```
cp -r ~/.codex docker/secrets/codex-account-a
```

Only `auth.json` is strictly required; copying the whole dir is simplest.

## Adding a third account (scale-out)

1. `cp -r ~/.codex docker/secrets/codex-account-c` (account C's login).
2. In `docker-compose.yml`, add a `dind-3` (`<<: *dind` + its `dind3-lib` and
   `scenario-shared3:/scenario-shared` volumes) and a `reviewer-3` that reuses
   the shared contract — `<<: *reviewer` and `<<: *reviewer-env` — overriding
   only `network_mode: service:dind-3`, `WORKER_ID: "3"`, the `reviewer3-local`
   volume, the `scenario-shared3:/scenario-shared` bridge (same path as dind-3,
   so the nested-dind scenario token mount resolves), and the `codex-account-c`
   mount. Add `reviewer3-local` + `dind3-lib` + `scenario-shared3` to the
   `volumes:` block.
3. `docker compose up -d`.

Mind the host memory budget: each unit's `reviewer` + `dind` mem_limits sum
toward the box's total — keep headroom for production Plow.
