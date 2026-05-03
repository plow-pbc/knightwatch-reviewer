## [consumers] findings

### Surveyed
- `SelfSizingHostingView` and its new `animatesWindowResize` / `clampsToScreen` properties across `app/Phoenix/MenuBarController.swift` and `app/Phoenix/PhoenixApp.swift` — clean; the installer is the only new caller configuring those knobs, and the menu-bar panel still relies on the default behavior.
- `installerWindowHeight(...)` added in `app/Phoenix/InstallerView.swift` — clean; the pre-pass missed this modified symbol, but repo-wide grep shows only the runtime consumer in `InstallerView` and the new unit tests in `app/PhoenixTests/InstallerStateTests.swift`.
- `InstallerContentHeightKey` / `InstallerOverlayHeightKey` preference plumbing between `app/Phoenix/SettingsView.swift` and `app/Phoenix/InstallerView.swift` — clean; each key has one producer and one consumer, so the new declarative sizing path is fully connected with no stale or dead internal API surface.
- Removal of the old imperative `updateWindowHeight(for:)` path from `app/Phoenix/InstallerView.swift` — clean; grep found no remaining callers or references to the fixed-height resize helper after this PR deletes it.
- Cross-repo internal-consumer sweep using the fully covered sibling set from `.codex-scratch/search-roots.md` — clean; none of the included sibling repos reference these Phoenix-only symbols, so there is no hidden internal caller to coordinate.