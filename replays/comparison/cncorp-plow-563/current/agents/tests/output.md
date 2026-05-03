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