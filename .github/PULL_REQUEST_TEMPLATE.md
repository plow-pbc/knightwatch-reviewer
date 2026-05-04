<!--
PR template for knightwatch-reviewer.

Most prompt or pipeline changes affect codex output in ways that are NOT visible
from the diff alone. The performance analysis below is how we keep regressions
from shipping silently. Skip the section if it's genuinely N/A — but don't
delete it without writing the one-line N/A explanation.

This is a public repo. Don't paste private replay artifacts (full
aggregator-output.md, private PR numbers, internal SHAs) into the PR
description — summarize deltas in the score table instead.
-->

## Summary

<!-- One or two sentences: what changed, why. Link any prior PR or commit that this builds on. -->

## Smoke

- [ ] `PATH=/opt/homebrew/bin:$PATH bash lib/tests/prompt-contracts-smoke.sh` reports `PASS` at HEAD

## Performance — before / after

**REQUIRED** for any change under `prompts/` or `lib/` (except `lib/tests/` smoke-only changes — those are gated by the smoke check above). The `lib/` rule is broad on purpose: scratch staging (`scratch.sh`, `diff-build.sh`, `state-io.sh`), pipeline orchestration (`pipeline.py`, `review-one-pr.sh`, `replay*.sh`), and config helpers (`knightwatch-config.sh`, `search-roots.sh`, `sibling-symlinks.sh`, `decline-history.sh`, `loc-trend.sh`) all change codex inputs, so all of them count.

**N/A** for: docs / README / CI / smoke-only / packaging / `.github/` — anything that demonstrably can't change codex output. If N/A, fill in the **N/A explanation** at the bottom and skip the rest of this section.

### Canary list (operator-local)

Maintain your canary set at `~/.pr-reviewer/canaries.csv` — operator state, outside any repo checkout (the in-repo `.knightwatch/` directory is base-branch policy per `README.md:55`, not the place for operator-private state). Format is what `lib/replay-batch.sh` consumes:

```
# repo,pr,sha   (one per non-blank, non-comment line)
owner/private-repo,123,abc1234567890abcdef1234567890abcdef12345
```

Pick PRs whose R1 (first reviewed) SHA had findings the OLD bot caught well — those are the regression targets to defend. **Cover at least three angles** of the reviewer pipeline so a regression in any one specialist surfaces:

| Angle | What it exercises | Looks like |
|---|---|---|
| Test-coverage gap | `tests` specialist | A PR where the bot caught a missing-test or fail-loud-vs-skip finding |
| Call-graph consistency / packaging | `shape`, `consumers`, `data-integrity` | A PR with a "two paths read different sources" or "stale caller" or path-resolution bug |
| `simplification` removal logic | `simplification` (DRY / dead-code / complexity-cost merged) | A PR where the bot correctly recommended deletion or DRY collapse |

3 canaries minimum; more is fine if budget allows. Don't paste the canary list into this public PR.

### Run replays — both sides

The template's required-when scope covers `prompts/` AND `lib/`, so both sides must run from their own checkout (each side's `replay.sh` / `pipeline.py` / scratch helpers can differ). Two sequential batch invocations:

```bash
OUT="replays/perf-$(date +%Y-%m-%d)"

# Side 1: baseline (main) — main's lib/ + main's prompts/
git switch main && git pull --ff-only
./lib/replay-batch.sh \
  --prs ~/.pr-reviewer/canaries.csv \
  --prompts "$(pwd)/prompts" \
  --output-dir "$OUT/baseline"

# Side 2: experiment (this PR) — PR's lib/ + PR's prompts/
git switch -
./lib/replay-batch.sh \
  --prs ~/.pr-reviewer/canaries.csv \
  --prompts "$(pwd)/prompts" \
  --output-dir "$OUT/experiment"

# Compare side-by-side — read both index files
echo "=== baseline ==="; cat "$OUT/baseline/index.md"
echo "=== experiment ==="; cat "$OUT/experiment/index.md"
```

`lib/replay-batch.sh` runs cells sequentially. Wall time is roughly `canaries × 10 min × 2 sides` — for 3 canaries that's ~60 min total. Each cell burns ~17 codex calls (1 intent + 1 dead-code + 8 specialists + 7 critics + 1 momentum + 1 aggregator). Logged-in `codex` CLI required.

### Score table — fill in (summarize, don't paste full output)

| Canary | Verdict (baseline → experiment) | # findings (baseline → experiment) | Severity / focus changes |
|---|---|---|---|
| canary 1 |  /  |  /  |  |
| canary 2 |  /  |  /  |  |
| canary 3 |  /  |  /  |  |

### Notable deltas

<!-- 1-2 sentences per material change. Examples (sanitized):
- "canary-1: missing-test finding recovered at [blocking] (was missed)"
- "canary-2: severity downgraded on path-resolution finding ([medium] → [low])"
Don't list every probe. Don't paste full aggregator-output.md into a public PR — summarize. -->

## Risk + rollback

<!-- What's the failure mode if this regresses in production? How to revert (git revert SHA, or specific revert PR plan)? -->

## N/A explanation

<!-- Delete this section if you filled in the performance analysis above. Otherwise, one line explaining why perf analysis doesn't apply (e.g., "docs-only change in README; no codex pipeline impact"). -->
