## [security] findings

### Surveyed
- `KeepMacAwake` persistence through `UserDefaults` — clean; stores only a local boolean preference, no secrets or PII.
- IOKit assertion acquisition and failure logging — clean; logs only numeric `IOReturn`, not user data, tokens, paths, or connector state.
- Toggle surfaces in `SettingsView` and `StatusView` — clean; local UI state only, no new HTTP route, auth bypass, or cross-user control path.
- `InstallerWindowController.show(...)` and view-tree threading of `KeepMacAwake` — clean; dependency is passed in-process and does not widen a trust boundary.
- Test injection points for `UserDefaults` and `AssertionCreator` — clean; scoped to local construction and do not expose runtime command execution or external input handling.
- New Xcode test target wiring — clean; no new third-party dependency or vulnerable package surface.
- Physical-security angle of keeping the Mac awake — clean under the Broken-Glass Test; this is an explicit local opt-in and not a failing auth/session/privacy contract.