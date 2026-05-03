## [pattern-conformance] findings

### Surveyed
- `KeepMacAwake`’s observable state machine and persistence path versus existing Phoenix toggle models in `LaunchAtLogin` and `FinderSidebarFavorite` — see Finding 1
- App-wide injection of `keepMacAwake` from `PhoenixAppDelegate` through `MenuBarController` and `InstallerWindowController` into SwiftUI views — clean
- Installer auto-sizing via `PreferenceKey` against the existing content-height measurement pattern in `StatusView` — clean
- Logging/error reporting for assertion acquisition failure versus Phoenix’s existing `NSLog` usage in runtime/app services — clean
- New Settings / Status toggle surfaces reusing existing row and toggle composition patterns instead of inventing a new settings UI seam — clean

### Finding 1 — blocking
`KeepMacAwake` solves the same problem class as `LaunchAtLogin` and `FinderSidebarFavorite`: an `@Observable` toggle backed by an OS side effect. Phoenix already has a canonical shape for that: expose `isEnabled` as a computed property over backing state and perform the side effect in the setter. This PR bypasses that shape and introduces a second one: stored `isEnabled`, `didSet { applyEnabled() }`, plus a `suppressApply` recursion guard. Per `Name the Shape` and `Concise Code`, this calcifies an avoidable parallel pattern. The cheaper remedy is to conform `KeepMacAwake` to the existing backing-storage/setter shape and delete the reentrancy flag entirely.
Files: app/Phoenix/KeepMacAwake.swift:19, app/Phoenix/KeepMacAwake.swift:23, app/Phoenix/KeepMacAwake.swift:42, app/Phoenix/FinderSidebar.swift:30, app/Phoenix/LaunchAtLogin.swift:5