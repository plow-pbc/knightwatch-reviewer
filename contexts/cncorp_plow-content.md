# plow-content — Product Context

**Stage:** Bootstrap — single producer (`@srosro`) wiring the tutorial-production pipeline. Favor clean designs over hardening edge cases; the user surface is "the human running this on wakeup," not the public.

**What it is:** A tutorial-production pipeline for `plow.co`. Takes a screen-recording (or YouTube URL) of someone using Plow/OpenClaw, runs Parakeet ASR with hot-word boosting from a `vocabulary.json` scanned from the live `plow2` repo, applies hand-curated `corrections.json`, calls Sonnet to structure the transcript into a tutorial schema, and emits a publish PR against `plow2/tutorials/<slug>.json` plus a chaptered `<slug>.youtube.txt` for the YouTube description.

**Authoritative guidance lives in `docs/runbook.md` — read it first.** It is the single source of truth for the operator flow (record → scp → build → emit-pr), the schema, and the publish path. The runbook also documents intentional draft-state quirks (e.g., the `youtube_id == "PLACEHOLDER"` placeholder during the build step before the actual upload) — these are known and were called out in the first review pass; flag if a change broadens the surface area where PLACEHOLDER can leak into a real publish.

**Architectural commitments worth flagging when a PR breaks them:**
- `tutorials/<slug>.json` writes through `emit-pr` — never directly committed by build. The `plow2` repo is the publish surface; `plow-content` is the producer. PRs that try to publish from inside the producer (skipping the PR step) cross the producer/publisher boundary.
- `vocabulary.json` is regenerated from `plow2` (`scan-vocabulary --plow2 ~/Hacking/plow2`). Hand-edits drift; flag if a PR adds product names directly to `vocabulary.json` instead of routing through the scan or `corrections.json`.
- The single shared Anthropic client surface should consolidate (the bot's first review flagged `pre_boost.py` / `structure.py` / `citation_tracker.py` each rolling their own client setup as a DRY/Name-the-Shape concern). Future changes that add a fourth parallel call site without going through a shared seam are a recurrence.
- Parakeet decoding-strategy API drift is a fail-fast concern, not a degrade-gracefully concern. The pipeline's value is "accurate hot-word boosting"; silent loss of boosting still produces publishable JSON, which is the worst failure mode.

**Review posture:**
- For producer-tool robustness findings (idempotence, retry-safety, draft/publish state shape), the standard is operator ergonomics, not service hardening. The single producer can re-run a build; the cost of a non-idempotent path is operator confusion, not user-facing breakage.
- The `plow2` schema is the contract — `plow_content/tests/test_entry.py` runs a live cross-repo schema check. Treat schema-drift findings as blocking.
- For roadmap-flavored findings, link to `docs/runbook.md` rather than asserting product-stage assumptions from memory; the runbook drifts faster than this file is updated.
