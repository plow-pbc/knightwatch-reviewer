## PR Title
fix(phoenix): auto-size installer window via SelfSizingHostingView (PLO-35)

## PR Description (author's own explanation)

## Summary

Installer window now auto-sizes its height to fit content (Connectors card + System card + DownloadBarView overlay) instead of presenting at a fixed ~530pt with a vertical scrollbar. Splash screens (welcome / FDA / activation / connectContext) keep the 530pt design height.

Replaces the imperative `window.animator().setFrame(...)` path attempted (and reverted) in PR #563 with the SwiftUI-driven `SelfSizingHostingView` pattern that already drives the status panel.

## Approach

- `InstallerView.swift` binds a target height into the SwiftUI tree via `installerWindowHeight(for:contentHeight:overlayHeight:cap:)`. Connectors → `min(content + overlay, cap)`; splash → `min(530, cap)`.
- `SettingsView.swift` emits `InstallerContentHeightKey`; `DownloadBarView` overlay emits `InstallerOverlayHeightKey`.
- `MenuBarController.swift` promotes `SelfSizingHostingView` from private → internal and adds `animatesWindowResize` / `clampsToScreen` flags (both default to `false` to preserve the menu-bar panel's prior behavior).
- `PhoenixApp.swift` `InstallerWindowController.show()` wraps the SwiftUI tree in `SelfSizingHostingView` with both flags enabled.

The reverted commits in PR #563 (`c06d059e`, `ad4e121f`) were vulnerable to three failure modes: GeometryReader returning 0 inside a ScrollView, AppKit re-pinning intrinsicContentSize over `setFrame`, and the window-identifier lookup race. The SelfSizingHostingView path avoids all three by driving the window frame from `intrinsicContentSize` instead of imperative lookups.

## Round-1 review trade-offs (commit 852beef0)

- **Double-animation:** dropped SwiftUI `.animation(...)` modifiers on the height plumbing; AppKit's `setFrame(animate: true)` drives the resize end-to-end.
- **Off-screen growth:** added `clampsToScreen: Bool` flag to `SelfSizingHostingView` (default `false` preserves menu-bar panel; installer flips it on); after top-pin, the frame clamps inside `(window.screen ?? NSScreen.main).visibleFrame`.
- **Splash + degenerate cap:** splash now respects the cap (`min(530, cap)`) so a degenerate `visibleFrame` doesn't render off-screen.

## Tests

`InstallerWindowSizeTests` (7 cases, all green):

- `testSplashScreensUseDesignHeight`
- `testConnectorsWithoutMeasurementFallsBackToDesignHeight`
- `testConnectorsSizesToMeasuredContentBelowCap`
- `testConnectorsAddsOverlayHeightToContent`
- `testConnectorsCapsAtVisibleScreen`
- `testConnectorsRetryStateGrowsWindowWithBar`
- `testSplashIsCappedOnDegenerateVisibleFrame`

## Verification

- ✅ `just build` — clean.
- ✅ `just test` — green; `xcodebuild test -only-testing PhoenixTests/InstallerWindowSizeTests` 7/7 in 0.004s.
- ⏳ Manual smoke (acceptance #1–#4) pending — needs human eyes on the running window across connectors / DownloadBar warm-up + retry / splash states / forced-overflow case.

## Test plan

- [ ] `just app build` from the worktree.
- [ ] `/plow-dev-install` (or `cd app/Phoenix && just rmup`).
- [ ] Drive the installer through:
  - [ ] Connectors at default — no scrollbar, all rows visible.
  - [ ] DownloadBarView warm-up + retry-state — bottom rows not occluded.
  - [ ] welcome / FDA / activation / connectContext splashes — window stays at 530.
  - [ ] Forced overflow (small external display, or temporary cap edit) — scroll fallback re-engages cleanly.

Closes PLO-35.
