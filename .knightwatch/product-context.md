# knightwatch-reviewer — Product Context

**Stage:** The reviewer reviewing itself. Single-operator tool used by one engineer (srosro); runs as systemd timers on one host. Not a product, not a distribution target.

**Distribution model:** Personal / internal. No external users, no Marketplace ambitions.

**Architectural commitments:**
- Shell-first. Scripts + prompts + systemd units. No application server, no database beyond `state.json`.
- Each running timer is a `Type=oneshot` with a lightweight sandbox (`ProtectHome=read-only` + explicit `ReadWritePaths`). When adding a capability that touches a new path, widen `ReadWritePaths` in the corresponding unit file — don't relax the outer sandbox.
- Codex runs with `--dangerously-bypass-approvals-and-sandbox` (Ubuntu 24.04 AppArmor breaks bwrap for unprivileged user namespaces). Outer sandbox is systemd; that substitution is load-bearing and should not be reverted casually.
- State lives in `~/.pr-reviewer/`. Code lives in this repo. `~/.pr-reviewer/{review.sh, lib, prompts, docs}` are symlinks to the repo.
- Auto-tuning from PR-reply feedback runs hourly. It only edits `~/.claude/COMMENT_REVIEW_MISTAKES.md` — a ranked top-48 list of calibrations. It does NOT touch hand-curated files (`CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`).

**Known near-term migrations / roadmap items:**
- None tracked here. This tool is intentionally done-ish; changes happen organically when a specific pain point surfaces.

**Review posture for PRs against this repo:**
- Bash and shell-pattern findings are fair game (quoting bugs, lock-file races, jq pitfalls).
- Architecture findings should respect the "shell-first, no database" commitment — don't push toward a FastAPI or Node rewrite unless the PR itself proposes it.
- Prompt-engineering changes are hard to test deterministically; acceptance criteria is usually "does the diff make the critic/aggregator's job easier?" Ask whether the prompt adds guardrails or only adds instructions.
- Every new systemd ReadWritePaths widening is a small lockbox change — worth flagging so the user consciously re-authorizes.
- Safety-critical: anything touching `gh pr comment`, `gh pr review`, or the auto-commit/push loops in `learn-from-replies.sh` can spam real PRs. A PR that changes those paths without a dry-run story is worth flagging.

**Update cadence:** Edit this file when the tool's scope changes (new tracked repo, new feedback loop, new deployment story). Otherwise it's static.
