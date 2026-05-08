# PR #584 fixtures (frozen historical data)

Captured from `~/.pr-reviewer/runs/cncorp_plow__584__20260507T004627849Z__3dfd523/inputs/` on 2026-05-08, immediately before the elegant-convergence refactor landed.

These files preserve the **failure-case inputs** that drove the convergence-failure analysis:

- `pr584-prior-reviews-r13.md` — concatenated prior-round aggregator outputs from rounds 1–12. Contains 3+ `Bug-Class-Recurrence` probes, all `Trajectory: STABLE` annotations, and the [blocking]-set series that goes 4→4→4→5→5→5→5→5→5→6→6→5 (never strictly shrinking once it reached 5).
- `pr584-loc-trend-r13.md` — round-by-round LoC table. Carries the legacy `Trajectory: STABLE` line that the post-refactor `lib/loc-trend.sh` no longer emits.

## Status: documentation, not an executed test

These fixtures are **not** read by any smoke or unit test. They exist to:

1. Let a future contributor inspect the exact failure case the elegant-convergence refactor was designed to fix (without reproducing it from a live PR).
2. Serve as a known-stale snapshot — the `Trajectory:` tag and the `Bug-Class-Recurrence` probes here are intentional historical artifacts, not regressions.

The deterministic guard against re-introducing the deleted patterns is `lib/tests/aggregator-convergence-smoke.sh`, which asserts the prompt sources and `lib/loc-trend.sh` no longer carry those constructs.

If you find yourself wanting to feed these fixtures into a live aggregator run, see Task 9's note in `lib/replay.sh`: the replay tool currently stubs `prior-reviews.md` and would need an `--inputs-from <run-dir>/inputs/` flag to consume historical staged inputs. That extension is out of scope for the elegant-convergence branch.
