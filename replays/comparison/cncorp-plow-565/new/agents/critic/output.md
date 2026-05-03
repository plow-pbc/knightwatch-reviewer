## Critic counterarguments

### [data-integrity] Finding 1 — AGREE
The failing path is real in the capped case: `installerWindowHeight` stops at `cap` (`InstallerView.swift:557`), while the bottom overlay can exceed the fixed `SettingsView` bottom padding (`SettingsView.swift:29`, `DownloadBarView.swift:45-58`). Shape Finding 1 is the same issue.
**Estimated remedy LOC:** ~8 LOC across 2 files.

### [architecture] Finding 1 — AGREE
This is edge-triggered, but the authority mismatch is concrete: cap uses `NSScreen.main` (`InstallerView.swift:523`) while clamp uses `window.screen ?? NSScreen.main` (`MenuBarController.swift:437`), so a smaller secondary display can still get a too-tall SwiftUI frame that AppKit only repositions.
**Estimated remedy LOC:** ~20 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will pre-PMF users actually move the installer onto a smaller non-main display before connector sizing settles, or is this only theoretical multi-display hardening?
- Is there an existing screen/window sizing seam near `SelfSizingHostingView` that can feed the same visible-frame height without adding a second display-resolution path?

### [simplification] Finding 1 — FALSE POSITIVE
The cited `[PLO-35-DEBUG]` harness is not present: `rg` finds no `PLO-35-DEBUG` tag and no `SelfSizingHostingView` debug logging; only the existing `InstallerView.swift:26` DEBUG screen `NSLog` appears. This looks like reviewing a different revision and risks scope-creep cleanup.

### [simplification] Finding 2 — FALSE POSITIVE
`InstallerContentHeightKey` is live in this patch: `SettingsView` emits it at `SettingsView.swift:30-37`, and `InstallerView` observes it at `InstallerView.swift:114-116`. The finding’s premise about an `onGeometryChange` rewrite does not match the actual diff/current file.

### [tests] Finding 1 — MISCALIBRATED
Concern survives, severity does not: the new tests only exercise the pure helper (`InstallerStateTests.swift:120-190`) while the core measurement pipeline is `SettingsView.swift:30-37` → `InstallerView.swift:114-118`. But as a tests-only gap with no severe user-data/security path, “blocking” over-calls it; one focused behavior test should be enough.
**Estimated remedy LOC:** ~45 LOC across 1 file.
**Calibration questions for go-deep investigation:**
- Will this SwiftUI preference measurement path regress at the current pre-PMF operating point without a host-window test, given the PR is specifically fixing a prior green-helper/failed-UI sizing path?
- Is there an existing Phoenix test seam for `NSWindow`/`NSHostingView` sizing, or would this introduce the first AppKit run-loop harness in `app/PhoenixTests`?

### [shape] Finding 1 — DUPLICATE OF [data-integrity] Finding 1
Same capped-overlay failure: fixed `SettingsView` bottom padding versus a taller bottom-anchored `DownloadBarView` when the outer height is capped. Keep one version, preferably the data-integrity wording because it names the user-observable clipped rows.

### [shape] Finding 2 — FALSE POSITIVE
The referenced `[PLO-35-DEBUG]` logging surface is not in the current files; `MenuBarController.swift:417` is just `syncWindowSize(animate:)`, not logging. The only DEBUG `NSLog` found is `InstallerView.swift:26`, so the finding overstates the retained diagnostic harness.

### [consumers] Finding 1 — FALSE POSITIVE
Same mismatch as simplification Finding 2: `InstallerContentHeightKey` has both a producer (`SettingsView.swift:30-37`) and a consumer (`InstallerView.swift:114-116`). It is not a dead internal symbol in the actual patch.