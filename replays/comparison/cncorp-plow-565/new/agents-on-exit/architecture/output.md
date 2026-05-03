## [architecture] findings

### Surveyed
- Installer height ownership across SwiftUI and AppKit — see Finding 1
- `SelfSizingHostingView` promotion from menu-bar-only to shared installer/window primitive — clean, defaults preserve existing panel behavior
- `SettingsView` / `DownloadBarView` measurement via preference keys — clean, keeps sizing data in the SwiftUI layout path instead of imperative window lookup
- Splash-screen fixed-height contract vs connectors intrinsic sizing — clean, matches PR intent and added pure helper tests
- Phoenix app docs boundary for Swift UI layer — clean, change stays inside `app/Phoenix`

### Finding 1 — medium
The height cap and frame clamp use different screen authorities. `InstallerView` computes the max height from `NSScreen.main`, but `SelfSizingHostingView` clamps position against `(window.screen ?? NSScreen.main).visibleFrame`. On a Mac where the installer is moved to a smaller non-main display, the SwiftUI frame can still be sized for the larger main display; the AppKit clamp only moves the oversized frame and cannot shrink it, so the intended ScrollView fallback does not re-engage and the installer can remain clipped/off-screen. Fix cost should stay low: make the sizing cap come from the same host-window screen source, not a new display heuristic layer.

Files: app/Phoenix/InstallerView.swift:519, app/Phoenix/MenuBarController.swift:437