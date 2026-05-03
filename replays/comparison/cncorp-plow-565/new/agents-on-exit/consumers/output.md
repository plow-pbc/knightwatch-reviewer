## [consumers] findings

### Surveyed
- `SettingsView` initializer shape after adding `visibleFrameHeight` / `overlayHeight` — clean
- `SelfSizingHostingView` promotion from private to internal and existing menu-bar panel callers — clean
- `animatesWindowResize` / `clampsToScreen` flag consumers — clean
- `installerHeightCap` and `installerWindowHeight` helper callers in production and tests — clean
- `InstallerOverlayHeightKey` emission and observer path — clean
- `InstallerContentHeightKey` after the final `onGeometryChange` rewrite — see Finding 1

### Finding 1 — medium
`InstallerContentHeightKey` is now a dead internal module symbol. The final `SettingsView` measures with `.onGeometryChange` instead of emitting a preference, and `InstallerView` only observes `InstallerOverlayHeightKey`, so this leftover key has no live producer or consumer. Broken-Glass Test favors deleting this because the remedy removes a stale abstraction and stale contract comments rather than adding conditionals, special cases, or defensive branches.
Files: app/Phoenix/InstallerView.swift:670, app/Phoenix/SettingsView.swift:69, app/Phoenix/InstallerView.swift:127