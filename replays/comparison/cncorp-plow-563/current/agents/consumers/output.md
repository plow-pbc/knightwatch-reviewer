## [consumers] findings

### Surveyed
- `InstallerView` constructor now requires `keepMacAwake`; repo-wide callers resolve to `PhoenixApp.swift` and pass the singleton — clean
- `SettingsView` constructor now requires `keepMacAwake`; only `InstallerView` constructs it and passes the new dependency — clean
- `MenuBarController.init` and `StatusView` constructor both gained `keepMacAwake`; the only construction path is updated through `PhoenixAppDelegate` — clean
- `InstallerWindowController.show(downloadManager:client:keepMacAwake:)` signature changed; all internal call sites in `PhoenixApp.swift` and `StatusView.swift` pass the new argument — clean
- `KeepMacAwake` / `KeepMacAwake.isEnabled` changed to `@MainActor` observable stored state; internal consumers are SwiftUI toggles and the app delegate singleton lifecycle — clean
- New `InstallerContentHeightKey` and `InstallerOverlayHeightKey` preference keys are consumed by `InstallerView` and emitted by the matching SwiftUI subtrees — clean
- `.codex-scratch/search-roots.md` is empty and no `.siblings` source tree is present; these touched symbols are Phoenix app-internal with no plausible sibling consumers found in this checkout — clean