## [performance] findings

### Surveyed
- `KeepMacAwake` assertion lifecycle and persisted toggle writes at `app/Phoenix/KeepMacAwake.swift:36` and `app/Phoenix/KeepMacAwake.swift:60` — clean; launch/toggle-only work, no repeated hot path
- IOKit assertion creation through the injected closure at `app/Phoenix/KeepMacAwake.swift:74` — clean; one system call on opt-in or relaunch, guarded by `hasAssertion`
- Assertion teardown at app termination in `app/Phoenix/PhoenixApp.swift:104` — clean; constant-time cleanup on exit
- Installer/status view wiring through `app/Phoenix/InstallerView.swift:53`, `app/Phoenix/PhoenixApp.swift:140`, and `app/Phoenix/StatusView.swift:257` — clean; dependency threading only, no added polling or request-time work
- New SwiftUI rows in `app/Phoenix/SettingsView.swift:159` and `app/Phoenix/StatusView.swift:433` — clean; render-only UI with no file/DB/HTTP work in body
- New tests and `CountingUserDefaults` in `app/PhoenixTests/KeepMacAwakeTests.swift:28` and `app/PhoenixTests/KeepMacAwakeTests.swift:106` — clean; test-only counters, no production-scale concern