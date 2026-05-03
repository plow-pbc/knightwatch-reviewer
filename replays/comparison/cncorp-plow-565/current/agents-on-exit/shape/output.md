## [shape] findings

### Surveyed
- Reuse of `SelfSizingHostingView` for installer sizing instead of a fresh imperative `NSWindow.setFrame` lookup path — clean
- `SettingsView` owning the connectors `ScrollView` frame and reporting height with `onGeometryChange` — clean
- Host-display cap plumbing through `visibleFrameHeight` into `installerHeightCap` — clean
- Splash/connectors height policy centralized in `installerWindowHeight` — clean
- Temporary `[PLO-35-DEBUG]` diagnostics in production source shape — see Finding 1

### Finding 1 — medium
Broken-Glass Test / Name the Shape question: can the temporary diagnostic seam come out before merge? The PR’s spirit is auto-sizing the installer; the current shape carries many installer-only `#if DEBUG` log branches in both `InstallerView` and shared `SelfSizingHostingView`, keyed to `"installer"` and `[PLO-35-DEBUG]`. Even though debug-gated, this adds conditionals and special-case knowledge to the shared hosting-view seam, which violates Concise Code by making future PMF iteration harder to reason about. The author intent says this instrumentation should be reverted once verified, so this looks above the spirit-of-ask line rather than durable shape.
Files: app/Phoenix/InstallerView.swift:83, app/Phoenix/InstallerView.swift:589, app/Phoenix/MenuBarController.swift:417