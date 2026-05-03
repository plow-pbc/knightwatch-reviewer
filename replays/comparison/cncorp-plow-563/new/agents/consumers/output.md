## [consumers] findings

### Surveyed
- `InstallerView`, `SettingsView`, and `StatusView` initializer shape changes — clean; each has exactly one updated internal caller.
- `MenuBarController.init` now requiring `keepMacAwake` — clean; only `PhoenixAppDelegate` constructs it and passes the shared instance.
- `InstallerWindowController.show(downloadManager:client:keepMacAwake:)` signature change — clean; all seven repo call sites pass the new argument.
- `KeepMacAwake` `@MainActor` isolation and `isEnabled` stored observable property — clean; consumers are main-actor app setup or SwiftUI bindings.
- New `teardown()` consumer path — clean; called from `applicationWillTerminate`.
- New installer height preference keys — clean; producer/consumer pairs are contained within `SettingsView` and `InstallerView`; no stale external call sites found.