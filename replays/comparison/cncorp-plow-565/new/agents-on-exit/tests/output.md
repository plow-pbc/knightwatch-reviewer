## [tests] findings

### Surveyed
- Recorded `.codex-scratch/test-results.md` — unavailable in checkout; self-healed with `gh pr checks` and PR body, but no full `just test` tail was present to classify
- `InstallerWindowSizeTests` pure helper coverage — see Finding 1
- Host-display cap tests for secondary display and degenerate visible frames — clean, they pin the new cap math
- Overlay/retry sizing test — clean, now asserts exact normal/retry heights
- Existing `SettingsViewTests` coverage style — see Finding 1; current tests exercise static helpers, not SwiftUI measurement behavior
- `SelfSizingHostingView` resize flags and clamp path — clean for this angle; covered indirectly by runtime verification, not enough to raise a separate tests-only finding

### Finding 1 — blocking
This PR fixes a real regression where helper tests stayed green while the connectors window still rendered at 530 because the SwiftUI measurement path reported/collapsed to zero. The new test block still only calls `installerWindowHeight(...)` with synthetic heights, so it cannot fail if `SettingsView` stops delivering a non-zero height through `onGeometryChange` and users again see the connectors scrollbar / bottom-row overlap. The seam is a focused AppKit/SwiftUI harness: host `SettingsView` in `SelfSizingHostingView` inside an `NSWindow`, pump the main run loop until geometry fires, then assert the resulting intrinsic/window height exceeds the 530 fallback for default connector content. Remedy cost is one UI-sizing harness, not new product conditionals or fallback branches.
Files: app/Phoenix/SettingsView.swift:69, app/Phoenix/SettingsView.swift:82, app/PhoenixTests/InstallerStateTests.swift:126