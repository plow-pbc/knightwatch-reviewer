## [data-integrity] findings

### Surveyed
- Installer screen-state resolution and connector polling lifecycle — clean
- SelfSizingHostingView resize trigger path from intrinsicContentSize invalidation to NSWindow frame update — clean
- SettingsView intrinsic height measurement inside the ScrollView content — clean
- DownloadBarView overlay measurement and retry-state height growth — see Finding 1
- Pure installerWindowHeight cap behavior and tests — see Finding 1

### Finding 1 — medium
On capped connector screens, the download/retry bar can still cover the last settings rows. The window height is capped with `return min(unclamped, cap)`, but the bar is a bottom overlay and `SettingsView` only has fixed `50pt` bottom padding; when the retry bar is taller than that, the ScrollView cannot scroll its final content fully above the overlay. Users on small displays or degenerate visible frames can see the settings list clipped even though this PR intends the ScrollView fallback to handle overflow. Remedy cost is small: reuse the measured overlay height as scroll bottom inset/padding, without adding new special-case branches.
Files: app/Phoenix/InstallerView.swift:64, app/Phoenix/InstallerView.swift:557, app/Phoenix/SettingsView.swift:29

---

## Critic counter-arguments

### [data-integrity] Finding 1 — AGREE
The failing path is real in the capped case: `installerWindowHeight` stops at `cap` (`InstallerView.swift:557`), while the bottom overlay can exceed the fixed `SettingsView` bottom padding (`SettingsView.swift:29`, `DownloadBarView.swift:45-58`). Shape Finding 1 is the same issue.
**Estimated remedy LOC:** ~8 LOC across 2 files.


