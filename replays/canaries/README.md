# Canary fixtures

Fixture files for `lib/replay-verify.sh`. Format: see
`lib/tests/fixtures/replay-verify/sample-fixture.md`.

## Where they live

- **Public fixtures** (e.g. canary against this repo's own historical PRs)
  may live here under `replays/canaries/`. They reference public PRs only.
- **Private / mixed fixtures** (anything pointing at a private repo, customer
  PR, or non-public SHA) MUST live at `~/.pr-reviewer/canary-fixtures/`,
  outside any repo checkout. Same boundary `PULL_REQUEST_TEMPLATE.md`
  establishes for `~/.pr-reviewer/canaries.csv`.

The `lib/replay-verify.sh --fixture <path>` argument accepts either location.
The replay-batch.sh / replay-verify workflow does not enumerate fixtures
itself; the operator passes `--fixture` per invocation.

## Fixture format

A canary fixture is a markdown file with this shape:

````markdown
---
repo: owner/name
pr: 123
sha: <40-char-hex-sha>
exercise: <free-text label, what the canary defends>
canary_class: <positive|negative|neutral>
---

## Why this PR is in the canary set

(prose — humans read this; verifier ignores it)

## expected_verdict

COMMENT

## expected_contains

- simplification
- NSScreen.main
- "blocking"

## expected_absent

- credential
- exfiltration
````

Field semantics:
- `expected_verdict`: literal match against the `VERDICT:` line value (`APPROVE` / `COMMENT` / `BLOCK`).
- `expected_contains`: each substring (case-insensitive) MUST appear somewhere in the rendered aggregator-output. Use one entry per concern; the verifier doesn't enforce joint shape ("appears in the SAME probe line").
- `expected_absent`: each substring (case-insensitive) MUST NOT appear. False-positive guards.

The previous `expected_findings`/`expected_NOT` DSL with `keywords_all`/`keywords_any`/`severity_min`/`class_any` was deprecated in PR #56 — it grew parser foot-guns faster than the operator-bench use case justified. If line-level matching with severity/class gating ever becomes a real need, it can be re-introduced.

## Where replay artifacts land

By default, `lib/replay-verify.sh` writes replay artifacts (`aggregator-output.md`,
`diff.patch`, per-agent logs) to `~/.pr-reviewer/replays/<repo>-<pr>-<sha7>-<slug>/`,
mirroring the existing `~/.pr-reviewer/` operator-local convention. This keeps
artifacts from private-fixture replays out of the repo working tree.

To pin artifacts inside the repo (e.g. capturing a public canary's last-known-good
output for review), pass `--output-dir replays/<your-path>` explicitly.

## Why no fixtures shipped here

Even this repo's own historical PRs change shape over time (the bot's
prompts evolve; its expected behavior on a 6-month-old PR may not match
today's contract). Adding sample fixtures here would invite drift between
the fixture and the current bot. Operators select their own canary set
based on what regression budget they're defending.

The fixture format itself is exercised by `lib/tests/replay-verify-smoke.sh`
against synthetic aggregator-output content — no real-PR fixture required.
