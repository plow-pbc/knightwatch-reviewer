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
| `repo-env/` | shared | Operator per-repo secret env files seeded into each reviewed repo's canonical clone for the trusted-author `.env` mirror (live `just test` creds CI has but a fresh container lacks — e.g. plow's `ANTHROPIC_API_KEY`). Layout: `repo-env/<repo-slug>/<relpath>` (e.g. `repo-env/plow-pbc_plow/api/.env.test-live`). Mounted **read-only** at the root-only `/root/.kwr/repo-env`. Optional — omit for repos needing no live creds. See *Live-credential `just test`* below. |
| `codex-account-a/` | reviewer-1's OpenAI account | A full `~/.codex` directory for account A (must contain `auth.json`). Mounted **writable** at reviewer-1's `/root/.codex` — codex rotates its own tokens/session state, and fatal-auth recovery keys on a newer `auth.json` mtime. If a worker goes offline on invalid auth, re-login that account's dir (`CODEX_HOME=docker/secrets/codex-account-a codex login --device-auth`, or copy in a fresh `auth.json`); the newer mtime auto-clears the offline marker. |
| `codex-account-b/` | reviewer-2's OpenAI account | Same, for account B → reviewer-2. |

## Live-credential `just test` (trusted-author scenario suites)

Some suites need real credentials — plow's `test-scenarios` requires
`ANTHROPIC_API_KEY` (+ Gmail/Slack tokens) from `api/.env.test-live`, which CI
has but a fresh container lacks. Provide them via the **`repo-env/` mount**:

```
docker/secrets/repo-env/<repo-slug>/<relpath>
# e.g. docker/secrets/repo-env/plow-pbc_plow/api/.env.test-live
```

`<repo-slug>` is the repo with `/`→`_` (`plow-pbc/plow` → `plow-pbc_plow`);
`<relpath>` mirrors the path inside the repo so the seeded file lands next to
the matching `.env*.example`. The dir is mounted read-only at the root-only
`/root/.kwr/repo-env` (the unprivileged `reviewer-test` user can't read it).

> **Renaming a tracked repo? Rename its `repo-env/<slug>` dir to match, in the
> same change.** The slug is the lookup key, so creds left under the old name are
> simply not found: the seed is a **clean no-op** — no log line, no warning — the
> `.env` mirror copies nothing, and `just test` then dies at its
> `${ANTHROPIC_API_KEY:?}` gate *after* every unit suite has passed. The reviewer
> posts a generic `🧪 Tests failed (exit 1)` on every PR in that repo, and the
> test-coverage specialist reasons against that phantom failure. `cncorp/plow` →
> `plow-pbc/plow` cost **208 reviews, 0 passes, over five days** before anyone
> noticed (#171). The tell: CI is green and local `just test` is green, but the
> reviewer fails every PR — that combination is always reviewer-side infra, never
> the PR.
>
> The slug also keys the review-history dir (`runs/<slug>__<pr>__*`, in the
> `kwr_claims` volume at `/shared/runs`), which the dedup gate reads to skip
> already-reviewed heads. A rename orphans that too — but unlike the creds gap this
> is **one-time and self-healing**: the first tick after finds no history and
> re-reviews every open PR in the repo once (duplicate comments plus a round of
> Codex spend), then new runs land under the new slug and dedup resumes on the next
> tick. Just expect the flood; migrating the history dirs to dodge it isn't worth
> the fiddliness for a one-time cost.

`lib/review-one-pr.sh` seeds these into the repo's **canonical clone** right
after the canonical fetch; the existing **trust-gated** `.env` mirror (for every
`.env*.example` the repo ships, copy the matching real file) then delivers them
into each trusted-author PR checkout. Untrusted PRs never receive them —
`git clone --shared` carries only tracked content and the mirror is push-access-
gated — so their `${VAR:?}` guards trip with the same graceful behavior as
before. Repos that need no live creds just omit their subdir (clean no-op);
non-scenario tests are unaffected.

**Rotating / withdrawing a credential:** the seed *copies* (it doesn't prune),
so replacing a host file rotates the cred on the next review (overwrite), but
*removing* one leaves the prior copy in the persistent canonical clone. To fully
withdraw, remove the host file **and** drop the canonical copy — `docker compose
down -v` (the seed re-provisions only what's still in `repo-env/` on the next
review) or `docker exec <reviewer> rm /local/repos/<slug>/<relpath>`. The stale
copy only reaches trusted-author test runs (never untrusted PRs), so a revoked
key surfaces as a loud test failure, not an exposure.

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
   so the nested-dind scenario token mount resolves), the shared
   `./docker/secrets/repo-env:/root/.kwr/repo-env:ro` mount (same on every
   reviewer), and the `codex-account-c` mount. Add `reviewer3-local` +
   `dind3-lib` + `scenario-shared3` to the
   `volumes:` block.
3. `docker compose up -d` to create the new pair, then `sudo systemctl start
   knightwatch-reviewer.service` to keep the fleet under systemd ownership
   (graceful `stop` + `PartOf`), matching the main README's bring-up — a no-op if
   the unit is already active.

Mind the host memory budget: each unit's `reviewer` + `dind` mem_limits sum
toward the box's total — keep headroom for production Plow.
