## [security] findings

### Surveyed
- `KeepMacAwake` power assertion acquisition/release path — clean; no secrets, tokens, shell commands, network input, or privilege boundary changes.
- `UserDefaults` persistence for `keepMacAwakeWhileRunning` — clean; stores only a local boolean preference, not sensitive data.
- Failure logging for `IOPMAssertionCreateWithName` — clean; logs only the numeric `IOReturn`, with no PII or credentials.
- Installer and status toggle wiring — clean; local UI only, no new auth/session/HTTP surface.
- Test-only injection points for `UserDefaults` and assertion creation — clean; internal dependency injection does not expose a runtime trust boundary.