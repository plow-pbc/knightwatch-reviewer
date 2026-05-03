## Critic counterarguments

### [data-integrity] Finding 1 — AGREE
Survives: `installerHeightCap()` still sizes against `NSScreen.main` ([app/Phoenix/InstallerView.swift:519](app/Phoenix/InstallerView.swift:519)), while the actual window clamp uses `(window.screen ?? NSScreen.main)` ([app/Phoenix/MenuBarController.swift:437](app/Phoenix/MenuBarController.swift:437)). The author explicitly says round-1 fixed “off-screen growth,” so this is a real gap in the intended fix, not an invented edge case.

### [simplification] Finding 1 — OVER-SPECIFIC
`window.identifier = "installer"` is now inert ([app/Phoenix/PhoenixApp.swift:181](app/Phoenix/PhoenixApp.swift:181)), and repo grep shows no remaining consumer. This is harmless cleanup, but `Incremental Improvement` says not to muddy a focused behavior PR with unrelated tidying unless it materially reduces risk; this one does not.

### [tests] Finding 1 — MISCALIBRATED
`Comment Review Mistakes` #1 says not to make missing layer-by-layer coverage blocking when focused behavior tests already cover the user-visible risk; this PR added 7 sizing-behavior tests ([app/PhoenixTests/InstallerStateTests.swift:120](app/PhoenixTests/InstallerStateTests.swift:120)). The real problem is the concrete bug in [data-integrity] Finding 1, and asking for a new `syncedWindowFrame(...)` seam is the kind of one-off helper bloat warned against by mistake #9/#11.

## Missed findings (if any)
None.