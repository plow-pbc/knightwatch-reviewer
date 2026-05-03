## Critic counterarguments

### [data-integrity] Finding 1 — <status: REMEDY-BLOAT>
The PR explicitly defines `isEnabled` as the resolved actual state, not a latent wish: author intent says failed acquire should revert OFF so the UI cannot lie, and `applyEnabled()` persists that resolved value (`.codex-scratch/author-intent.md:10,15`; `app/Phoenix/KeepMacAwake.swift:39-53`). Keeping `UserDefaults=true` while the visible toggle is `false` splits “desired” vs “actual” state and likely needs extra branches/state, which `Anti-Bloat` warns against.

### [data-integrity] Finding 2 — <status: AGREE>
This is concrete and cheap: the cap uses `NSScreen.main` instead of the installer window’s display (`app/Phoenix/InstallerView.swift:537-545`), while the window is movable (`app/Phoenix/PhoenixApp.swift:177-180`). On a smaller secondary monitor, the computed frame can exceed the visible height.

### [architecture] Finding 1 — <status: MISCALIBRATED>
This is roadmap pressure, not a current contract break. `docs/phoenix.md:117-119` still assigns local UI controls to the Swift app, and `launchd/SMAppService` ownership is only a Phase 2 hardening item (`docs/phoenix-openclaw-security-architecture.md:110-116`); product-context says to favor the smallest clean current seam over prebuilding future layers (`.codex-scratch/product-context.md:3,15-19`).

### [architecture] Finding 2 — <status: REMEDY-BLOAT>
Author intent explicitly chose the installer Settings card plus connected status popover (`.codex-scratch/author-intent.md:9-11`). Asking this PR to introduce a dedicated settings host is a broader product refactor, not a local defect, and it falls into `Reframe the Spec` / `Anti-Bloat` territory for a one-toggle change.

### [simplification] Finding 1 — <status: AGREE>
The failure path is already finite without the sentinel: setting `isEnabled = false` would trigger one second `didSet`, run the false branch, and stop (`app/Phoenix/KeepMacAwake.swift:42-53`). `suppressApply` adds internal state the next edit has to reason about without obviously preventing a real bug.

### [simplification] Finding 2 — <status: REMEDY-BLOAT>
The three arguments are explicit app-lifetime singletons rooted in `PhoenixAppDelegate` (`app/Phoenix/PhoenixApp.swift:38-45,87-125`). Hiding them inside `InstallerWindowController` creates a new ownership/DI seam for one window, which `Anti-Bloat` and Comment Review Mistake #9 caution against.

### [tests] Finding 1 — <status: MISCALIBRATED>
“Needs more proof” is fair, but `blocking` plus “inject an assertion client + UserDefaults suite” overreaches. Comment Review Mistake #1 says 1–2 focused behavior tests or smoke checks are enough, and #9 warns against new DI seams when a smaller fix/test would do (`.codex-scratch/standards.md:390,398`).

### [tests] Finding 2 — <status: MISCALIBRATED>
Same calibration problem: extracting pure math helpers just to unit-test the window sizing is test-driven abstraction, not necessarily product-driven design. Given the explicit manual test plan and the standards’ warning against over-calling missing tests as blocking, this reads as low/medium at most unless there is a reproduced regression beyond the follow-up fix commits (`.codex-scratch/author-intent.md:21-27`; `.codex-scratch/commits.md`).

### [shape] Finding 1 — <status: FALSE POSITIVE>
There is no single canonical toggle shape here: `LaunchAtLogin` is a computed property with swallowed errors (`app/Phoenix/LaunchAtLogin.swift:7-19`), while `FinderSidebarFavorite` keeps backing state plus refresh (`app/Phoenix/FinderSidebar.swift:32-53`). The author deliberately used stored `isEnabled` so both surfaces re-render on toggle (`.codex-scratch/author-intent.md:15`), so treating this as shape nonconformance overstates the precedent.

## Missed findings (if any)
- [medium] The new user-facing copy overpromises the feature. `KeepMacAwake.swift:5-11` explicitly says battery mode is effectively only idle-sleep prevention and clamshell sleep cannot be prevented, but both UI rows promise “Prevent system sleep so your agent stays reachable” without that caveat (`app/Phoenix/SettingsView.swift:188-193`, `app/Phoenix/StatusView.swift:434-440`).