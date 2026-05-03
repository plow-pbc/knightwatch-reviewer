## [tests] findings

### Surveyed
- `InstallerWindowSizeTests` cover the pure `installerWindowHeight(for:contentHeight:overlayHeight:cap:)` mapping for splash, connectors, overlay, retry-height, and cap cases — clean
- The new `SettingsView`/`DownloadBarView` measurement path feeds `InstallerView` through preference keys, but the added tests never drive that plumbing; they only pass synthetic numbers into the helper — see Finding 1
- `SelfSizingHostingView.syncWindowSize` now owns top-edge pinning, optional animation, and visible-frame clamping for installer resizes — see Finding 1
- `InstallerWindowController.show()` now swaps `NSHostingView` for `SelfSizingHostingView` and enables `animatesWindowResize` plus `clampsToScreen`; there is no regression harness around that wiring — see Finding 1
- The supplied `just test` log fails in `lint-extras` temp-dir creation before Phoenix tests run, so I did not see a PR-specific XCTest failure in the provided gate output — clean

### Finding 1 — blocking
This PR fixes a user-visible installer sizing bug by replacing the resize mechanism, but the only new tests cover helper arithmetic. They never exercise the new code that actually mutates the window frame, so top-edge pinning or `clampsToScreen` can regress while every added test stays green. For a bug-fix PR, that is not a real regression test. Low-cost seam: extract `syncWindowSize`’s frame computation into a pure helper such as `syncedWindowFrame(currentFrame:targetSize:visibleFrame:clampsToScreen:)`, then unit-test top-pin/clamp/no-op cases and the installer’s `clampsToScreen = true` wiring.
Files: app/Phoenix/MenuBarController.swift:396, app/Phoenix/PhoenixApp.swift:153, app/PhoenixTests/InstallerStateTests.swift:120