## [performance] findings

### Surveyed
- `KeepMacAwake` launch and toggle path (`UserDefaults`, IOKit assertion acquire/release) — clean | runs once at launch and only on user toggle, no realistic hot-path cost.
- Failed-acquire rollback via `suppressApply` — clean | bounded to one attempted assertion and one persisted resolved value.
- `StatusView` keep-awake toggle wiring — clean | adds a small observed row to an existing local SwiftUI panel; no per-record or request-scale work.
- `SettingsView` System section toggle — clean | static UI addition with no loop, fetch, or synchronous external I/O.
- Installer/menu-bar plumbing of the shared `KeepMacAwake` instance — clean | passes one object through existing view construction without adding repeated work.
- New `KeepMacAwakeTests` injected assertion/defaults helpers — clean | deterministic unit-only overhead, no production-path scale concern.