_It appears @swagatpatel is working towards making the Phoenix installer feel correctly sized during setup, especially on the connectors screen where settings rows and the download/retry bar can otherwise be clipped or push the window off-screen, by wiring `InstallerView` to measured `SettingsView` and `DownloadBarView` heights, using `SelfSizingHostingView` for animated intrinsic window resizing in `PhoenixApp.swift`, and covering the sizing rules in `InstallerWindowSizeTests` — reviewing against that goal._
> 🎬 Replay of `852beef00a4ca8ec6d95e131b4ff10720614c0ea` (`gh pr view --repo cncorp/plow 565`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — This PR moves installer sizing out of the old imperative window-height path and into measured SwiftUI content plus `SelfSizingHostingView`. The overall seam is much better aligned with the intended user outcome, but two gaps still matter: capped overflow does not reserve overlay clearance inside the scroll content, and the tests still mostly prove the pure math rather than the UI measurement path that previously failed.

**Strengths** — Reusing `SelfSizingHostingView` for the installer is the right direction; it extends an existing window-sizing primitive instead of adding another one-off `NSWindow` mutation path.

**Findings**
1. [medium] On capped connector screens, the download/retry bar can still cover the last settings rows. `installerWindowHeight(...)` adds `overlayHeight`, but then caps the outer window with `min(unclamped, cap)`; once capped, `SettingsView` still only has fixed `.padding(.bottom, 50)`, while `DownloadBarView` grows in retry state. That means the ScrollView fallback can re-engage but still leave final rows underneath the bottom overlay. Reuse the measured overlay height as the scroll bottom clearance instead of only adding it to parent frame math. Files: `app/Phoenix/InstallerView.swift:82`, `app/Phoenix/InstallerView.swift:557`, `app/Phoenix/SettingsView.swift:29`, `app/Phoenix/DownloadBarView.swift:45`. Standard: Narrow-Fix.
2. [medium] Will we rely on this PR to prevent another green-helper/failed-UI sizing regression? If yes, the tests need one focused host-window/SwiftUI measurement assertion, because the current coverage exercises `installerWindowHeight(...)` with synthetic numbers while the production contract is `SettingsView` emitting `InstallerContentHeightKey`, `InstallerView` observing it, and the hosting view resizing from that intrinsic size. If that preference path collapses back to zero, these tests can still pass while users see the 530-height connector window again. Files: `app/Phoenix/SettingsView.swift:30`, `app/Phoenix/InstallerView.swift:114`, `app/PhoenixTests/InstallerStateTests.swift:120`. Standard: Tests.

**Open Questions**
- **Q: Host-screen cap authority** — Will pre-PMF users actually drag the installer to a smaller non-main display while connector content is settling and hit clipping? If yes, feed one host-window visible-frame height into the installer cap from the existing `SelfSizingHostingView` window-screen authority. If not, consider cutting this fix for now — it adds cross-layer display-state complexity and makes PMF iteration harder.

**Security** — Clean; the security review found only internal layout measurements and window-frame synchronization, with no new trust boundary, credential, persistence, or network surface.

**Test coverage** — The tests cover the pure sizing helper and cap behavior, but not the live SwiftUI/AppKit measurement path. `.codex-scratch/test-results.md` was not present in this checkout, so I do not have a recorded `just test` outcome to report.

VERDICT: COMMENT
