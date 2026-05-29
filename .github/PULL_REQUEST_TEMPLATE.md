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

**REQUIRED** for any change under `prompts/` or `lib/` (except `lib/tests/` smoke-only changes — those are gated by the smoke check above). Broad on purpose: anything else under `lib/` can change codex inputs, so all of it counts.

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
| `simplification` removal logic | `architecture-refined` (DRY / dead-code / complexity-cost / over-engineering merged) | A PR where the bot correctly recommended deletion or DRY collapse |

3 canaries minimum; more is fine if budget allows. Don't paste the canary list into this public PR.

### Run replays — both sides

The template's required-when scope covers `prompts/` AND `lib/`, so both sides must run from their own checkout (each side's `replay.sh` / `pipeline.py` / scratch helpers can differ). Two sequential batch invocations:

```bash
set -euo pipefail
OUT="$HOME/.pr-reviewer/replays/perf-$(date +%Y-%m-%d)"

# Side 1: baseline (main) — main's lib/ + main's prompts/
git switch main
git pull --ff-only
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

Output goes under `~/.pr-reviewer/replays/` so private canary identifiers + replay artifacts never land as commit-ready files in the public worktree. `set -euo pipefail` aborts on any failure (e.g. `git switch main` in a dirty tree) so a bad checkout can't silently produce a false no-delta comparison.

`lib/replay-batch.sh` runs cells sequentially. Wall time is roughly `canaries × 10 min × 2 sides` — for 3 canaries that's ~60 min total. Each cell burns `2 + 2×|SPECIALISTS| + 2` codex calls (intent + dead-code, then one specialist + one critic per `lib/pipeline.py::SPECIALISTS` entry, plus momentum + aggregator) — ~18 today. Logged-in `codex` CLI required.

### Verify with fixtures (optional, recommended for repeated regressions)

If you maintain canary fixtures at `~/.pr-reviewer/canary-fixtures/` (format: `replays/canaries/README.md` § Fixture format), `lib/replay-verify.sh` lets you assert specific behaviors instead of eyeballing each `aggregator-output.md`:

```bash
# Per-fixture diff between baseline and experiment cells. --no-replay
# reads what lib/replay-batch.sh already wrote — no second codex burn.
# Run against BOTH sides so a fixture that fails on baseline (stale or
# canary drifted) is labeled distinctly from a true PR regression.
. lib/replay-paths.sh
for f in ~/.pr-reviewer/canary-fixtures/*.md; do
  fm=$(awk '/^---$/{c++; if (c==2) exit; next} c==1' "$f")
  repo=$(awk '/^repo:/ {print $2}' <<<"$fm")
  pr=$(awk   '/^pr:/   {print $2}' <<<"$fm")
  sha=$(awk  '/^sha:/  {print $2}' <<<"$fm")
  slug=$(replay_prompt_slug "$(pwd)/prompts")
  cell="$(replay_run_dir "$repo" "$pr" "$sha" "$slug")"
  # Errexit-safe status capture: under `set -euo pipefail` from the prior block,
  # `cmd; base=$?` would exit the shell on the first non-zero before $? is read.
  if ./lib/replay-verify.sh --fixture "$f" --no-replay "$OUT/baseline/$cell/aggregator-output.md"   >/dev/null 2>&1; then base=0; else base=$?; fi
  if ./lib/replay-verify.sh --fixture "$f" --no-replay "$OUT/experiment/$cell/aggregator-output.md" >/dev/null 2>&1; then expt=0; else expt=$?; fi
  case "$base $expt" in
    "0 0") ;;  # both pass — silent (normal)
    "0 1") echo "REGRESSION: $(basename "$f") — passed baseline, failed experiment" ;;
    "1 0") echo "RECOVERY:   $(basename "$f") — failed baseline, passed experiment" ;;
    "1 1") echo "STALE:      $(basename "$f") — failed both sides (fixture or canary needs update)" ;;
    *)     echo "ERROR:      $(basename "$f") — verifier exit base=$base expt=$expt (parse error / missing cell / unknown — inspect manually)" ;;
  esac
done
```

Only the **REGRESSION** lines belong in **Notable deltas** below — STALE fixtures are operator-side cleanup (the canary diverged from the fixture's expectations independent of this PR), and RECOVERY lines are worth mentioning as positive deltas. Fixtures encode `expected_verdict` + `expected_contains` + `expected_absent` so a regression surfaces as a clean FAIL line instead of a subtle aggregator-output diff.

**Sanitize before pasting**: fixture basenames can carry private repo / PR / SHA identifiers (e.g. `cncorp-plow-565-dual-screen.md`). The local console output is for the operator's eyes; in **Notable deltas**, summarize the *behavior* that regressed (e.g. "data-integrity finding lost on the dual-screen-source canary"), not the raw fixture filename.

Reviewers asking for "one more substring fence" in a smoke test are usually asking for a fixture instead — encode the behavior as an `expected_contains` / `expected_absent` entry, not as prompt prose pinning. See `replays/canaries/README.md` for the format spec.

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
