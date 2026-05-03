## [security] findings

### Surveyed
- `InstallerView` height measurement and preference plumbing at `app/Phoenix/InstallerView.swift:64` and `app/Phoenix/InstallerView.swift:80` — clean; only internal `CGFloat` layout data flows through SwiftUI preferences.
- `installerWindowHeight` and preference key definitions at `app/Phoenix/InstallerView.swift:546` — clean; pure sizing logic, no trust boundary, persistence, logging, or network surface.
- `SettingsView` content measurement at `app/Phoenix/SettingsView.swift:20` — clean; measures rendered content height without exposing connector/account data.
- `SelfSizingHostingView` changes at `app/Phoenix/MenuBarController.swift:396` — clean; AppKit window-frame synchronization only, with no auth/session/token handling.
- Installer window host migration at `app/Phoenix/PhoenixApp.swift:145` — clean; changes the hosting view class but does not add daemon calls, HTTP routes, or credential access.
- New sizing tests at `app/PhoenixTests/InstallerStateTests.swift:120` — clean; pure constants and enum cases, no secrets or live fixtures.