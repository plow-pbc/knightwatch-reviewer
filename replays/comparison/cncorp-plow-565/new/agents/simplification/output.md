## [simplification] findings

### Surveyed
- Kid prior-art surface — clean; `.codex-scratch/prior-art.md` is empty, so there were no strong kid hits to triage
- `SelfSizingHostingView` reuse for installer resizing — clean; the shared host view avoids duplicating the old imperative `setFrame` path
- `SettingsView` moving content measurement into the scroll view — clean; this removes the failed parent preference pipeline instead of adding another fallback
- PR-head DEBUG instrumentation in the sizing path — see Finding 1
- Remaining installer measurement preference keys and comments — see Finding 2
- Installer sizing tests for pure height/cap helpers — clean; no repeated setup large enough to warrant a helper

### Finding 1 — low
Will PLO-35 still need post-merge DEBUG-build telemetry from local installer sessions? If not, the branch is carrying temporary diagnosis code across the final path: `InstallerView` logs screen resolution, notifications, cap math, and height math, while `SelfSizingHostingView` logs every intrinsic invalidation and frame sync. Broken-Glass Test favors deleting this now that the final commit says runtime verification produced the 680x637 fix signal; the remedy is only removing conditionals/log branches, not adding architecture, and it keeps the sizing code easier to inspect.
Files: app/Phoenix/InstallerView.swift:34, app/Phoenix/InstallerView.swift:83, app/Phoenix/InstallerView.swift:589, app/Phoenix/MenuBarController.swift:417, app/Phoenix/MenuBarController.swift:448

### Finding 2 — nit
Will another installer screen before PMF need to report intrinsic content height through SwiftUI preferences instead of `SettingsView`’s `onGeometryChange` path? If not, `InstallerContentHeightKey` is now dead-on-touch: the final code removed the content preference observer and SettingsView no longer emits it, but the key and its doc comment still describe the abandoned outer-frame pipeline. Broken-Glass Test and Concise Code both point toward deleting the unused key and stale comment rather than preserving a second measurement contract.
Files: app/Phoenix/InstallerView.swift:664