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
- **Wave B** (parallel): the nine **specialists** — `security`, `data-integrity`, `architecture`, `architecture-refined`, `contract-drift`, `consumers`, `shape`, `simplification`, `tests` — each looking at one angle of the diff against the rest of the repo. On re-reviews, the `momentum` standalone joins Wave B (it tracks LOC trajectory and prior-round drift). Each specialist emits structured **probes** (hypothesis + severity + class), and a per-angle `critic` then resolves each probe (`Answer: yes/no/unknown` + evidence).
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

    subgraph WB[Wave B — 9 specialists in parallel; each chains to a per-angle critic]
        direction LR
        sec[security] --> ksec[critic]
        di[data-integrity] --> kdi[critic]
        arch[architecture] --> karch[critic]
        archref["architecture-refined"] --> karchref[critic]
        simp[simplification] --> ksimp[critic]
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

`install.sh` symlinks scripts into `~/.pr-reviewer/`, copies the `systemd/*.{service,timer}` files into `/etc/systemd/system/`, daemon-reloads, and enables the timers. Idempotent — re-run after pulling changes.

Single-tenant by design: one Linux host with `gh` authenticated as the bot's signing user. The systemd units currently bake in `User=odio` and `/home/odio/.pr-reviewer/`; edit them for a different user or path.

## Configure repos

The tracked-repo manifest is split into a committed template ([`repos.conf.example`](repos.conf.example)) and a per-operator live file (`repos.conf`, gitignored). On first `./install.sh` run the live file is bootstrapped from the template — edit it in place, then re-run `./install.sh`:

```sh
REPOS=(
    "your-org/your-repo"
    ...
)
```

The next 2-minute timer tick picks it up. `SOURCE_PATHS` in the same file enables cross-repo grep/search-roots and `KID_PATHS` wires kid-prior-art lookup. Per-repo policy (product context, review priority, sibling allowlist, dead-code command, strict-typing command) lives in each tracked repo's `.knightwatch/` directory and is read from the base branch via `lib/knightwatch-config.sh`. See the inline comments in [`repos.conf.example`](repos.conf.example) for shapes and `lib/tracked-repos.sh` for the loader.

## Use on a PR

Reviews fire on PR open and again after one hour of idle. To force a fresh review on the new head, post a slash command:

> **Command prefix:** all bot commands use the prefix from `BOT_CMD_PREFIX` (default: `srosro`). Set it in `~/.pr-reviewer/config.env` to fork-customize. Examples below use the default.

| Command | What |
|---|---|
| `/srosro-update-review` | Incremental re-review against the prior reviewed SHA |
| `/srosro-review` | Whole-PR re-review from scratch |
| `/srosro-approve` | Approve the PR (push-access collaborators only) |
| `/srosro-props [from: <specialist>]` | Give props to a specialist's contribution |
| `/srosro-critique [from: <specialist>]` | Flag a specialist's contribution as a misread |
| `/srosro-memorize` | Teach the bot a calibration lesson from your reply |

### Specialist bake-off

A small post-hoc measurement that helps decide which specialists are earning their place. `specialist-bakeoff.sh` runs daily at 03:30 UTC via systemd, walks the tracked repos in `repos.conf` for bot reviews + feedback comments since the per-repo `min(REWALK_HOURS_ago, walks.last_walked_at)` floor — covers new comments since the last cron and refreshes `edited_after` on recent reviews — and persists one row per (review × specialist) into `~/.pr-reviewer/bakeoff.db`. A markdown snapshot is regenerated at `~/.pr-reviewer/specialist-bakeoff.md` with the following columns per specialist over a rolling 14-day window (configurable via `SCORECARD_DAYS`; the renderer reads accumulated DB state, decoupled from the walker's `REWALK_HOURS`):

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
- `systemd/` — polling timer + service units
- `repos.conf.example` — tracked-repo manifest template (live `repos.conf` is per-operator, gitignored)
