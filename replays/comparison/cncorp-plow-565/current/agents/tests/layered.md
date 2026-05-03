## [tests] findings

### Surveyed
- Recorded `just test` output — unavailable locally; `.codex-scratch/test-results.md` was missing, so I could not classify run failures
- Added `InstallerWindowSizeTests` for `installerWindowHeight` math — clean for pure height/cap cases
- Secondary-display cap regression tests — see Finding 2
- New `SettingsView` `onGeometryChange` measurement path — see Finding 1
- `SelfSizingHostingView` installer sizing/clamp flags — clean for scope; behavior is indirectly covered by the cap math, not by AppKit frame tests
- Existing Phoenix test patterns — clean; current suite is mostly pure/unit tests with no established SwiftUI hosting harness

### Finding 1 — blocking
This PR’s core bug fix moved from pure height math to `SettingsView`’s `onGeometryChange` feeding `measuredContentHeight`, but the tests still only call `installerWindowHeight` with synthetic non-zero heights. That is the exact gap the PR history says let prior rounds pass while the real connectors window stayed at 530. A regression that removes or breaks the measurement at `SettingsView.swift:69` would leave users seeing the scrollbar/overlap again while every added test still passes. The lowest-cost seam is a tiny internal measurement host or extracted `AutoSizingScrollView` with a `Binding<CGFloat>`, hosted in an `NSHostingView` test and asserted to publish a non-zero height after layout.
Files: app/Phoenix/SettingsView.swift:69, app/PhoenixTests/InstallerStateTests.swift:131

### Finding 2 — blocking
The round-3 fix depends on `InstallerView` refreshing `visibleFrameHeight` from both `NSWindow.didChangeScreenNotification` and `NSApplication.didChangeScreenParametersNotification`, but the regression tests stop at `installerHeightCap(visibleFrameHeight:)`. If either observer is deleted or stops calling `refreshVisibleFrameHeight`, `testSecondaryDisplayCapPreventsOversize` still passes because it injects the final height directly. That misses the user-visible failure: after display reconfiguration, the installer can size against a stale cap and slide under the Dock. A compact seam would be an internal `VisibleFrameHeightTracker`/provider function injected with window/main-screen readers and driven by notification handlers, avoiding extra defensive branches while making the state transition testable.
Files: app/Phoenix/InstallerView.swift:106, app/Phoenix/InstallerView.swift:114, app/PhoenixTests/InstallerStateTests.swift:225

---

## Critic counter-arguments

### [tests] Finding 1 — MISCALIBRATED
The gap is legitimate, but `[blocking]` is over-called: the patch already adds behavior tests for the sizing policy at `app/PhoenixTests/InstallerStateTests.swift:126`, and adding a SwiftUI hosting harness or extracted `AutoSizingScrollView` is extra machinery for one geometry seam. Better as a non-blocking question unless there is a reproduced regression in measurement propagation.
**Estimated remedy LOC:** ~40 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will users hit a regression where `SettingsView.swift:30` stops publishing height while the pure sizing tests still pass, or is there no observed instance in this PR round?
- Can this be covered by one focused hosted-view behavior test without extracting a new production wrapper type?

### [tests] Finding 2 — FALSE POSITIVE
The finding cites `NSWindow.didChangeScreenNotification`, `NSApplication.didChangeScreenParametersNotification`, and `visibleFrameHeight`, but none exist in the current patch; `app/Phoenix/InstallerView.swift:106` is only `onChange(of: screen)`. The surviving display concern is data-integrity Finding 1, not a missing test for nonexistent observers.



---

## Go-deep tech-lead investigation

### Investigation of Finding 1

**Calibration answers:**

**Q1: Will users hit a regression where `SettingsView.swift:30` stops publishing height while the pure sizing tests still pass, or is there no observed instance in this PR round?**
A: No observed instance in this PR round. The real user-facing state is plausible because `SettingsView` is the only content-height emitter (`app/Phoenix/SettingsView.swift:31`, `app/Phoenix/SettingsView.swift:33`) and `InstallerView` falls back to the splash height when `contentHeight <= 0` (`app/Phoenix/InstallerView.swift:552`, `app/Phoenix/InstallerView.swift:554`), while the added tests inject synthetic heights directly (`app/PhoenixTests/InstallerStateTests.swift:143`, `app/PhoenixTests/InstallerStateTests.swift:151`). But the firing-rate evidence points to a different prior failure: the 90-day `git log --stat` entry for `2dd8753f` says the reverted PR #563 used the same PreferenceKey measurement pipeline and failed because imperative `window.animator().setFrame(...)` fought hosting-view intrinsic sizing / hit a window-identifier startup race, not because `SettingsView` stopped publishing. Confidence: high.

**Q2: Can this be covered by one focused hosted-view behavior test without extracting a new production wrapper type?**
A: Probably yes in principle, but not with an existing local pattern. A test-only SwiftUI wrapper could host `SettingsView` and observe `InstallerContentHeightKey`, so no production `AutoSizingScrollView` extraction is necessary. However, the current Phoenix tests are pure XCTest modules (`app/PhoenixTests/InstallerStateTests.swift:1`, `app/PhoenixTests/InstallerStateTests.swift:2`), and `grep -rn "NSHostingView\|NSWindow" app/PhoenixTests --include='*.swift'` found no hosted SwiftUI/AppKit test harness. The only existing tests for this PR target the pure policy helper (`app/PhoenixTests/InstallerStateTests.swift:120`, `app/PhoenixTests/InstallerStateTests.swift:126`). Confidence: medium.

**Pattern search:**
- Existing production pattern for this shape is `StatusView`: it defines a content-height `PreferenceKey` (`app/Phoenix/StatusView.swift:4`), emits it from a `GeometryReader` (`app/Phoenix/StatusView.swift:277`), and consumes it with `.onPreferenceChange` (`app/Phoenix/StatusView.swift:290`). The PR mirrors that pattern in `SettingsView` and `InstallerView` (`app/Phoenix/SettingsView.swift:31`, `app/Phoenix/InstallerView.swift:114`).
- Existing reusable sizing contract is already the pure `installerWindowHeight` helper (`app/Phoenix/InstallerView.swift:546`) with behavior tests for zero measurement fallback, measured content, overlay, retry growth, and cap (`app/PhoenixTests/InstallerStateTests.swift:141`, `app/PhoenixTests/InstallerStateTests.swift:149`, `app/PhoenixTests/InstallerStateTests.swift:157`, `app/PhoenixTests/InstallerStateTests.swift:176`, `app/PhoenixTests/InstallerStateTests.swift:190`).
- No existing hosted-view test pattern was found under `app/PhoenixTests`; production `SelfSizingHostingView` reuse is in `PhoenixApp` (`app/Phoenix/PhoenixApp.swift:159`) and `MenuBarController` (`app/Phoenix/MenuBarController.swift:396`).
- Original remedy ~40 LOC across 2 files per specialist file (`.codex-scratch/specialists/tests.md:25`). A no-extraction test-only wrapper likely cuts production LOC to 0 but still adds a new AppKit/SwiftUI test harness above the Broken-Glass threshold.

**Decline-history check:**
- No prior decline: `.codex-scratch/decline-history.md` has no nonblank lines (`grep -n "." .codex-scratch/decline-history.md` returned no lines).

**Recommendation:** REFRAME
- The test gap is real, but blocking on a new hosted SwiftUI/AppKit harness does not clear the Broken-Glass bar here. The observed prior user bug was the hard-coded / imperatively resized window path, and this PR already replaces that with the existing `SelfSizingHostingView` contract plus pure sizing tests. At the PMF-iteration operating point, adding a new harness for an unobserved measurement-publisher regression is more complexity than the firing rate justifies.
- Will the connectors screen ever render at 530 because `SettingsView` no longer emits `InstallerContentHeightKey` while `installerWindowHeight` tests still pass? If yes, add a focused hosted-view regression test that observes the preference without extracting production UI. If not, consider cutting that test request for now — it adds a new SwiftUI/AppKit test harness and makes PMF iteration harder.