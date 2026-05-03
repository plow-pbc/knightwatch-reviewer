## [data-integrity] findings

### Surveyed
- Settings and download-bar height preferences flowing into `InstallerView` — clean; stale content height is ignored outside `.connectors`
- `installerWindowHeight` zero-measurement, overlay addition, retry-bar growth, and cap behavior — clean
- `SelfSizingHostingView` reuse by the menu-bar panel — clean; defaults preserve the prior non-animated, unclamped behavior
- Installer window creation with intrinsic sizing enabled — clean
- Screen cap and clamp behavior after the installer is moved between displays — see Finding 1

### Finding 1 — low
Under the Broken-Glass Test, the failing path is: the installer is movable, `installerHeightCap()` caps height from `NSScreen.main`, but `SelfSizingHostingView` later clamps position against `window.screen`. If a user drags the installer to a shorter secondary display and then connector/download content grows, the height can still be based on the taller main screen; the clamp only changes `origin.y`, not `height`, so the window can extend off the current display instead of letting `SettingsView` scroll. The remedy cost is small screen-cap plumbing, not new defensive branches or special-case heuristics.
Files: app/Phoenix/InstallerView.swift:519, app/Phoenix/MenuBarController.swift:437