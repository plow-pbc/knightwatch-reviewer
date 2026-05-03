## [tests] findings

### Surveyed
- PR test signal — clean; `.codex-scratch/test-results.md` was absent, but current GitHub PR checks show App build and API passing.
- Failed runtime acquire rollback tests — clean; covers toggle-on failure and seeded-true launch failure.
- Test seam for `IOPMAssertionCreateWithName` — clean; closure injection keeps the failure path deterministic without real IOKit.
- UserDefaults isolation in `KeepMacAwakeTests` — clean; per-test suite names avoid cross-test state leakage.
- Successful assertion lifecycle coverage — see Finding 1.
- Settings/status toggle UI plumbing — clean; both bind to the same `KeepMacAwake` model, so model-level coverage is the right leverage.

### Finding 1 — medium
The new tests only drive `KeepMacAwake` through forced acquire failures, so CI never exercises the core success lifecycle: seeded `true` acquires an assertion, toggling ON persists `true`, toggling OFF releases it, and `teardown()` releases while enabled. A regression where the success path stops storing `assertionID`, or app termination stops releasing, would pass both tests because they return `kIOReturnError` at lines 32 and 76. The concrete seam is to extend the existing IOKit injection with an `AssertionReleaser` closure; that is one DI seam, not conditionals or fallback branches.
Files: app/PhoenixTests/KeepMacAwakeTests.swift:32, app/PhoenixTests/KeepMacAwakeTests.swift:76, app/Phoenix/KeepMacAwake.swift:74, app/Phoenix/KeepMacAwake.swift:86

---

## Critic counter-arguments

### [tests] Finding 1 — FALSE POSITIVE
The cited file/lines do not exist in the current tree or `.codex-scratch/diff.patch`: there is no `app/PhoenixTests/KeepMacAwakeTests.swift`, and `KeepMacAwake.swift` has no `AssertionCreator` or `AssertionReleaser` seam. The underlying test gap is real, but this exact finding’s factual path is wrong.


