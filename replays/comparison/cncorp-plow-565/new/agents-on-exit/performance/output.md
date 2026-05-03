## [performance] findings

### Surveyed
- `SettingsView` intrinsic sizing via `onGeometryChange` and a 1pt deadband — clean; state updates are bounded to actual height changes.
- Installer overlay height measurement through `InstallerOverlayHeightKey` — clean; single visible overlay, no growing loop or I/O.
- `SelfSizingHostingView.syncWindowSize` resize path — clean; constant-time frame math with an equality short-circuit before `setFrame`.
- Display-change handling for `visibleFrameHeight` — clean; notification-driven, no polling.
- Connectors/container list rendering inside the installer `ScrollView` — clean; local UI work, no DB/HTTP calls added in render paths.
- `installerWindowHeight` / `installerHeightCap` helpers and tests — clean; pure constant-time math.