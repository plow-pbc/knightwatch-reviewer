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