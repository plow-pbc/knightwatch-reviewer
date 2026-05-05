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

## Why no fixtures shipped here

Even this repo's own historical PRs change shape over time (the bot's
prompts evolve; its expected behavior on a 6-month-old PR may not match
today's contract). Adding sample fixtures here would invite drift between
the fixture and the current bot. Operators select their own canary set
based on what regression budget they're defending.

The fixture format itself is exercised by `lib/tests/replay-verify-smoke.sh`
against synthetic aggregator-output content — no real-PR fixture required.
