## [architecture] findings

### Surveyed
- Phoenix app boundary and current focus from `README.md` / `docs/phoenix.md` — clean
- Intent-to-implementation fit for installer autosizing via `SelfSizingHostingView` — clean
- Split sizing ownership: splash frames in `InstallerView`, connectors self-sizing in `SettingsView` — clean
- Host-screen cap propagation and clamp alignment for secondary displays — clean
- Shared `SelfSizingHostingView` changes used by both menu bar and installer — see Finding 1
- Tests around pure height policy and secondary-display cap behavior — clean

### Finding 1 — low
Could the temporary `PLO-35-DEBUG` probes be removed before merge instead of carrying issue-specific instrumentation through the shared window-sizing primitive? Under the Broken-Glass Test this is not a user-visible bug, but it adds debug-only branches and installer-specific logging to `SelfSizingHostingView`, `installerHeightCap`, and `installerWindowHeight`; that makes the shared sizing layer noisier and harder to reuse for the next UI surface. The low-cost remedy is deletion only: it removes conditionals and log paths without adding a fallback or new abstraction, which aligns with Concise Code and the repo rule to remove debug leftovers.
Files: app/Phoenix/MenuBarController.swift:417, app/Phoenix/InstallerView.swift:83, app/Phoenix/InstallerView.swift:619, AGENTS.md:150