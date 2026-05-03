## [consumers] findings

### Surveyed
- Constructor/call-site chain for the new `keepMacAwake` dependency across `PhoenixAppDelegate` → `MenuBarController` → `StatusView` and `InstallerWindowController.show(...)` → `InstallerView` → `SettingsView` — clean
- `KeepMacAwake.isEnabled` lifecycle, including the new `teardown()` path and the `@MainActor` shift in [app/Phoenix/KeepMacAwake.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/KeepMacAwake.swift:14) and [app/Phoenix/PhoenixApp.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/PhoenixApp.swift:104) — clean
- Modified symbols the prepass did not enumerate explicitly (`KeepMacAwake.teardown()`, `InstallerContentHeightKey`, `InstallerOverlayHeightKey`) — clean
- Repo-wide grep for `KeepMacAwake`, `keepMacAwake.isEnabled`, `InstallerView(`, `SettingsView(`, `StatusView(`, and `MenuBarController(` across this repo plus the only included sibling search root — clean
- Unreachable/dead-code pass over the new auto-sizing preference-key flow in [app/Phoenix/InstallerView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/InstallerView.swift:69) and [app/Phoenix/SettingsView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/SettingsView.swift:29) — clean