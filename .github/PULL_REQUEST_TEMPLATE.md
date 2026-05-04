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

Maintain your canary set at `.knightwatch/canaries.csv` — gitignored, kept off this public repo. Format is what `lib/replay-batch.sh` consumes:

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

```bash
# Stage baseline (main) and experiment (this PR) prompt directories
git switch main && git pull --ff-only
cp -r prompts /tmp/prompts-baseline
git switch -
cp -r prompts /tmp/prompts-experiment

# Cross-product replay: canaries × {baseline, experiment}
./lib/replay-batch.sh \
  --prs .knightwatch/canaries.csv \
  --prompts /tmp/prompts-baseline,/tmp/prompts-experiment \
  --output-dir "replays/perf-$(date +%Y-%m-%d)"

# Read the side-by-side index
cat "replays/perf-$(date +%Y-%m-%d)/index.md"
```

`lib/replay-batch.sh` runs cells sequentially. Wall time is roughly `(canaries × prompt sets) × 10 min` — for 3 canaries × 2 sets that's ~60 min. Each cell burns ~17 codex calls (1 intent + 1 dead-code + 8 specialists + 7 critics + 1 momentum + 1 aggregator). Logged-in `codex` CLI required.

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
