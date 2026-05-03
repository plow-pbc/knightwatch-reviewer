## [simplification] findings

### Surveyed
- Prior-art surface plus manual grep for existing sleep-assertion helpers (`IOPMAssertion*`, “Keep Mac Awake”) — clean; no obvious repo utility or canonical abstraction was bypassed
- `KeepMacAwake` acquire/release/persist flow, compared with nearby observable toggles like `LaunchAtLogin` and `FinderSidebarFavorite` — see Finding 1
- `InstallerWindowController.show(...)` call shape and every new `keepMacAwake` call site in app startup, reopen, and status-popover flows — see Finding 2
- The two “Keep Mac Awake” UI rows in `SettingsView` and `StatusView` — clean; same behavior but materially different layout contracts, so a shared view would be premature
- Installer auto-sizing additions (`InstallerContentHeightKey`, `InstallerOverlayHeightKey`, screen cap) — clean; the two measurements come from distinct view sources and aren’t obvious accidental duplication

### Finding 1 — low
`KeepMacAwake` now carries a mini reentrancy state machine just to roll back a failed enable: `suppressApply`, a guard, then flip `isEnabled` false inside `applyEnabled()`. That extra branch does not appear to buy anything. On acquire failure, setting `isEnabled = false` and returning would already drive the natural second `didSet`, release/persist the false state, and keep the UI honest. Keeping the sentinel means future edits have to reason about two internal flags for a one-step rollback, which is the kind of special-case state `Concise Code` warns against.
Files: app/Phoenix/KeepMacAwake.swift:19,23-24,42-49

### Finding 2 — low
The new wake-toggle dependency widens `InstallerWindowController.show(...)` into a repeated three-argument bundle, and that same bundle is now copied into seven call sites. These are all app-lifetime singletons, so threading them through every “show installer” path adds surface area without adding flexibility; the next installer-owned dependency will force the same signature churn again. A simpler shape is for `InstallerWindowController` to own its static dependencies and expose `show()` as an action, which deletes duplication instead of letting it accrete.
Files: app/Phoenix/PhoenixApp.swift:101,115,125,140-153; app/Phoenix/StatusView.swift:258,264,271,360