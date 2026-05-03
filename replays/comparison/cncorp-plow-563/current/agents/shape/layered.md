## [shape] findings

### Surveyed
- `KeepMacAwake` as the single OS assertion owner — clean; novel domain object, no existing power-management seam to bypass.
- `UserDefaults` persistence for the toggle — clean; Phoenix already uses direct `UserDefaults` for app-local preferences.
- `NSLog` on assertion failure — clean; conforms to the existing Phoenix logging style.
- Passing the observable model into `SettingsView` and `StatusView` with `@Bindable` — clean; keeps the toggle state centralized.
- Installer window height measurement added around the settings row — see Finding 1.

### Finding 1 — medium
By `Name the Shape` and the `Broken-Glass Test`, does PLO-30 need to introduce a second installer layout-sizing system? The user-facing intent is “keep the Mac awake while Plow runs,” but this diff also adds measured content state, two `PreferenceKey`s, overlay measurement, and dynamic `NSWindow` resizing. That remedy adds layout conditionals and preference plumbing that future installer changes must reason about, which adds complexity and makes PMF iteration harder. If the new settings row needs space, the simpler shape is to keep the existing fixed installer behavior or handle installer sizing in its own PR.
Files: app/Phoenix/InstallerView.swift:14, app/Phoenix/InstallerView.swift:72, app/Phoenix/InstallerView.swift:114, app/Phoenix/InstallerView.swift:531, app/Phoenix/InstallerView.swift:554, app/Phoenix/InstallerView.swift:566, app/Phoenix/SettingsView.swift:32

---

## Critic counter-arguments

### [shape] Finding 1 — AGREE
Does PLO-30 need a second installer layout-sizing system? The live diff does add measured height state and preference keys in [InstallerView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/InstallerView.swift:14) and [SettingsView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/SettingsView.swift:32), which is adjacent to the stated keep-awake intent and adds complexity and makes PMF iteration harder.

**Estimated remedy LOC:** ~0 added LOC across 2 files; likely removes ~55 LOC.


