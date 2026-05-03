## [architecture] findings

### Surveyed
- Wake-lock ownership across Phoenix UI vs `plowd` runtime boundaries — see Finding 1
- Runtime-startup and process-ownership roadmap in the Phoenix architecture docs — see Finding 1
- Existing machine-local preference patterns (`LaunchAtLogin`, `FinderSidebarFavorite`, `KeepMacAwake`) and where they are surfaced — clean
- Whether “Settings” is a standalone surface or still routed through installer chrome — see Finding 2
- Installer auto-sizing changes added to accommodate the new toggle — see Finding 2

### Finding 1 — medium
`KeepMacAwake` is owned entirely by the Swift UI app process (`PhoenixAppDelegate` singleton + `applicationWillTerminate` teardown), but the docs describe `plowd` as the runtime/process owner today and explicitly call out a move toward launchd/SMAppService-owned startup next. That makes this a `Narrow-Fix` to the current app-owned shape: as runtime ownership moves out of the UI, “keep agent reachable” will have to be rethreaded across layers or it will stop matching the product promise. The cheaper seam is a runtime-owned policy (“user opted in” + runtime active), not a UI-owned assertion object.
Files: docs/phoenix.md:3-21,117-119; docs/phoenix-openclaw-security-architecture.md:23-27,110-116; app/Phoenix/PhoenixApp.swift:37-45,87-106; app/Phoenix/KeepMacAwake.swift:14-54

### Finding 2 — low
This PR deepens the existing coupling where steady-state settings are still hosted inside the installer window. The app’s Settings command and status-panel Settings button both open `InstallerWindowController`, and adding one more persistent preference required new installer-only height/overlay machinery. That is a `Reframe the Spec` / `Concise Code` smell: the real problem is not window sizing, it is that onboarding chrome is carrying long-lived system settings. With upcoming host integrations already calling for more status/settings affordances, this seam will keep turning ordinary preference work into installer-state work. A dedicated settings host reused by onboarding would age better than growing the installer further.
Files: app/Phoenix/PhoenixApp.swift:14-20,124-125,136-187; app/Phoenix/StatusView.swift:359-364,430-518; app/Phoenix/SettingsView.swift:171-202; app/Phoenix/InstallerView.swift:512-571; docs/architecture/2026-04-27-onepassword-broker-spike-findings.md:27-31