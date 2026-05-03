## [data-integrity] findings

### Surveyed
- `KeepMacAwake` state model in [app/Phoenix/KeepMacAwake.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/KeepMacAwake.swift:14) — see Finding 1
- Single-instance ownership of `KeepMacAwake` through [app/Phoenix/PhoenixApp.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/PhoenixApp.swift:42) into installer + status surfaces — clean
- Toggle bindings in [app/Phoenix/SettingsView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/SettingsView.swift:181) and [app/Phoenix/StatusView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/StatusView.swift:430) for cross-surface consistency — clean
- Teardown/release path on app termination in [app/Phoenix/PhoenixApp.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/PhoenixApp.swift:104) and [app/Phoenix/KeepMacAwake.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/KeepMacAwake.swift:35) — clean
- Installer auto-size clamp and overlay-height math in [app/Phoenix/InstallerView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/InstallerView.swift:512) — see Finding 2

### Finding 1 — medium
`applyEnabled()` conflates “user preference” with “current assertion state.” When `IOPMAssertionCreateWithName` returns any non-success, the code flips `isEnabled` to `false` and immediately overwrites `UserDefaults` with that value. Apple documents that any non-success here means power management could not activate the assertion, not that the user changed their mind, so a transient acquire failure permanently clears the opt-in and future launches stop retrying. The user-visible result is Plow silently losing its “stay reachable while asleep” behavior until the user manually re-enables it. Remedy cost is small: keep the current-session UI rollback, but do not persist that rollback as the stored preference. Source: https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname  
Files: [app/Phoenix/KeepMacAwake.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/KeepMacAwake.swift:23)

### Finding 2 — low
The new installer-height cap is taken from `NSScreen.main`, not from the installer window’s actual screen. On a common multi-monitor setup where the installer is dragged to a smaller secondary display, `targetWindowHeight()` can compute a cap larger than that display’s visible frame and then animate the window partly off-screen, hiding the bottom settings rows or the download bar the PR is trying to preserve. The fix is cheap and branch-free: derive the cap from `window.screen?.visibleFrame` (or the installer window found a few lines above) instead of the process-global main screen.  
Files: [app/Phoenix/InstallerView.swift](/home/odio/.pr-reviewer/workdirs/cncorp_plow__563/app/Phoenix/InstallerView.swift:512)