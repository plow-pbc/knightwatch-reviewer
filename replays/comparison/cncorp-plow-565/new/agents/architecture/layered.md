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

---

## Critic counter-arguments

### [architecture] Finding 1 — AGREE
This is edge-triggered, but the authority mismatch is concrete: cap uses `NSScreen.main` (`InstallerView.swift:523`) while clamp uses `window.screen ?? NSScreen.main` (`MenuBarController.swift:437`), so a smaller secondary display can still get a too-tall SwiftUI frame that AppKit only repositions.
**Estimated remedy LOC:** ~20 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will pre-PMF users actually move the installer onto a smaller non-main display before connector sizing settles, or is this only theoretical multi-display hardening?
- Is there an existing screen/window sizing seam near `SelfSizingHostingView` that can feed the same visible-frame height without adding a second display-resolution path?



---

## Go-deep tech-lead investigation

### Investigation of Finding 1

**Calibration answers:**

**Q1: Will pre-PMF users actually move the installer onto a smaller non-main display before connector sizing settles, or is this only theoretical multi-display hardening?**
A: The state is plausible but firing-rate evidence is weak. The inferred user-facing intent is connector-screen clipping from settings/download-bar sizing, not monitor movement (`.codex-scratch/inferred-intent.md:1`). The only multi-display evidence I found is this PR/review’s own comments and synthetic tests: the cap comment names “multi-display reconfigurations” (`app/Phoenix/InstallerView.swift:521`, `app/Phoenix/InstallerView.swift:523`), the helper doc names “sidecar with a tiny secondary display” (`app/Phoenix/InstallerView.swift:543`), and the test injects `cap: 400` without exercising an actual moved window (`app/PhoenixTests/InstallerStateTests.swift:184`, `app/PhoenixTests/InstallerStateTests.swift:190`). Given the repo’s early-stage bias (`AGENTS.md:111`, `AGENTS.md:113`) and complexity guidance (`AGENTS.md:9`, `AGENTS.md:11`), this reads as theoretical multi-display hardening. Confidence: medium.

**Q2: Is there an existing screen/window sizing seam near `SelfSizingHostingView` that can feed the same visible-frame height without adding a second display-resolution path?**
A: There is an existing authority inside `SelfSizingHostingView`: the clamp reads `(window.screen ?? NSScreen.main)?.visibleFrame` (`app/Phoenix/MenuBarController.swift:437`) after deriving the resized frame from `intrinsicContentSize` (`app/Phoenix/MenuBarController.swift:429`, `app/Phoenix/MenuBarController.swift:436`). But `InstallerView` computes its SwiftUI cap independently from `NSScreen.main` (`app/Phoenix/InstallerView.swift:519`, `app/Phoenix/InstallerView.swift:523`) and `PhoenixApp` only wires `SelfSizingHostingView(rootView:)`, `animatesWindowResize`, and `clampsToScreen` (`app/Phoenix/PhoenixApp.swift:159`, `app/Phoenix/PhoenixApp.swift:160`, `app/Phoenix/PhoenixApp.swift:164`). I did not find an existing callback/environment seam that pushes the host window’s visible-frame height back into SwiftUI. Confidence: high.

**Pattern search:**
- Existing single-owner screen pattern: menu-bar positioning carries `screen` in `PanelAnchor` (`app/Phoenix/MenuBarController.swift:205`, `app/Phoenix/MenuBarController.swift:208`) and then uses `anchor.screen.visibleFrame` for clamping (`app/Phoenix/MenuBarController.swift:192`). That pattern supports the concern, but it is AppKit-owned and does not directly solve the installer SwiftUI cap without new plumbing.
- Current mismatch is concrete: installer height cap uses `NSScreen.main` (`app/Phoenix/InstallerView.swift:523`), while the host-view clamp uses `window.screen ?? NSScreen.main` (`app/Phoenix/MenuBarController.swift:437`).
- Existing tests document cap behavior as a pure input contract (`app/PhoenixTests/InstallerStateTests.swift:120`, `app/PhoenixTests/InstallerStateTests.swift:125`) and cover a degenerate cap synthetically (`app/PhoenixTests/InstallerStateTests.swift:184`, `app/PhoenixTests/InstallerStateTests.swift:190`), but they do not assert host-window screen/source alignment.
- Git history shows the real PLO-35 work already replaced the failed imperative window lookup with `SelfSizingHostingView`, and the follow-up commit added `clampsToScreen`; the remaining issue is a second-order authority mismatch, not the primary clipping bug. Original remedy estimate remains ~20 LOC across SwiftUI/AppKit; I found no existing <20 LOC pattern that feeds `window.screen.visibleFrame.height` into `InstallerView` without adding a new display-state path.

**Decline-history check:**
- No prior decline found; `.codex-scratch/decline-history.md` has no line-numbered entries from `grep -n ^`.

**Recommendation:** REFRAME
- The finding is technically valid, but all three Broken-Glass checks point away from publishing it as a blocking architecture issue: firing rate is unproven, the simpler existing seam only owns AppKit clamping and does not feed SwiftUI sizing, and the remedy likely adds cross-layer state plumbing at an early PMF stage where complexity debt is explicitly more costly than rare breakage.
- Reframed question: Will pre-PMF users actually drag the installer to a smaller non-main display while connector content is settling and hit clipping? If yes, feed one host-window visible-frame height into the installer cap from the existing `SelfSizingHostingView` window-screen authority. If not, consider cutting this fix for now — it adds cross-layer display-state complexity and makes PMF iteration harder.