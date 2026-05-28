# knightwatch-reviewer — Product Context

**Stage:** The reviewer reviewing itself. Single-operator tool used by one engineer (srosro). The review loop is moving to a containerized multi-account deployment (docker-compose: per-account `reviewer`+`dind` units, a shared `claims` volume for PR-claim/`runs/` state, per-container `LOCAL_STATE_DIR` locks) as the **primary** path; the systemd-timer-on-one-host path is the **legacy fallback**. Auxiliary timers (learn, org-sync, approve, re-request, kid-refresh) still run on the host. Not a product, not a distribution target.

**Distribution model:** Personal / internal. No external users, no Marketplace ambitions.

**Architectural commitments:**
- Shell-first. Scripts + prompts + systemd units. No application server. State is JSON files plus one SQLite database (`bakeoff.db`) — see "Persistent stores" below for the carve-out.
- Each running timer is a `Type=oneshot` with a lightweight sandbox (`ProtectHome=read-only` + explicit `ReadWritePaths`). When adding a capability that touches a new path, widen `ReadWritePaths` in the corresponding unit file — don't relax the outer sandbox.
- Codex runs with `--dangerously-bypass-approvals-and-sandbox` (Ubuntu 24.04 AppArmor breaks bwrap for unprivileged user namespaces). Outer sandbox is systemd; that substitution is load-bearing and should not be reverted casually.
- State lives in `~/.pr-reviewer/` (legacy/systemd path). Code lives in this repo. `~/.pr-reviewer/{review.sh, lib, prompts, docs}` are symlinks to the repo. In the containerized path, `STATE_DIR` is the shared `claims` volume (`/shared`) and `LOCAL_STATE_DIR` (`/local`) holds the per-container just-test/canonical locks; the image carries the code, so prompts/lib resolve in-image.
- Auto-tuning from PR-reply feedback runs hourly. It only edits `~/.claude/COMMENT_REVIEW_MISTAKES.md` — a ranked top-48 list of calibrations. It does NOT touch hand-curated files (`CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`).
- Bot command prefix is operator-configurable via `BOT_CMD_PREFIX` (default `srosro`). All command parsers (props/critique/approve/memorize/review/update-review) match `/${BOT_CMD_PREFIX}-<verb>`.

**Persistent stores:**
- `~/.pr-reviewer/state.json` — legacy "what did we last review?" cache (no longer read or written by production paths; preserved for transition).
- `~/.pr-reviewer/bakeoff.db` — SQLite store for the specialist bake-off (per-(review × specialist) rows, daily incremental walker since `min(REWALK_HOURS_ago, walks.last_walked_at)`, write-time roster marker on every posted review). The carve-out is justified by needing time-series queries for cull/promote decisions on specialists; flat JSON would have required re-implementing GROUP BY + window cutoffs in awk on every walk. This is the ONLY SQLite seam — new state needs should default to JSON files + flock unless they have the same time-series-query shape.

**Known near-term migrations / roadmap items:**
- Containerized multi-account review loop (in flight): distributes reviews across N OpenAI/Codex accounts so one account's weekly cap can't stall the queue, and confines PR code + codex agents to a container. The auxiliary host timers are not yet containerized; reconciling their `~/.pr-reviewer` state with the container `claims` volume is a follow-up.

**Review posture for PRs against this repo:**
- Bash and shell-pattern findings are fair game (quoting bugs, lock-file races, jq pitfalls).
- Architecture findings should respect the "shell-first, one-database (bakeoff.db only)" commitment — don't push toward a FastAPI or Node rewrite unless the PR itself proposes it.
- Prompt-engineering changes are hard to test deterministically; acceptance criteria is usually "does the diff make the critic/aggregator's job easier?" Ask whether the prompt adds guardrails or only adds instructions.
- Every new systemd ReadWritePaths widening is a small lockbox change — worth flagging so the user consciously re-authorizes.
- Safety-critical: anything touching `gh pr comment`, `gh pr review`, or the auto-commit/push loops in `learn-from-replies.sh` can spam real PRs. A PR that changes those paths without a dry-run story is worth flagging.

**Update cadence:** Edit this file when the tool's scope changes (new tracked repo, new feedback loop, new deployment story). Otherwise it's static.
