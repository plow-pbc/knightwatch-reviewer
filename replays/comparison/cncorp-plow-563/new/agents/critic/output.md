## Critic counterarguments

### [architecture] Finding 1 — AGREE
Will status-popover users rely on that row as the primary control? If yes, the diff really does put the explanatory sleep-limit copy only in `SettingsView.swift:191`, while `StatusView.swift:431-441` carries a label-only toggle. Low severity is calibrated; this is copy parity, not a blocker.
**Estimated remedy LOC:** ~3 LOC across 1 file.

### [simplification] Finding 1 — AGREE
Will installer settings content vary enough across supported displays before PMF to justify this sizing machinery? If not, `InstallerView.swift:14-15`, `114-124`, and `531-570` add measurement state, preference keys, observation hooks, and a `28` titlebar constant for one added row; that adds complexity and makes PMF iteration harder.
**Estimated remedy LOC:** ~0 added LOC; deletes ~50 LOC across 2 files.

### [simplification] Finding 2 — AGREE
Will `keepMacAwakeRow` need divider variants before PMF? Current evidence says no: the only call passes `false` at `SettingsView.swift:176`, so the defaulted parameter at `SettingsView.swift:182` is unused option surface. Nit severity is calibrated.
**Estimated remedy LOC:** ~0 added LOC; deletes ~2 LOC across 1 file.

### [tests] Finding 1 — FALSE POSITIVE
The cited file/lines do not exist in the current tree or `.codex-scratch/diff.patch`: there is no `app/PhoenixTests/KeepMacAwakeTests.swift`, and `KeepMacAwake.swift` has no `AssertionCreator` or `AssertionReleaser` seam. The underlying test gap is real, but this exact finding’s factual path is wrong.

### [shape] Finding 1 — AGREE
Will this toggle need separate “user requested ON” state versus “macOS granted assertion” state? The diff says no: acquire failure immediately rewrites `isEnabled = false` at `KeepMacAwake.swift:45-48` and persists the resolved value at `:53`. The recursive `didSet`/`suppressApply` mechanism is real removable complexity.
**Estimated remedy LOC:** ~12 LOC across 1 file.

### [shape] Finding 2 — AGREE
Will installer presentation keep gaining app-owned dependencies? Even without future growth, this diff repeats the same `show(downloadManager:client:keepMacAwake:)` call at `StatusView.swift:258/264/271/360` and `PhoenixApp.swift:101/115/125`; collapsing through local/existing `showInstaller()` helpers is branch-negative and prevents argument drift.
**Estimated remedy LOC:** ~8 LOC across 2 files.

## Missed findings (if any)
- [medium] The PR adds a persisted, IOKit-backed `KeepMacAwake` state machine with no test file or deterministic injection seam in the actual diff. A reviewer should ask for 1-2 behavior tests around “persisted true acquires on launch” and “failed acquire reverts/persists false,” rather than the nonexistent `KeepMacAwakeTests.swift` path cited by the tests specialist.