# knightwatch-reviewer

An AI code reviewer that traces causality across files, not patterns within them.

## What's different

Most AI reviewers do single-file pattern matching. Useful, but they miss bugs that only emerge from how files and systems interact.

Here's a real PR that switched the production database from password auth to RDS IAM tokens. GitHub Copilot's reviewer commented on three single-file patterns. The most substantive of the three:

**Copilot, inline on `api/svc/db/session.py`:**
> `sslmode=require` encrypts the connection but does not verify the server certificate/hostname in Postgres, so it's vulnerable to MITM within the network. Consider `sslmode=verify-full`…

Reasonable. But that's a hardening note, not a finding that would stop the merge.

**Knightwatch's review on the same PR:**
> **[blocking]** IAM rollout would crash the API at startup. `entrypoint.sh` runs `migrate up` before the web server, but `migrations/env.py` builds a plain engine without the IAM hook (which is only wired into `build_runtime_engine`). Since `infra/locals.tf` removes the legacy password env var, the migration step would attempt passwordless auth as `svc_app` and the API would never boot. Reuse `get_migration_connection()` so the migration path and runtime obtain credentials the same way.

The bug isn't visible in any single file. It only shows up when you stitch shell startup + the migration engine builder + the infra env config + the location of the IAM hook. That's the kind of catch knightwatch is designed for.

Two more, from the public [`tkmx-client`](https://github.com/srosro/tkmx-client) reporter:

- **[#19 — legacy daemons would silently stop after `git pull`](https://github.com/srosro/tkmx-client/pull/19#issuecomment-4357873121)**. Deleting `reporter/report.js` and pointing new installs at `dist/reporter/report.js` would leave already-installed launchd/systemd units calling the removed path, because the documented update path is `git pull && npm install` and that doesn't rerun `install-service`. Caught by stitching the diff against the install script, the README's update instructions, and the systemd/launchd unit `ExecStart=` that reaches into the source tree.
- **[#19 — recurring schema-ownership drift](https://github.com/srosro/tkmx-client/pull/19#issuecomment-4358179972)**. Flagged the third instance of the same DTO-ownership class — each new consumer re-deriving usage shapes from `agentsview` rather than one neutral seam — and asked for a refactor at the right level instead of another local patch. Fixed by extracting `reporter/usage.ts` as the single owner.

## How it works

A timer polls tracked repos for new or updated PRs. For each, it runs a two-wave pipeline:

- **Wave A** (parallel): two **standalone** stages — `intent` (infers the end-user-facing outcome the PR is reaching for) and `dead-code-search` (pre-pass static + LLM evidence). Both seed scratch inputs the next wave reads.
- **Wave B** (parallel): the seven **specialists** — `security`, `data-integrity`, `architecture-refined` (over-engineering + DRY/duplication), `contract-drift`, `consumers`, `shape`, `tests` — each looking at one angle of the diff against the rest of the repo. On re-reviews, the `momentum` standalone joins Wave B (it tracks LOC trajectory and prior-round drift). Each specialist emits structured **probes** (hypothesis + severity + class), and a per-angle `critic` then resolves each probe (`Answer: yes/no/unknown` + evidence).
- **Aggregator** (sequential): renders a single ranked **Probes** section with `[from: <specialist>]` attribution, a verdict (`APPROVE` or one or more blocking probes), and an AI-author callout so Codex/Claude Code/Cursor can parse load-bearing open probes directly. A marker (`<!-- knightwatch-reviewer:auto-post -->`) tags every post so reply automation and human babysitting can filter cleanly.

```mermaid
flowchart TB
    PR([PR opened or updated]) --> WA

    subgraph WA[Wave A — parallel pre-pass]
        direction LR
        intent[intent<br/>infer end-user goal]
        dcs[dead-code-search<br/>static + LLM evidence]
    end

    WA --> scratch[(.codex-scratch/<br/>inferred-intent.md<br/>dead-code.md)]
    scratch --> WB

    subgraph WB[Wave B — 7 specialists in parallel; each chains to a per-angle critic]
        direction LR
        sec[security] --> ksec[critic]
        di[data-integrity] --> kdi[critic]
        archref["architecture-refined"] --> karchref[critic]
        tst[tests] --> ktst[critic]
        shp[shape] --> kshp[critic]
        cd["contract-drift"] --> kcd[critic]
        cons[consumers] --> kcons[critic]
        mom["momentum<br/>(re-review only)"]
    end

    WB --> agg["aggregator<br/>merge · dedupe · rank"]
    agg --> out([Posted review:<br/>VERDICT + ranked Probes])
```

The bot signs as a real GitHub user, so reviews appear under that account.

## Install

```sh
git clone git@github.com:srosro/knightwatch-reviewer.git
cd knightwatch-reviewer
./install.sh
```

`install.sh` symlinks scripts into `~/.pr-reviewer/`, copies the `systemd/*.{service,timer}` files into `/etc/systemd/system/`, daemon-reloads, enables the timers, and `enable`s the boot-managed reviewer-fleet unit (`knightwatch-reviewer.service`) so the containers come back after a reboot. It does **not** start the fleet — that's the `systemctl start` in the containerized deployment below, after the image + secrets exist — so `install.sh` is safe to run before the container stack is built. Idempotent — re-run after pulling changes.

Single-tenant by design: one Linux host with `gh` authenticated as the bot's signing user. The systemd units currently bake in `User=odio` and `/home/odio/.pr-reviewer/`; edit them for a different user or path.

> **The review loop is containerized.** `install.sh` sets up the **auxiliary host timers** — auto-discovery (`org-sync`), auto-calibration (`learn`), `poll` (the merged /srosro-approve + re-request-review poller), `kid-refresh`, and the specialist `bake-off` — plus the boot-persistence unit for the fleet. The reviewer itself runs in the **containerized multi-account deployment below** — it spreads reviews across N accounts and confines each review (PR code + codex agents) to a container. The legacy single-account host reviewer (`pr-reviewer.timer`/`.service`) has been retired in its favor; `install.sh` removes the stale units if a prior install left them. No cutover drain is needed before `docker compose up -d`: the host reviewer was disabled ahead of this change, its detached workers are bounded to ~90m (`WORKER_TIMEOUT`), and nothing here re-creates a host reviewer — `review.sh` now runs only as the container loop's entrypoint — so no detached `review-one-pr.sh` from `~/.pr-reviewer` can still be posting by the time the containers start.

### Containerized (multi-account) deployment

Runs N reviewer containers on one host, each pinned to its own OpenAI account and claiming PRs through a shared lock volume (the existing non-blocking per-PR flock + `KNOWN_SHA` gate dedup across containers). Each reviewer gets its own privileged `docker:dind` sidecar so the target repo's `just test` (docker-compose) runs nested, not on the host daemon.

```sh
cp -r docker/secrets.example docker/secrets   # then populate — see docker/secrets.example/README.md
# fleet.conf comes along with the -r copy above; edit it to list your accounts.
docker build -f docker/Dockerfile -t knightwatch-reviewer:dev .
# Create the EXTERNAL `claims` volume that holds the shared review state (runs/ —
# the KNOWN_SHA dedup history). It's external (fixed name) so it survives project
# rename / `docker compose down -v` / prune / re-up from a new dir; a
# compose-managed `<project>_claims` is lost on those and a cold runs/ makes the
# reviewer re-review every open PR (duplicate comments + codex burn).
docker volume create kwr_claims
# UPGRADE ONLY (an existing deployment already has review history): seed the new
# volume from the old compose-managed one BEFORE first `up`, or the empty runs/
# triggers exactly that re-review flood. Fresh installs skip this. Replace
# <OLD> with the prior project's volume (e.g. `knightwatch-reviewer_claims` —
# `docker volume ls | grep claims`):
#   docker run --rm -v <OLD>:/old -v kwr_claims:/new alpine \
#     sh -c 'cp -a /old/. /new/'
# First bring-up via systemd (after `./install.sh` has enabled the unit) so the
# fleet's lifecycle is systemd-owned from the start — graceful `stop` on
# shutdown + restart-in-tandem on a docker daemon restart (PartOf). ExecStart is
# `docker compose up -d`, so this both starts the stack AND hands it to systemd.
# Always finish a bring-up this way: a bare `docker compose up -d` starts the
# containers but leaves this unit inactive, so graceful stop + PartOf don't apply
# until the next boot. (A redeploy does its staggered `up -d` for zero downtime,
# then `systemctl start` here to re-establish systemd ownership.)
just fleet   # renders docker-compose.yml from docker/secrets/fleet.conf — not in git
sudo systemctl start knightwatch-reviewer.service
docker compose logs -f reviewer-1
```

The auxiliary host timers (`-poll` — the merged /srosro-approve + re-request-review poller — `-kid-refresh`, `-org-sync`, `-learn`, `-bakeoff`) run host-side, independent of the containerized review loop. The containers read only `/shared/manifest/repos.conf` and the secrets mounts — never host *state* — with two read-only exceptions: (1) if the operator activates the operator-managed review config (set `KWR_CONFIG_REPO` in `~/.pr-reviewer/config.env` **and** `docker/secrets/config.env`), the host-pulled `${HOME}/services/kwr-config` cache is bind-mounted **read-only** at `/root/.kwr-config` into every reviewer (`install.sh` does the first pull, the `-org-sync` timer keeps it fresh); and (2) if the operator wires kid prior-art (see [kid prior-art](#kid-prior-art) below), the host-built `.keepitdry` indices are bind-mounted **read-only** into each reviewer. Two notes follow:
- **Review coverage comes from `ORGS`, not `repos.conf.auto`.** Set `ORGS=(plow-pbc srosro)` in `docker/secrets/manifest/repos.conf` for whole-org review (every non-archived open PR, new repos included, via one batched search per org per tick); keep only partial orgs in `REPOS` (owners NOT in `ORGS`, e.g. `some-org/one-repo`). The containers never read `pr-reviewer-org-sync`'s `~/.pr-reviewer/repos.conf.auto` — and with `ORGS` they don't need to; org-sync's role is now just cloning org repos host-side for kid-prior-art.
- **Calibration is host-only in v1.** `pr-reviewer-learn` updates `~/.claude/COMMENT_REVIEW_MISTAKES.md`, but the containers read the static `docker/secrets/claude-standards/` copy → re-copy that file (or mount the live one read-only) to pick up new calibrations.

Fully reconciling these into one shared host/container seam is the tracked follow-up in `REVIEW.md`.

**Redeploying onto this fleet.conf migration.** `docker-compose.yml` is generated (`just fleet`) and no longer tracked in git, so `git pull` deletes the working-tree file the moment the merge commit lands — until a render runs, `docker compose` (including systemd's `ExecStop`) has no file to act on. In order:

1. **Author `docker/secrets/fleet.conf` first**, while the old tracked compose file is still on disk. Write it out directly rather than copying `docker/secrets.example/fleet.conf` — that example is delivered by the very `git pull` in step 4, so it does not exist on the deployed checkout yet. It must name every account **currently running**; a file listing fewer units than are up will make `docker compose up -d --remove-orphans` tear down the missing ones. On the production host today that is these five rows verbatim:

   ```sh
   cat > docker/secrets/fleet.conf <<'EOF'
   # <worker-id>  <codex-account-dir, relative to docker/secrets/>
   1  codex-account-a
   2  codex-account-b
   3  codex-account-c
   4  codex-account-d
   5  codex-account-e
   EOF
   ```

   A missing `fleet.conf` fails loudly at render time (`render-compose: FATAL: no fleet.conf …`) by design; it does not silently render an empty fleet.
2. **Retire any deployed `docker-compose.override.yml`**, still ahead of the render. Port **every** mount it declares into `docker/secrets/config.env` — the clone root into `KID_ROOT`, any other index into `KID_EXTRA_MOUNTS` (see [kid prior-art](#kid-prior-art); on the production host today that is `KID_ROOT=/home/odio/services/kwr-repos` plus `KID_EXTRA_MOUNTS=/home/odio/Hacking/plow-kid`, and dropping the second one silently disables prior art on plow). Then delete the override — it stays gitignored so an uncleaned deployment doesn't trip the deploy preflight, but leaving it in place means compose keeps auto-merging a file the generator no longer expects. If the deployment also carries a `config.env.bak-kid`, check whether it holds kid wiring that needs porting alongside the override before deleting either. This is `config.env` **only** — the manifest move is step 3 and the `KID_PATHS` edit belongs in step 6.
3. **Migrate the manifest to the directory layout** — `mkdir -p docker/secrets/manifest && mv docker/secrets/repos.conf docker/secrets/manifest/repos.conf`. Do this while the old layout is still intact, *ahead of the render*: the manifest is a directory mount now (so operator edits apply without recreating containers), and `just fleet` refuses to render a flat `docker/secrets/repos.conf` rather than fall back to a file mount. Skip it and step 4 dies — inside the no-compose-file window its ordering exists to avoid. The die names this exact command if you hit it anyway.
4. `git pull && just fleet` as **one step**, never split across a pause — that pause is the no-compose-file window above.
5. `./install.sh` — idempotent, and the only step that copies `systemd/*.service` into place + daemon-reloads. This migration *edits* the fleet unit (`ExecStartPre` renders the compose file before every `up`; `ExecStop` self-heals a missing one). Skip it and step 6 restarts the **pre-migration** unit with no signal that anything is missing — step 4 already left a compose file on disk, so the next `up` succeeds and the render-before-up guarantee simply never lands.
6. `sudo systemctl restart knightwatch-reviewer.service` — **always, whatever the kid wiring**: this is what puts step 5's freshly-installed unit in charge and recreates every container against the re-rendered mounts. One rider, only if the deployment sets `KID_EXTRA_MOUNTS` (prod does): **immediately** before that restart, never split across a pause from it, change `docker/secrets/manifest/repos.conf`'s `KID_PATHS` entry for `["plow-pbc/plow"]` from `/kid-ro/plow-kid` to `/home/odio/Hacking/plow-kid`, since each extra index now mounts at the **same path inside the container**. Either half alone is inconsistent: the containers re-source `/shared/manifest/repos.conf` per review so the new value takes effect the instant it lands, while the matching mount only arrives when the restart recreates them — pause in between and every plow review silently falls through to `kid index not yet built … — skipping prior-art lookup`. (Follow-up, not this PR: relocating plow's index under `KID_ROOT` would remove the need for `KID_EXTRA_MOUNTS`, and this rider, altogether.)

**Security note — before you deploy:** the dind sidecar runs `--privileged`, and the sandbox-bypassed codex agents share its network namespace (`DOCKER_HOST`), so a successful prompt-injection of a review agent could drive the daemon → host root. Untrusted `just test` is already skipped, but the codex path is an **accepted v1 residual to resolve at bring-up** — make the daemon unprivileged (rootless dind / sysbox) or run codex in a container that doesn't share dind, and verify against the live suite, before standing this up against real PRs.

`docker compose config` validates the topology before bringing it up. Add an account by appending a row to `docker/secrets/fleet.conf` and re-running `just fleet` (see `docker/secrets.example/README.md` § Adding the Nth account). Each unit's `reviewer` + `dind` memory limits sum toward the host budget — keep headroom for anything else on the box.

**Watching one review.** `docker compose logs -f reviewer-1` follows a whole unit; to follow a single PR instead, read its per-run dir on the shared `claims` volume. Every worker writes `runs/<slug>__<pr>__<ts>__<sha7>/` containing `run.log` (the worker's own log lines), plus per-agent `prompt.txt` (what the agent was sent), `output.md` (its verdict), `log.txt` (codex **stdout** — model reasoning), and `err.txt` (codex **stderr** — quota / auth / network errors land here, so this is the file to check on a failure). Any reviewer container can read the volume, so pick one and resolve the PR's newest run:

```sh
CID=$(docker ps -q --filter name=knightwatch-reviewer-reviewer- | head -1)
SLUG=cncorp_plow; PR=523
NEWEST='r=$(ls /shared/runs | grep "^'"$SLUG"'__'"$PR"'__" | sort | tail -1)'

# the worker's own log
docker exec "$CID" sh -c "$NEWEST"'; tail -f "/shared/runs/$r/run.log"'

# one agent's reasoning, then the errors it hit (aggregator is the usual suspect on a stall)
docker exec "$CID" sh -c "$NEWEST"'; tail -f "/shared/runs/$r/agents/aggregator/log.txt"'
docker exec "$CID" sh -c "$NEWEST"'; cat "/shared/runs/$r/agents/aggregator/err.txt"'
```

`-f` is for a run still in flight — swap `tail -f` for `cat` on a finished one, which is the usual case when `err.txt` is what you're after.

The per-agent files exist only once the agent pipeline has started. A run that aborted before then — e.g. canonical clone, `--unshallow`, base-ref fetch — keeps `run.log` and two empty dirs, so `agents/` being empty *is* the diagnosis: read `run.log`, which carries the abort reason.

A tick that skipped *cleanly* — the `refs/pull/N/head` fetch failed (usually the head isn't published yet — a persistent auth or repo-access failure fails the base-ref fetch one call earlier and lands in the paragraph above; when it's something else, the truncated `fetch_err` is all you get), or the head was already reviewed by a concurrent worker — discards its run dir outright, so `$NEWEST` silently resolves to an **earlier** run. Check the `__<ts>__` in `$r` against the clock before trusting what you're reading; the skip line, carrying the fetch error when there was one, goes to `/shared/orchestrator.log` rather than to any run dir.

`sort | tail -1`, not `ls -t | head -1`: `RUN_ID`'s embedded UTC timestamp makes lexical order chronological, so picking the newest needs no `stat()`. `ls -t` needs one per entry, so a prune that catches the newest matching dir makes it print `cannot access` on stderr and quietly hand back an older run — quietly because `head`'s status, not `ls`'s, is what the substitution returns.

## Configure repos

The tracked-repo manifest is split into a committed template ([`repos.conf.example`](repos.conf.example)) and a per-operator live file (`repos.conf`, gitignored). On first `./install.sh` run the live file is bootstrapped from the template — edit it in place, then re-run `./install.sh`:

```sh
# Whole-org coverage: review every non-archived open PR in the org,
# including repos created later — no manifest edit per new repo. One
# batched search per org per tick (not a per-repo fan-out).
ORGS=(your-org)

# Per-repo allowlist: for partially-tracked orgs where you want only
# specific repos reviewed (leave such an org OUT of ORGS).
REPOS=(
    "other-org/just-this-repo"
)
```

The host auxiliary timers pick it up on their next tick. **The containerized review loop reads a separate manifest** — `docker/secrets/manifest/repos.conf` (the `manifest/` **directory** is mounted at `/shared/manifest`), polled every 30s — so edit *that* copy to change which repos the fleet reviews. The edit applies within one enumerate window (`ENUMERATE_SECS`, 60s) — no restart, no re-render. Not instantly: `queue.json` is refreshed on that floor and consumed every 30s, so specs enumerated just before the edit can still dispatch for up to a window afterward. It is a directory mount rather than a file mount deliberately: docker pins a file bind-mount to the source **inode**, and ordinary editors write a temp file and rename over the original, so a file mount would leave every container serving the pre-edit manifest while the host file looked correct — silently, with no error. Set `ORGS` there for whole-org coverage; reserve `REPOS` for specific repos in partially-tracked orgs. `SOURCE_PATHS` in the same file enables cross-repo grep/search-roots and `KID_PATHS` wires kid-prior-art lookup. Per-repo **reviewer policy** — the operating point and any repo-specific calibration — lives in each tracked repo's root `REVIEW.md`; the **universal review policy** (security fence, voice posture, decline rules, review-loop rules) lives in [`prompts/policy.md`](prompts/policy.md) and is prepended to every agent by `lib/pipeline.py:build_prompt`, so no repo carries it (roborev gets the same rules from claude-config's `_src_rubric`); per-repo **pipeline mechanics** — sibling allowlist, dead-code command, strict-typing command — stay in that repo's `.knightwatch/` directory. Both are read from the base branch via `lib/knightwatch-config.sh`, so PR-head edits don't take effect until merged. A repo with no `REVIEW.md` gets the org default from `default_review_md`. See the inline comments in [`repos.conf.example`](repos.conf.example) for shapes and `lib/tracked-repos.sh` for the loader.

### kid prior-art

A DRY pre-pass: before the specialists run, `lib/review-one-pr.sh` runs [`kid`](https://github.com/srosro/knightwatch-kid) (`keepitdry`) against a semantic index of your canonical code and surfaces existing code similar to each new block, so the reviewer can flag duplication. It's **opt-in** — a no-op unless a repo has a `KID_PATHS` entry.

Indices are built host-side (the `kid-refresh` timer indexes `KWR_CLONE_ROOT/<repo>` into `<repo>/.keepitdry`) and consumed **read-only** by the containers. To enable it: set `KID_ROOT` in `docker/secrets/config.env` to your kid **clone root** — the dir holding `knightwatch-kid/scripts/` and, by convention, the per-repo `.keepitdry` indices — then set `KID_PATHS`, `KID_OLLAMA_URL`, and `KID_EMBED_MODEL` in `docker/secrets/`, and re-run `just fleet` to render the `/kwr` bind mount into every unit. An index that lives *outside* the clone root needs its own mount: list its **host path** in `KID_EXTRA_MOUNTS` (space-separated, each rendered read-only on every unit) — e.g. `KID_EXTRA_MOUNTS=/home/odio/Hacking/plow-kid` with `["plow-pbc/plow"]="/home/odio/Hacking/plow-kid"`. Each extra index is deliberately mounted at the **same path inside the container as on the host**, so that one `KID_PATHS` value is valid in *both* manifests: the repo-root `repos.conf` (host timers — `plow-kid-refresh.sh` git-pulls + re-indexes each value as a checkout, `install.sh` grants it in the kid-refresh unit's `ReadWritePaths`) and `docker/secrets/manifest/repos.conf` (the containers' query path). A split host/container path would silently force those two same-named files to diverge on that key. Because ChromaDB's sqlite needs write access even for a query, the worker copies the read-only index into a per-container scratch dir before querying. Pin the mounted `knightwatch-kid` clone to the same commit as the image's `kid` binary to avoid script/binary skew.

## Use on a PR

Reviews fire on PR open and again after a period of idle (the `STABLE_SECS` stability window). To force a fresh review on the new head, post a slash command:

> **Command prefix:** all bot commands use the prefix from `BOT_CMD_PREFIX` (default: `srosro`). Set it in `~/.pr-reviewer/config.env` to fork-customize. Examples below use the default.

| Command | What |
|---|---|
| `/srosro-update-review` | Incremental re-review against the prior reviewed SHA |
| `/srosro-review` | Whole-PR re-review (full diff; keeps prior-review + decline memory) |
| `/srosro-approve` | Approve the PR (push-access collaborators only) |
| `/srosro-props [from: <specialist>]` | Give props to a specialist's contribution |
| `/srosro-critique [from: <specialist>]` | Flag a specialist's contribution as a misread |
| `/srosro-memorize` | Teach the bot a calibration lesson from your reply |

### Specialist bake-off

A small post-hoc measurement that helps decide which specialists are earning their place. `specialist-bakeoff.sh` runs twice nightly at 02:00 + 04:00 Pacific (off-hours) via systemd, walks the tracked repos in `repos.conf` for bot reviews + feedback comments in the per-repo window `[min(REWALK_HOURS_ago, walks.last_walked_at), last_walked_at + WINDOW_HOURS]` — `WINDOW_HOURS` (16 in production) caps how far forward each run advances the watermark so the two fires split the day's per-PR fetches into smaller off-hours bursts with spare daily capacity (2×16 > 24h) to burn down a missed fire, while the floor still refreshes `edited_after` on recent reviews — and persists one row per (review × specialist) into `~/.pr-reviewer/bakeoff.db`. A markdown snapshot is regenerated at `~/.pr-reviewer/specialist-bakeoff.md` with the following columns per specialist over a rolling 14-day window (configurable via `SCORECARD_DAYS`; the renderer reads accumulated DB state, decoupled from the walker's `REWALK_HOURS`):

- **Reviews** — total reviews where this specialist was invoked (the denominator). Comes from the write-time `<!-- knightwatch-bakeoff: specialists=... -->` marker on every posted review.
- **Shipped** — reviews where this specialist contributed at least one probe (per-review bool, not probe count).
- **Cited** — reviews where any of this specialist's probes cited a path that the PR touched (any commit on the branch). Near-tautological signal — by construction specialists cite paths in the diff they're reviewing. Useful as a sanity check (is the specialist looking at the right files?), not as a quality metric. `[open]` probes (no `Files:` clause) earn no Cited credit.
- **Edited** — reviews where any of this specialist's cited paths was touched by a commit landing AFTER the bot review. Stronger signal than Cited: the developer went back to that path after seeing the probe. Doesn't prove the *specific* suggestion was applied, only that the area got more attention.
- **Blocking / Medium / Low+Nit / Open** — reviews bucketed by the specialist's *max* probe severity in that review. Sums to ≤ Shipped (a review where the specialist raised no probes contributes to none). Helps tell apart specialists that ship load-bearing findings from those mostly raising open questions.
- **+LOC / −LOC** — sum of `additions` / `deletions` across the specialist's Cited (deduped) paths in the PR's diff.
- **Loved / Critiqued** *(persisted but not rendered)* — reviews where a trusted (push-access) collaborator posted `/srosro-props [from: <specialist>]` / `/srosro-critique [from: <specialist>]`. Still tracked per-(review × specialist) in `bakeoff.db` for inspection; omitted from the rendered snapshot because the qualitative signal is currently too sparse to drive collapse/keep decisions.

The store is append-only — historical reviews continue accumulating data; the rolling 14-day window is a renderer query parameter (`SCORECARD_DAYS`) rather than an API-cost ceiling. Tradeoff: edits or feedback landing >`REWALK_HOURS` after a review (on still-active PRs) won't flip `edited_after` / `loved_positive` / `critiqued` on a re-walk — that's the cost of the incremental window. Transient fetch failures preserve the prior snapshot rather than republishing with partial data.

> **First-run note:** the table will be empty for ~14 days after this ships, then populates as new reviews land. The roster marker only goes on new reviews; old reviews are skipped by the walker.

Use it to inform collapse-or-keep decisions on specialist agents.

## Repo layout

- `review.sh` / `lib/review-one-pr.sh` — per-PR review driver
- `prompts/` — specialist + critic + aggregator prompts
- `systemd/` — auxiliary host timer + service units (discovery, calibration, poll [merged approve + re-request], kid-refresh, bake-off)
- `repos.conf.example` — tracked-repo manifest template (live `repos.conf` is per-operator, gitignored)
