## [data-integrity] findings

### Surveyed
- Live PR diff vs stale scratch diff — clean; GitHub’s current PR has reverted the installer auto-sizing work, so I did not review the stale sizing patch as part of the final correctness surface.
- `KeepMacAwake.applyEnabled()` acquire/revert/persist flow — clean; failed assertion acquire reverts `isEnabled` and writes the resolved value to `UserDefaults` on the main actor.
- Assertion ID lifecycle in `acquireAssertion()` / `releaseAssertion()` — clean; synchronous, guarded, and no shared mutable state is accessed off-main.
- Shared wiring through `PhoenixAppDelegate`, `InstallerView`, `SettingsView`, and `StatusView` — clean; both toggles bind to the same `KeepMacAwake` instance rather than diverging persisted state.
- Quit path via `applicationWillTerminate` → `teardown()` — clean; release is deterministic without changing the persisted opt-in, so relaunch reacquires as intended.
- Failed-acquire tests in `KeepMacAwakeTests` — clean; toggle-time and init-time rollback paths are covered for the data correctness invariant.