## Critic counterarguments

### [data-integrity] Finding 1 — AGREE
The failing path is real in the current patch: `installerHeightCap()` uses `NSScreen.main` at `app/Phoenix/InstallerView.swift:519`, while `SelfSizingHostingView` clamps against `window.screen` at `app/Phoenix/MenuBarController.swift:437`. A moved installer on a shorter secondary display can still be sized from the taller main display.
**Estimated remedy LOC:** ~40 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will users at this pre-PMF stage commonly drag the installer to a shorter secondary display while connector/download content grows, or are there no observed instances beyond display-edge cases?
- Can the cap be derived from the active installer window’s screen through the existing hosting/window path, instead of adding separate display notification state?

### [architecture] Finding 1 — FALSE POSITIVE
The cited `PLO-35-DEBUG` probes are absent from the current patch and files; `rg "PLO-35"` returns nothing. The only installer `#if DEBUG` log is pre-existing at `app/Phoenix/InstallerView.swift:26`, so this finding is grading stale or different code.

### [simplification] Finding 1 — REFRAME-AS-QUESTION
The concern is real, but the finding asserts shared-file discoverability as settled when this is currently a two-caller internal type.
Reframe:
> Will `SelfSizingHostingView` be reused enough that discoverability outside `MenuBarController.swift` matters now? If yes, move it to `SelfSizingHostingView.swift`. If not, consider cutting the file move — adds complexity and makes PMF iteration harder.
**Estimated remedy LOC:** ~40 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will another Phoenix surface consume this hosting view soon, or is the current reuse limited to menu bar plus installer?
- Can a plain file move preserve behavior without introducing any new abstraction or policy surface?

### [tests] Finding 1 — MISCALIBRATED
The gap is legitimate, but `[blocking]` is over-called: the patch already adds behavior tests for the sizing policy at `app/PhoenixTests/InstallerStateTests.swift:126`, and adding a SwiftUI hosting harness or extracted `AutoSizingScrollView` is extra machinery for one geometry seam. Better as a non-blocking question unless there is a reproduced regression in measurement propagation.
**Estimated remedy LOC:** ~40 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will users hit a regression where `SettingsView.swift:30` stops publishing height while the pure sizing tests still pass, or is there no observed instance in this PR round?
- Can this be covered by one focused hosted-view behavior test without extracting a new production wrapper type?

### [tests] Finding 2 — FALSE POSITIVE
The finding cites `NSWindow.didChangeScreenNotification`, `NSApplication.didChangeScreenParametersNotification`, and `visibleFrameHeight`, but none exist in the current patch; `app/Phoenix/InstallerView.swift:106` is only `onChange(of: screen)`. The surviving display concern is data-integrity Finding 1, not a missing test for nonexistent observers.

### [shape] Finding 1 — FALSE POSITIVE
Same stale-code problem as architecture Finding 1: no `PLO-35-DEBUG` or installer-keyed debug branches exist in `SelfSizingHostingView` or the current diff. The cited shape cost is not present in this snapshot.

## Missed findings (if any)

None identified.