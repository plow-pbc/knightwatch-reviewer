## [simplification] findings

### Surveyed
- kid prior-art report — clean; the file is empty, so there were no scored cross-repo DRY hits to adjudicate
- `KeepMacAwake` state/persistence/assertion flow — clean; the recursion guard is local to the acquire-failure path
- duplicated “Keep Mac Awake” UI rows in installer settings and status panel — clean; they share state but have different layout contracts
- installer content/overlay height measurement — see Finding 1
- `SettingsView.keepMacAwakeRow(showDivider:)` API shape — see Finding 2

### Finding 1 — low
Broken-Glass Test question: will installer settings content vary enough across supported Mac displays before PMF to justify shipping PLO-35-style auto-sizing in this PR? The keep-awake feature adds one settings row, but this PR also adds two measured heights, four observation hooks, two `PreferenceKey` types, and a `28` titlebar constant. That remedy cost is new measurement plumbing plus special-case sizing logic, not just LOC. Under Concise Code, if the external need is only “the added row fits,” a fixed connector-window height keeps this PR easier to review and delete.
Files: app/Phoenix/InstallerView.swift:14, app/Phoenix/InstallerView.swift:114, app/Phoenix/InstallerView.swift:537, app/Phoenix/InstallerView.swift:554

### Finding 2 — nit
Will the “Keep Mac Awake” settings row appear in multiple positions with different divider needs before PMF? Today the new `showDivider` parameter has one call site and is always passed `false`, so it adds a small option surface without current reuse. Concise Code favors collapsing this to `settingsRow(showDivider: false)` inside the helper until there is a second real row placement that needs the knob.
Files: app/Phoenix/SettingsView.swift:176, app/Phoenix/SettingsView.swift:182

---

## Critic counter-arguments

### [simplification] Finding 1 — AGREE
Will installer settings content vary enough across supported displays before PMF to justify this sizing machinery? If not, `InstallerView.swift:14-15`, `114-124`, and `531-570` add measurement state, preference keys, observation hooks, and a `28` titlebar constant for one added row; that adds complexity and makes PMF iteration harder.
**Estimated remedy LOC:** ~0 added LOC; deletes ~50 LOC across 2 files.

### [simplification] Finding 2 — AGREE
Will `keepMacAwakeRow` need divider variants before PMF? Current evidence says no: the only call passes `false` at `SettingsView.swift:176`, so the defaulted parameter at `SettingsView.swift:182` is unused option surface. Nit severity is calibrated.
**Estimated remedy LOC:** ~0 added LOC; deletes ~2 LOC across 1 file.


