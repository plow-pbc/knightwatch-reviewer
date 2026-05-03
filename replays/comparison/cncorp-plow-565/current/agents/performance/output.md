## [performance] findings

### Surveyed
- `SettingsView` connector height measurement via `.onGeometryChange` — clean: constant-time geometry read plus 1pt deadband, no loop/I/O path (`app/Phoenix/SettingsView.swift:69`).
- `installerWindowHeight` and `installerHeightCap` sizing helpers — clean: pure constant-time math with no data growth behavior (`app/Phoenix/InstallerView.swift:588`, `app/Phoenix/InstallerView.swift:625`).
- `SelfSizingHostingView.syncWindowSize` intrinsic-size propagation — clean: constant AppKit frame calculation per invalidation, with early return when size already matches (`app/Phoenix/MenuBarController.swift:444`).
- Overlay height measurement for `DownloadBarView` — clean: one geometry preference and deadbanded state update, no progress-rate work tied to content size (`app/Phoenix/InstallerView.swift:54`, `app/Phoenix/InstallerView.swift:127`).
- Display-change cap refresh notifications — clean: rare OS notifications, no polling or per-frame screen scanning (`app/Phoenix/InstallerView.swift:106`, `app/Phoenix/InstallerView.swift:114`).
- DEBUG `[PLO-35-DEBUG]` instrumentation in layout paths — clean for production performance because it is compiled under `#if DEBUG`, so it does not create a shipped runtime cost (`app/Phoenix/MenuBarController.swift:417`, `app/Phoenix/InstallerView.swift:633`).