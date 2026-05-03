## [simplification] findings

### Surveyed
- `kid` prior-art surface — clean; `.codex-scratch/prior-art.md` was empty and repo grep found no existing `KeepMacAwake`/IOPM utility to reuse
- `KeepMacAwake` assertion acquisition, failure rollback, and test injection points — clean; the extra seams are tied to deterministic failure tests
- installer auto-sizing code in the stale scratch diff — clean; current PR head has reverted it and only keeps `keepMacAwake` pass-through
- Phoenix project file addition for `KeepMacAwakeTests.swift` — clean; the final IDs are isolated to the test file entry
- duplicated Keep Mac Awake UI rows — see Finding 1
- repeated installer-opening calls in `StatusView` — see Finding 2

### Finding 1 — low
Under the Broken-Glass Test, can the Keep Mac Awake control stay single-source? The PR adds two hand-copied controls with the same title, binding, empty-label `Toggle`, switch style, and tint; the later accuracy tooltip only landed on the Settings version, so the duplicate has already diverged. A small shared view/helper for the label+toggle, with each surface keeping its own chrome, would avoid conditionals and special cases while satisfying Concise Code.
Files: app/Phoenix/SettingsView.swift:170, app/Phoenix/SettingsView.swift:176, app/Phoenix/SettingsView.swift:186, app/Phoenix/SettingsView.swift:191, app/Phoenix/StatusView.swift:433, app/Phoenix/StatusView.swift:437, app/Phoenix/StatusView.swift:440

### Finding 2 — nit
Can `StatusView` collapse the repeated installer-opening command before the dependency bundle grows further? The exact `installerController.show(downloadManager: client: keepMacAwake:)` call now appears in four button/menu actions, and this PR had to touch each one just to thread the new dependency. A file-local `showInstaller()` helper is a low-cost Concise Code cleanup: one method, no defensive branches, no new abstraction outside the view.
Files: app/Phoenix/StatusView.swift:258, app/Phoenix/StatusView.swift:264, app/Phoenix/StatusView.swift:271, app/Phoenix/StatusView.swift:363