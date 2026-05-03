## [tests] findings

### Surveyed
- Prepared `just test` result artifact — missing locally; GitHub PR checks are passing, so no PR-related failure classification was available from scratch output
- `KeepMacAwakeTests` target wiring in `PhoenixTests` — clean
- Failed runtime toggle-on rollback coverage — clean
- Failed launch-from-persisted-true rollback coverage — clean
- Successful acquire, toggle-off release, and teardown coverage — see Finding 1
- `CountingUserDefaults` write-count assertions — see Finding 2

### Finding 1 — medium
Could the tests cover the success/release state transition, not just acquisition failure? Current tests exercise only `kIOReturnError`, while the feature’s core contract lives in successful `acquireAssertion`, `releaseAssertion`, and `teardown`. A regression that stops recording the returned assertion ID, never calls `IOPMAssertionRelease`, or leaves `hasAssertion` stale would pass automated tests and show up as the Mac still sleeping or an assertion lingering until process exit. Concrete seam: inject an `AssertionReleaser` closure or small assertion-client value beside `AssertionCreator`, then assert toggle-on and toggle-off/teardown behavior. Cost is one symmetric test seam, not conditionals or special cases.
Files: app/Phoenix/KeepMacAwake.swift:53, app/Phoenix/KeepMacAwake.swift:74, app/Phoenix/KeepMacAwake.swift:86, app/PhoenixTests/KeepMacAwakeTests.swift:28

### Finding 2 — nit
Under the Broken-Glass Test, can these tests assert the user-visible state instead of exact `UserDefaults` write counts? The assertions at lines 61 and 95 make a private implementation detail part of the contract; final `isEnabled`, final persisted value, and `acquireCallCount` already cover rollback plus no repeated acquire. Keeping the write-count contract makes harmless refactors fail and carries a custom `CountingUserDefaults` helper for one internal choreography check. The Concise Code remedy is to drop the exact write-count assertions/helper unless a single-write behavior is itself a product requirement.
Files: app/PhoenixTests/KeepMacAwakeTests.swift:61, app/PhoenixTests/KeepMacAwakeTests.swift:95, app/PhoenixTests/KeepMacAwakeTests.swift:106

---

## Critic counter-arguments

### [tests] Finding 1 — AGREE
Will automated coverage accept a new OS assertion owner with no success/release behavior test? The concern survives, but the evidence is stale: current tree has no `app/PhoenixTests/KeepMacAwakeTests.swift`, so failure rollback is also untested, not just release/teardown.

**Estimated remedy LOC:** ~80 LOC across 3 files.

**Calibration questions for go-deep investigation:**
- Will this feature’s core failures be user-visible at launch/toggle time? Yes: a missed release or stale assertion state maps directly to the Mac sleeping or an assertion lingering.
- Can the remedy stay to 1-2 behavior tests plus one small assertion/defaults seam, instead of broad test-target or UI automation churn?

### [tests] Finding 2 — FALSE POSITIVE
The cited `CountingUserDefaults` helper and line references do not exist in the current tree; `rg` finds no `KeepMacAwakeTests.swift` at all. This should not be raised as a brittle-test cleanup.



---

## Go-deep tech-lead investigation

### Investigation of Finding 1

**Calibration answers:**

**Q1: Will this feature’s core failures be user-visible at launch/toggle time? Yes: a missed release or stale assertion state maps directly to the Mac sleeping or an assertion lingering.**
A: Yes, for users who opt into the feature. The object is created at app launch (`app/Phoenix/PhoenixApp.swift:42`), `init()` immediately applies the persisted state (`app/Phoenix/KeepMacAwake.swift:27`, `app/Phoenix/KeepMacAwake.swift:28`), and both Settings and status popover expose toggles bound directly to `isEnabled` (`app/Phoenix/SettingsView.swift:198`, `app/Phoenix/StatusView.swift:437`). The core side effects are exactly the IOKit acquire/release calls (`app/Phoenix/KeepMacAwake.swift:60`, `app/Phoenix/KeepMacAwake.swift:77`), so a stale `hasAssertion` or missed `assertionID` write breaks the user-facing contract. Firing-rate evidence: every persisted-enabled launch and every toggle-on/toggle-off fires this path (`app/Phoenix/KeepMacAwake.swift:23`, `app/Phoenix/KeepMacAwake.swift:24`, `app/Phoenix/KeepMacAwake.swift:42`, `app/Phoenix/KeepMacAwake.swift:53`). Confidence: high.

**Q2: Can the remedy stay to 1-2 behavior tests plus one small assertion/defaults seam, instead of broad test-target or UI automation churn?**
A: Yes. The current tree has no `KeepMacAwakeTests.swift`; the Phoenix test target already uses direct model/service tests via `@testable import Phoenix` (`app/PhoenixTests/ActivationStateTests.swift:1`, `app/PhoenixTests/ActivationStateTests.swift:2`) and `@MainActor` unit tests for app-state code (`app/PhoenixTests/DaemonClientLaunchStateTests.swift:25`, `app/PhoenixTests/DaemonClientLaunchStateTests.swift:46`). Existing patterns support a small injected seam: `DaemonClient` accepts an optional `LimaVMManaging` dependency and tests pass `FakeVMManager` (`app/Phoenix/DaemonClient.swift:436`, `app/PhoenixTests/DaemonClientLaunchStateTests.swift:74`, `app/PhoenixTests/DaemonClientLaunchStateTests.swift:86`), while startup timing uses a narrow test writer hook for one side effect (`app/Phoenix/ActivationState.swift:7`, `app/Phoenix/ActivationState.swift:54`, `app/Phoenix/ActivationState.swift:64`). Confidence: high.

**Pattern search:**
- `git grep -n "KeepMacAwake"` shows production wiring only and no existing tests for this class (`app/Phoenix/KeepMacAwake.swift:14`, `app/Phoenix/PhoenixApp.swift:42`, `app/Phoenix/SettingsView.swift:6`, `app/Phoenix/StatusView.swift:177`).
- `git grep -n "IOPMAssertion"` shows the assertion acquire/release surface is single-owner and isolated to `KeepMacAwake.swift` (`app/Phoenix/KeepMacAwake.swift:60`, `app/Phoenix/KeepMacAwake.swift:77`).
- Existing lightweight dependency seams: optional injected VM manager plus fake (`app/Phoenix/DaemonClient.swift:436`, `app/PhoenixTests/DaemonClientLaunchStateTests.swift:74`, `app/PhoenixTests/DaemonClientLaunchStateTests.swift:86`); module-level writer hook for one side effect (`app/Phoenix/ActivationState.swift:54`, `app/Phoenix/ActivationState.swift:64`).
- `git log --stat --since='90 days ago' -- app/Phoenix/KeepMacAwake.swift` shows the feature was introduced in `684de1d3` and then touched twice on Apr 30 for review fixes and acquire-failure rollback (`e0b5177`, `74908ca`), so this code path is already review-churned despite being small.

**Decline-history check:**
- no prior decline; `.codex-scratch/decline-history.md` has no line-bearing content.

**Recommendation:** KEEP
- This is above the broken-glass comfort zone, but it protects the feature’s central operating contract: keeping the agent reachable while Plow runs. The fix should stay narrowly scoped: one tiny assertion client/closure seam, injected defaults or a test suite defaults instance, and 1-2 `@MainActor` behavior tests for successful acquire, toggle-off release, and teardown release. Do not expand this into UI automation, broader window/controller tests, or exact write-count assertions.