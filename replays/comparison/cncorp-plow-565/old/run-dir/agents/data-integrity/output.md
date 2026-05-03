## [data-integrity] findings

### Surveyed
- `InstallerView`’s `installerWindowHeight(...)` mapping across splash, activation, and connectors states — see Finding 1
- `SettingsView`’s `GeometryReader`-based content measurement inside the connectors `ScrollView` — clean
- `DownloadBarView` overlay sizing, including the taller retry state and post-install disappearance — clean
- `SelfSizingHostingView.syncWindowSize(...)` resize/clamp behavior after intrinsic-size invalidation — see Finding 1
- `InstallerWindowSizeTests` covering pure content/overlay arithmetic and splash-vs-connectors branching — clean for the helper itself

### Finding 1 — medium
`installerHeightCap()` derives the cap from `NSScreen.main` and floors it at `420`, but `SelfSizingHostingView` only clamps the resized frame’s origin, not its height. On a smaller secondary/Sidecar display, or after the installer is dragged off the main display, the connectors screen can still request a height larger than the actual `window.screen.visibleFrame`; the clamp then pins the oversized window to `minY`, leaving part of the installer off-screen and potentially hiding connector rows or the retry bar. This is a single-path correctness fix: size against the host window’s visible frame and clamp height there, rather than adding more special-case guards (`Concise Code`, `Fail-Fast`).
Files: app/Phoenix/InstallerView.swift:519-523, app/Phoenix/MenuBarController.swift:437-448