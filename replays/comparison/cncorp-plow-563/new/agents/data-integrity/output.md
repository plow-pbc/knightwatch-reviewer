## [data-integrity] findings

### Surveyed
- `KeepMacAwake` enable/disable state machine — clean: `@MainActor` serializes UI toggles, failed acquire reverts `isEnabled`, and the resolved value is persisted.
- Startup from persisted `true` — clean: `init()` explicitly calls `applyEnabled()`, so launch either reacquires the assertion or persists `false` on acquire failure.
- Shared Settings/status toggles — clean: both bind to the same `KeepMacAwake` instance threaded from `PhoenixAppDelegate`, so the two UI surfaces do not diverge.
- Assertion teardown on app termination — clean: release is deterministic, while leaving the persisted opt-in intact for the next launch.
- Installer/menu-bar call sites — clean: no new concurrent owners or duplicated assertion state were introduced.
- Failure-path tests with injected `AssertionCreator` and `UserDefaults` — clean: they cover retry/revert behavior without touching real IOKit state.