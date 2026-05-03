## [simplification] findings

### Surveyed
- Kid prior-art surface — clean; `prior-art.md` is empty, so no score ≥ 0.75 duplication hits to keep or dismiss.
- Two new SwiftUI height-preference emitters in `InstallerView` and `SettingsView` — clean; same mechanism, but separate semantic channels for content vs overlay height.
- `installerWindowHeight(...)` helper and sizing tests — clean; small pure helper, direct cases, no unnecessary fallback chain.
- `SelfSizingHostingView` promoted from menu-bar-only to shared installer usage — see Finding 1.
- Added AppKit resize flags, `animatesWindowResize` and `clampsToScreen` — clean; defaults preserve the existing menu-bar behavior without branching at call sites.

### Finding 1 — low
Under the Broken-Glass Test, this is a code-local cleanup question, not a bug: now that `SelfSizingHostingView` is shared by the menu-bar panel and installer, could it stop living inside `MenuBarController.swift`? `PhoenixApp.swift` now depends on a sizing primitive hidden in a controller file whose surrounding context is menu-bar-specific, which makes the shared seam harder to find. The remedy cost is just a file move to a small `SelfSizingHostingView.swift`, with no new conditionals, special cases, or defensive branches.
Files: app/Phoenix/MenuBarController.swift:396, app/Phoenix/PhoenixApp.swift:159