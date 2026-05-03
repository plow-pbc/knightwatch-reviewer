## [architecture] findings

### Surveyed
- App-wide `KeepMacAwake` ownership in `PhoenixAppDelegate` — clean; matches the current Swift app + plowd host split rather than introducing a daemon/runtime dependency.
- IOKit power assertion wrapper and persistent `UserDefaults` state — clean; no new external dependency or hard-to-reverse data shape.
- Constructor threading through `InstallerView`, `SettingsView`, `MenuBarController`, and `StatusView` — clean; single shared model, no parallel wake-state sources.
- UI placement in installer Settings and connected status popover — clean; the feature is exposed where users already manage local app/runtime controls.
- Current PR diff versus earlier auto-sizing commits — clean; the unrelated installer window sizing path is not present in the live PR diff.
- Phoenix/OpenClaw architecture docs and roadmap boundaries — clean; the change stays in the macOS app layer and does not cross gateway, plowd policy, or VM management boundaries.