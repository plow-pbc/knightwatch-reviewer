_It appears @swagatpatel is working towards keeping users’ Plow agent reachable when their Mac would otherwise go to sleep by adding a persistent “Keep Mac Awake” toggle in `SettingsView.swift` and `StatusView.swift`, wired through `PhoenixApp.swift` to `KeepMacAwake.swift`’s IOPM sleep-prevention assertion — reviewing against that goal._
> 🎬 Replay of `48419b4b1a2ce3a375b84570c38e8da9729b9611` (`gh pr view --repo cncorp/plow 563`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — The core feature shape is straightforward: one `@MainActor` `KeepMacAwake` owner, shared through the installer/settings/status UI, acquires an IOPM assertion when enabled and releases it on teardown. The main concerns are that the PR also pulls in installer window auto-sizing work, and the new OS assertion owner lacks behavior tests for the success/release path.

**Strengths** — The toggles bind to the same observable `KeepMacAwake` instance, so Settings and the status popover do not create competing sleep-prevention state. The failed-acquire rollback also keeps persisted state aligned with what the system actually accepted.

**Findings**
1. [medium] Does PLO-30 need to introduce a second installer layout-sizing system? The end-user goal is the keep-awake toggle, but this diff also adds measured content/overlay state, two `PreferenceKey`s, and dynamic `NSWindow` resizing for the installer. That makes future installer changes reason about two sizing paths for a feature that only needs another settings row; keeping the fixed installer behavior or moving sizing into its own focused PR would avoid scope creep that adds complexity and makes PMF iteration harder. Files: `app/Phoenix/InstallerView.swift:14`, `app/Phoenix/InstallerView.swift:114`, `app/Phoenix/InstallerView.swift:537`, `app/Phoenix/InstallerView.swift:554`, `app/Phoenix/SettingsView.swift:32`. Standard: Narrow-Fix / Concise Code.
2. [medium] Will automated coverage accept a new OS assertion owner with no success/release behavior test? `KeepMacAwake`’s contract depends on recording the returned assertion ID, releasing it on toggle-off, and releasing it again on app termination; a regression in any of those paths would make the Mac sleep despite opt-in or leave an assertion around until process exit. There is no `KeepMacAwakeTests.swift` in the current tree, so add a narrow assertion-client/defaults seam and 1-2 `@MainActor` behavior tests for successful acquire, toggle-off release, and teardown release. Files: `app/Phoenix/KeepMacAwake.swift:56`, `app/Phoenix/KeepMacAwake.swift:75`, `app/Phoenix/PhoenixApp.swift:104`. Standard: Tests.
3. [low] Will “your agent stays reachable” be true in the states this implementation explicitly cannot control? The code documents battery downgrade and clamshell limits, but the Settings copy promises reachability without that qualifier. If the product promise is best-effort sleep prevention, soften the copy so the UI does not overstate the system contract. Files: `app/Phoenix/KeepMacAwake.swift:5`, `app/Phoenix/SettingsView.swift:191`. Standard: Spec-Reframe.

**Open Questions**
- **Q: Shared row or local chrome?** — Will both Keep Mac Awake surfaces stay intentionally identical in copy and affordance? If yes, align the copy inline first and extract only after observed drift or a third surface appears. If not, consider cutting the shared component request — it adds complexity and makes PMF iteration harder.

**Security** — Clean: the security specialist found only a local boolean preference, in-process IOKit use, and no widened trust boundary.

**Test coverage** — The tests specialist flagged missing `KeepMacAwake` behavior coverage for successful acquire/release/teardown. No `.codex-scratch/test-results.md` artifact was present, so I cannot report a local `just test` outcome from this review bundle.

VERDICT: COMMENT
