# vibe-engineering — Product Context

**Stage:** Personal engineering-config repo for one engineer (srosro). Holds the canonical copies of `~/.claude/*.md` (coding standards, review practices, testing rules, the auto-tuned `COMMENT_REVIEW_MISTAKES.md`), symlinked into `~/.claude/`. Skills also live under `claude-config/skills/` but aren't part of the symlink model. Not a product.

**Distribution model:** Public on GitHub but personal/internal usage. Other engineers may reference it; nobody depends on it as a versioned dependency.

**Architectural commitments:**
- `claude-config/` is the canonical source of truth; `~/.claude/` symlinks point in. PRs that move or rename files in `claude-config/` break those symlinks on every host using this layout — outsized blast radius for what looks like a simple file move.
- `claude-config/COMMENT_REVIEW_MISTAKES.md` is **auto-tuned hourly** by `learn-from-replies.sh` (in knightwatch-reviewer), which commits + pushes a fresh top-48 ranked list. Hand-edits to that one file race the auto-tune loop and will likely be overwritten on the next tick. The other `.md` files (`CLAUDE.md`, `CODING_STANDARDS.md`, `REVIEW_PRACTICES.md`, `TESTING.md`) are hand-curated and the auto-tuner explicitly does not touch them.
- Skills under `claude-config/skills/` are prompt-engineering artifacts — review them as prompts, not as code.
- No build, no tests, no CI. Files are just read by the Claude Code harness on whatever machine has the symlinks.

**Known near-term migrations / roadmap items:**
- None tracked. Changes happen organically when a calibration is needed.

**Review posture for PRs against this repo:**
- Cascade risk is the dominant axis: a change to `CODING_STANDARDS.md` or `REVIEW_PRACTICES.md` affects every PR reviewed across every tracked repo. Weight tradeoffs accordingly — favor precise, falsifiable rules over vague guidance.
- For `COMMENT_REVIEW_MISTAKES.md` hand-edits: flag that the auto-tuner will likely overwrite the change on its next tick unless the entry survives re-ranking. Suggest landing the underlying lesson in `REVIEW_PRACTICES.md` or `CODING_STANDARDS.md` instead, where it's stable.
- For new or modified skills: ask whether the change adds guardrails (constraints, refusal conditions, must/must-not rules) or only adds instructions. Pure-instruction skills tend to drift; guardrail skills hold up.
- Editorial findings on prose `.md` files are fair game — internal contradictions, redundancy with another file, ambiguity that would let a reviewer wriggle out of the rule.
- Architecture findings should respect the "files + symlinks, no tooling" commitment — don't push toward a packaging/install-script rewrite unless the PR proposes it.

**Update cadence:** Edit this file when the repo's scope changes (new categories of config land, the auto-tune loop changes which files it touches, the install/symlink model changes). Otherwise it's static.
