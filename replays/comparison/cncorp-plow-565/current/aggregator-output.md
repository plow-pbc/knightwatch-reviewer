_It appears @swagatpatel is working towards making the Phoenix installer feel correctly sized during setup, especially on the connectors screen where settings rows and retry/download bar states can otherwise be clipped or pushed off-screen, by wiring `InstallerView`/`SettingsView` height measurements into `SelfSizingHostingView` in `PhoenixApp.swift` and covering the sizing rules in `InstallerWindowSizeTests` — reviewing against that goal._
> 🎬 Replay of `852beef00a4ca8ec6d95e131b4ff10720614c0ea` (`gh pr view --repo cncorp/plow 565`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — This PR replaces the prior imperative installer resize path with intrinsic sizing through `SelfSizingHostingView`, then feeds connector content and download-bar measurements into a pure height policy. The main path matches the intent; the remaining concern is a low-frequency multi-display mismatch between the screen used to cap height and the screen used to clamp the final window frame.

**Strengths** — Pulling the height decision into `installerWindowHeight(...)` and testing the splash/connectors/overlay/cap cases is the right kind of small seam. Reusing `SelfSizingHostingView` also removes the old `NSApp.windows` lookup shape, which is a cleaner ownership boundary.

**Findings**
1. [low] Will the installer be moved to a shorter secondary display while connector/download content grows? If yes, the cap still comes from `NSScreen.main` while the final frame clamp uses `window.screen`, so a window on a shorter non-main display can be sized from the taller main display and still extend off the active display before `SettingsView` gets to scroll. Use the existing active-screen pattern: carry/derive the screen at the owner seam, like `PanelAnchor.screen`, rather than adding display notification state. Files: app/Phoenix/InstallerView.swift:519, app/Phoenix/MenuBarController.swift:437, app/Phoenix/MenuBarController.swift:192, app/Phoenix/MenuBarController.swift:205. (Standard: Narrow-Fix)

**Open Questions**
- **Q: Shared hosting view file now?** — Will `SelfSizingHostingView` be reused by another Phoenix surface beyond menu bar plus installer soon? If yes, move it to an existing shared seam such as `SharedComponents.swift` or a dedicated `SelfSizingHostingView.swift`. If not, consider cutting the move — it adds review/build-project churn for a maintainer-discoverability concern users will not hit, and makes PMF iteration harder.
- **Q: Hosted measurement regression test?** — Will the connectors screen ever render at 530 because `SettingsView` no longer emits `InstallerContentHeightKey` while `installerWindowHeight` tests still pass? If yes, add a focused hosted-view regression test that observes the preference without extracting production UI. If not, consider cutting that test request for now — it adds a new SwiftUI/AppKit test harness and makes PMF iteration harder.

**Security** — Clean: this is local AppKit/SwiftUI layout state only; no auth, sandbox, persistence, network, or secret surface changed.

**Test coverage** — The added tests cover the pure installer height policy, including fallback, measured connectors content, overlay growth, retry-bar growth, and cap behavior. `.codex-scratch/test-results.md` was not present, so I can’t report a `just test` outcome from the review artifacts.

VERDICT: APPROVE — pending: active-window screen cap alignment
