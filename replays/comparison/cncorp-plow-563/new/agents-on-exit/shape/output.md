## Shape findings

### Surveyed
- `KeepMacAwake` persisted toggle plus IOKit assertion ownership — see Finding 1
- Observable-toggle pattern compared with `LaunchAtLogin` and `FinderSidebarFavorite` — see Finding 1
- `keepMacAwake` dependency threading through app, installer, menu bar, and status surfaces — see Finding 2
- Settings surface placement under a new System section — clean
- Status popover toggle placement in the connected view — clean

### Finding 1 — low
Name the Shape / Broken-Glass Test asks: will this toggle ever need to preserve a user-requested ON separately from the macOS-granted assertion state? If not, the recursive `didSet` plus `suppressApply` state machine is above the spirit of a single resolved preference. Phoenix’s existing observable toggles use computed setters over system/backing state, which is simpler and avoids a re-entry flag plus write-count-specific test surface. This is a Concise Code simplification, not added architecture.
Files: app/Phoenix/KeepMacAwake.swift:28, app/Phoenix/KeepMacAwake.swift:60, app/Phoenix/LaunchAtLogin.swift:7, app/Phoenix/FinderSidebar.swift:42

### Finding 2 — low
Name the Shape / Broken-Glass Test asks: will installer presentation keep gaining app-owned dependencies as Phoenix adds setup surfaces before PMF? This PR already shows the cost of the raw-call shape: adding one shared object required updating every `installerController.show(...)` call site. A local `showInstaller()` in `StatusView`, and reusing `PhoenixAppDelegate.showInstaller()` for app-level paths, removes duplication and argument drift; the remedy cost is negative because it deletes repeated calls instead of adding conditionals or special cases.
Files: app/Phoenix/StatusView.swift:258, app/Phoenix/StatusView.swift:264, app/Phoenix/StatusView.swift:271, app/Phoenix/StatusView.swift:363, app/Phoenix/PhoenixApp.swift:101, app/Phoenix/PhoenixApp.swift:115, app/Phoenix/PhoenixApp.swift:124