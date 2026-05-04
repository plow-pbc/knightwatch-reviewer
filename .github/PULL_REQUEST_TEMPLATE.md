<!--
PR template for knightwatch-reviewer.

Most prompt or pipeline changes affect codex output in ways that are NOT visible
from the diff alone. The performance analysis below is how we keep regressions
from shipping silently. Skip the section if it's genuinely N/A — but don't
delete it without writing the one-line N/A explanation.
-->

## Summary

<!-- One or two sentences: what changed, why. Link any prior PR or commit that this builds on. -->

## Smoke

- [ ] `PATH=/opt/homebrew/bin:$PATH bash lib/tests/prompt-contracts-smoke.sh` reports `PASS` at HEAD

## Performance — before / after

**REQUIRED** when this PR touches any of:
- `prompts/` (any specialist, critic, aggregator, common-header, probe-schema, intent, dead-code-search, momentum)
- `lib/pipeline.py`, `lib/review-one-pr.sh`, `lib/replay.sh`, `lib/scratch.sh`, `lib/state-io.sh`

**N/A** for: docs / README / CI / smoke-test-only / packaging changes that demonstrably can't change codex output.
If N/A, fill in the **N/A explanation** at the bottom and skip the rest of this section.

### Canary PRs

These are the three baseline canaries — R1 SHAs from `fb4c508`'s ground-truth measurement. They cover three different angles of the reviewer pipeline:

| PR | R1 SHA | What it exercises |
|---|---|---|
| `cncorp/plow#563` | `48419b4b1a2ce3a375b84570c38e8da9729b9611` | SwiftUI feature + `KeepMacAwake` test-gap detection |
| `cncorp/plow#565` | `852beef00a4ca8ec6d95e131b4ff10720614c0ea` | AppKit/SwiftUI installer sizing + call-graph consistency bug (`NSScreen.main` vs `window.screen`) |
| `cncorp/plow#569` | `dcb80a5a3dc1752799cd7498c06fdaf907adff0d` | Shell scripts + DMG packaging + path-resolution bug (`--dmg` recipe) |

**These three are the floor**, not the ceiling. If your change targets a specific pipeline angle (e.g., a new specialist, perf-class probe behavior, security carve-out), supplement with a representative PR in that angle. Drop a canary only if you can name a specific reason it doesn't exercise the change.

### Run replays — both sides

Run against `main` first (`before`), then against this PR's HEAD (`after`). Replays inside each side run in parallel; total wall time ~10 minutes per side, ~20 minutes total. Each replay burns ~17 codex calls (1 intent + 1 dead-code + 8 specialists + 7 critics + 1 momentum + 1 aggregator). Logged-in `codex` CLI required.

```bash
# From repo root, on this PR's branch.
THIS_BRANCH=$(git branch --show-current)
OUT_BASE="replays/perf-$(date +%Y-%m-%d)-${THIS_BRANCH//\//-}"

run_canaries () {
  local cond=$1
  mkdir -p "$OUT_BASE/$cond"
  for entry in \
    "569 dcb80a5a3dc1752799cd7498c06fdaf907adff0d" \
    "563 48419b4b1a2ce3a375b84570c38e8da9729b9611" \
    "565 852beef00a4ca8ec6d95e131b4ff10720614c0ea"; do
    local pr=${entry% *}
    local sha=${entry#* }
    nohup ./lib/replay.sh --repo cncorp/plow --pr "$pr" --sha "$sha" \
      --prompts "$(pwd)/prompts" \
      --output-dir "$OUT_BASE/$cond/cncorp-plow-$pr" \
      > "/tmp/replay-$cond-$pr.out" 2>&1 &
  done
  wait
}

# 1) before — main
git switch main && git pull --ff-only
run_canaries before

# 2) after — this PR's HEAD
git switch "$THIS_BRANCH"
run_canaries after

# 3) Read aggregator outputs side-by-side
for cond in before after; do
  echo "###### $cond ######"
  for pr in 569 563 565; do
    f="$OUT_BASE/$cond/cncorp-plow-$pr/aggregator-output.md"
    echo "=== #$pr ==="
    grep '^VERDICT:' "$f"
    grep -E '^[0-9]+\. \[' "$f"
    echo ""
  done
done
```

### Score table — fill in

| PR | Verdict (before → after) | # findings (before → after) | Severity / focus changes |
|---|---|---|---|
| `cncorp/plow#563` | / | / |  |
| `cncorp/plow#565` | / | / |  |
| `cncorp/plow#569` | / | / |  |

### Notable deltas

<!-- 1-2 sentences per material change. Examples:
- "#565: dual-screen-source bug recovered at [medium] (was missed)"
- "#569: --dmg path bug downgraded from [medium] to [low]"
Don't list every probe — just the load-bearing changes. -->

## Risk + rollback

<!-- What's the failure mode if this regresses in production? How to revert (git revert SHA, or specific revert PR plan)? -->

## N/A explanation

<!-- Delete this section if you filled in the performance analysis above. Otherwise, one line explaining why perf analysis doesn't apply (e.g., "docs-only change in README; no codex pipeline impact"). -->
