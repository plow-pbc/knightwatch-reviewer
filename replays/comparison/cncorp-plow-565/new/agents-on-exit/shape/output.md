## Shape findings

### Surveyed
- `SelfSizingHostingView` promotion plus `animatesWindowResize` / `clampsToScreen` flags — clean; extends the existing window-sizing seam instead of reintroducing imperative window lookup
- `SettingsView` owning the connectors `ScrollView` frame with `onGeometryChange` — clean; the PR documents observed macOS 26 preference collapse, so this is a justified pattern fork
- Host-display cap source via `visibleFrameHeight` and screen-parameter notifications — clean; one external display fact feeds both cap and clamp
- Overlay height as part of connectors sizing — see Finding 1
- Retained `[PLO-35-DEBUG]` instrumentation — see Finding 2

### Finding 1 — medium
The overlay is modeled as extra window height, but capped overflow still needs scrollable bottom clearance. In the capped case, `frameHeight` becomes `cap` from `contentHeight + overlayHeight`, while the `ScrollView` content still has only fixed `.padding(.bottom, 50)`. The bottom-anchored `DownloadBarView` can be taller than that in retry state, so on small displays or long container lists the last rows can still sit under the bar even though the fallback scroll path “re-engages.” The simplest shape is to make overlay clearance part of the scroll content/inset rather than only the parent frame math.
Files: app/Phoenix/SettingsView.swift:41, app/Phoenix/SettingsView.swift:59, app/Phoenix/InstallerView.swift:48

### Finding 2 — medium
Broken-Glass Test / Name the Shape question: Will another pre-merge runtime capture of `[PLO-35-DEBUG]` logs be needed after the branch already has the 680x637 accessibility verification? If that external verification need is gone, the PR is carrying a diagnostic harness rather than the installer-sizing shape: `InstallerView`, pure helpers, and shared `SelfSizingHostingView` all retain DEBUG-only logging branches. The remedy cost is not LOC; it is persistent conditionals and log-string surface in a shared sizing seam, which conflicts with Concise Code once diagnosis is complete.
Files: app/Phoenix/InstallerView.swift:83, app/Phoenix/InstallerView.swift:589, app/Phoenix/MenuBarController.swift:417