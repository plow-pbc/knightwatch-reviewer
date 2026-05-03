# prompts.new-design — sparse overlay on `prompts/`

This directory is a **sparse overlay** of `prompts/` containing only the files
that the Bug 1+2 patch touches. Missing files mean "identical to `prompts/`".

To run a replay against this overlay, materialize the full prompt set first
(merge sparse overlay onto `prompts/`):

```bash
mkdir -p /tmp/prompts-merged
cp prompts/*.md /tmp/prompts-merged/
cp prompts.new-design/*.md /tmp/prompts-merged/   # overrides only the 2 patched files
lib/replay.sh --repo OWNER/REPO --pr N --sha SHA \
    --prompts /tmp/prompts-merged --output-dir replays/<slug>
```

## Files in this overlay

- `common-header.md` — adds **§ Q-field shape** (state-shaped Qs only) and **§ Broken-Glass is pro-simplification** (anti-inversion). Bug 1 fix + Bug 2 fix.
- `critic.md` — tightens **REFRAME-AS-QUESTION** to require 3 conditions; excludes removal findings (DRY, dead code, unreachable branch). Bug 2 fix follow-through.

## What it tests

See `docs/comparison-2026-05-02.md` for the empirical comparison this overlay was built to validate. Headline: NEW recovers 5/8 of OLD's findings vs CURRENT's 3/8 across `cncorp/plow#563/#565/#569` R1.
