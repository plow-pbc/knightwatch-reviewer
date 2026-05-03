## [data-integrity] findings

### Surveyed
- Settings and download-bar height preferences flowing into `InstallerView` — clean; stale content height is ignored outside `.connectors`
- `installerWindowHeight` zero-measurement, overlay addition, retry-bar growth, and cap behavior — clean
- `SelfSizingHostingView` reuse by the menu-bar panel — clean; defaults preserve the prior non-animated, unclamped behavior
- Installer window creation with intrinsic sizing enabled — clean
- Screen cap and clamp behavior after the installer is moved between displays — see Finding 1

### Finding 1 — low
Under the Broken-Glass Test, the failing path is: the installer is movable, `installerHeightCap()` caps height from `NSScreen.main`, but `SelfSizingHostingView` later clamps position against `window.screen`. If a user drags the installer to a shorter secondary display and then connector/download content grows, the height can still be based on the taller main screen; the clamp only changes `origin.y`, not `height`, so the window can extend off the current display instead of letting `SettingsView` scroll. The remedy cost is small screen-cap plumbing, not new defensive branches or special-case heuristics.
Files: app/Phoenix/InstallerView.swift:519, app/Phoenix/MenuBarController.swift:437

---

## Critic counter-arguments

### [data-integrity] Finding 1 — AGREE
The failing path is real in the current patch: `installerHeightCap()` uses `NSScreen.main` at `app/Phoenix/InstallerView.swift:519`, while `SelfSizingHostingView` clamps against `window.screen` at `app/Phoenix/MenuBarController.swift:437`. A moved installer on a shorter secondary display can still be sized from the taller main display.
**Estimated remedy LOC:** ~40 LOC across 2 files.
**Calibration questions for go-deep investigation:**
- Will users at this pre-PMF stage commonly drag the installer to a shorter secondary display while connector/download content grows, or are there no observed instances beyond display-edge cases?
- Can the cap be derived from the active installer window’s screen through the existing hosting/window path, instead of adding separate display notification state?



---

## Go-deep tech-lead investigation

### Investigation of Finding 1

**Calibration answers:**

**Q1: Will users at this pre-PMF stage commonly drag the installer to a shorter secondary display while connector/download content grows, or are there no observed instances beyond display-edge cases?**
A: The state is reachable but the observed firing-rate evidence is weak. The installer is user-movable (`app/Phoenix/PhoenixApp.swift:182`), connector content and the download bar do feed dynamic height (`app/Phoenix/SettingsView.swift:21`, `app/Phoenix/SettingsView.swift:31`, `app/Phoenix/InstallerView.swift:64`, `app/Phoenix/InstallerView.swift:573`), and the cap/clamp mismatch is real (`app/Phoenix/InstallerView.swift:519`, `app/Phoenix/InstallerView.swift:523`, `app/Phoenix/MenuBarController.swift:437`). But the repo evidence I found frames this as multi-display/degenerate-display handling, not a known user-reported operating-point path: the intent file names connectors clipping/retry-download sizing generally, with no secondary-display mention (`.codex-scratch/inferred-intent.md:1`), and the only secondary-display references are comments/tests around degenerate visible frames (`app/Phoenix/InstallerView.swift:542`, `app/Phoenix/InstallerView.swift:543`, `app/PhoenixTests/InstallerStateTests.swift:185`). `git grep` for drag/secondary/off-screen found no separate user report or plan beyond this PR’s code/comments. Confidence: medium.

**Q2: Can the cap be derived from the active installer window’s screen through the existing hosting/window path, instead of adding separate display notification state?**
A: Yes. The existing design already makes the hosting/window path the owner of resize behavior: `InstallerWindowController` creates the single `InstallerView` call site (`app/Phoenix/PhoenixApp.swift:145`), wraps it in `SelfSizingHostingView` (`app/Phoenix/PhoenixApp.swift:159`), installs that hosting view as the window content (`app/Phoenix/PhoenixApp.swift:174`), and stores the window on the controller (`app/Phoenix/PhoenixApp.swift:189`). `SelfSizingHostingView` already derives clamp geometry from `window.screen` (`app/Phoenix/MenuBarController.swift:437`). The closest existing pattern is `MenuBarController` carrying the active screen at the positioning seam via `PanelAnchor.screen` and then using that exact screen’s `visibleFrame` for clamping (`app/Phoenix/MenuBarController.swift:192`, `app/Phoenix/MenuBarController.swift:205`, `app/Phoenix/MenuBarController.swift:208`, `app/Phoenix/MenuBarController.swift:223`, `app/Phoenix/MenuBarController.swift:247`). Confidence: high.

**Pattern search:**
- Existing single-screen contract: menu-bar positioning resolves one active `NSScreen` and carries it through `PanelAnchor.screen`, then clamps against `anchor.screen.visibleFrame` (`app/Phoenix/MenuBarController.swift:192`, `app/Phoenix/MenuBarController.swift:205`, `app/Phoenix/MenuBarController.swift:208`).
- Existing installer seam: only one `InstallerView` construction exists (`app/Phoenix/PhoenixApp.swift:145`), and the controller already owns `window` (`app/Phoenix/PhoenixApp.swift:133`, `app/Phoenix/PhoenixApp.swift:189`), so a cap closure can read `(self?.window?.screen ?? NSScreen.main)?.visibleFrame.height` without display notifications or global window lookup.
- Existing tests already exercise `installerWindowHeight(... cap:)` with synthetic cap values, including overflow and degenerate visible frame behavior (`app/PhoenixTests/InstallerStateTests.swift:165`, `app/PhoenixTests/InstallerStateTests.swift:184`).
- Recent history: `2dd8753f` introduced the SelfSizingHostingView auto-size path and explicitly rejected `NSApp.windows` lookup because it raced window setup; `852beef0` added `clampsToScreen` for smaller-display bottom overflow. The simpler remedy should keep the current direct controller/window path, not revive the prior global lookup.
- LOC delta: original remedy estimate is ~40 LOC across 2 files (`.codex-scratch/specialists/data-integrity.md:20`); the simpler pattern is roughly ~8-12 LOC: add a `heightCap`/`visibleFrameHeight` closure to `InstallerView`, pass it from the only caller using the controller’s `window?.screen`, and keep the existing pure `installerWindowHeight(... cap:)`.

**Decline-history check:**
- No prior decline found; `.codex-scratch/decline-history.md` has no line content in this checkout.

**Recommendation:** SIMPLIFY-WITH-PATTERN
- Keep the underlying concern, but do not accept a ~40 LOC notification/state remedy at this early stage (`AGENTS.md:111`, `AGENTS.md:113`). The bug is real but low firing-rate, and the repo already has a simpler “derive screen at the owner seam” pattern. Rewritten remedy: make `InstallerView` receive a cap provider from `InstallerWindowController`, e.g. a closure that computes `max(420, ((self?.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 80)`, and use that as the existing `installerWindowHeight(... cap:)` input. This keeps one execution path and avoids separate display-change machinery.