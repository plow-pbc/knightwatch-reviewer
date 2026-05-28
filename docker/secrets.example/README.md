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
| `shared.env` | shared by all reviewers | `GH_TOKEN`, `ANTHROPIC_API_KEY`, `BOT_USER`, and any other `config.env`-style knobs. Sourced into every reviewer via `env_file`. |
| `repos.conf` | shared | The tracked-repo manifest (`REPOS=(...)`, `KID_PATHS`). Mounted into the shared volume at `/shared/repos.conf`. Start from the repo-root `repos.conf.example`. |

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
| `codex-account-a/` | reviewer-1's OpenAI account | A full `~/.codex` directory for account A (must contain `auth.json`). Mounted read-only at reviewer-1's `/root/.codex`. |
| `codex-account-b/` | reviewer-2's OpenAI account | Same, for account B → reviewer-2. |

## Generating a codex account directory

Run `codex login` once on any machine logged into that OpenAI/ChatGPT account,
then copy its `~/.codex` here:

```
cp -r ~/.codex docker/secrets/codex-account-a
```

Only `auth.json` is strictly required; copying the whole dir is simplest.

## Adding a third account (scale-out)

1. `cp -r ~/.codex docker/secrets/codex-account-c` (account C's login).
2. In `docker-compose.yml`, add a `dind-3` + `reviewer-3` pair (copy the
   `dind-2`/`reviewer-2` blocks), set `WORKER_ID: "3"`, mount
   `codex-account-c`, and add `reviewer3-local` + `dind3-lib` volumes.
3. `docker compose up -d`.

Mind the host memory budget: each unit's `reviewer` + `dind` mem_limits sum
toward the box's total — keep headroom for production Plow.
