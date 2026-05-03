## [consumers] findings

### Surveyed
- `SelfSizingHostingView<Content>` visibility and new configuration properties — clean; repo callers in `MenuBarPanel` and `InstallerWindowController` match the unchanged initializer and property writes at `app/Phoenix/MenuBarController.swift:375`, `app/Phoenix/MenuBarController.swift:396`, and `app/Phoenix/PhoenixApp.swift:159`.
- `animatesWindowResize` / `clampsToScreen` consumers — clean; only the installer sets them, while the menu-bar panel uses default behavior at `app/Phoenix/PhoenixApp.swift:160` and `app/Phoenix/PhoenixApp.swift:164`.
- `InstallerContentHeightKey` producer/consumer path — clean; `SettingsView` emits it and `InstallerView` consumes it at `app/Phoenix/SettingsView.swift:33` and `app/Phoenix/InstallerView.swift:114`.
- `InstallerOverlayHeightKey` producer/consumer path — clean; `DownloadBarView` measurement is emitted and consumed in the same installer tree at `app/Phoenix/InstallerView.swift:73` and `app/Phoenix/InstallerView.swift:117`.
- `installerWindowHeight(for:contentHeight:overlayHeight:cap:)` call graph — clean; used by production sizing and the added test coverage at `app/Phoenix/InstallerView.swift:82`, `app/Phoenix/InstallerView.swift:546`, and `app/PhoenixTests/InstallerStateTests.swift:134`.
- Removed `updateWindowHeight(for:)` path — clean; repo grep found no remaining callers after the intrinsic-sizing replacement, so there is no stale internal call site.
- Sibling search coverage for these symbols — clean; `.codex-scratch/search-roots.md` declares no included or missing sibling roots, and the touched symbols are Phoenix app-target internals rather than shared package APIs.