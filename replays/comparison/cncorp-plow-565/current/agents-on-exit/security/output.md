## [security] findings

### Surveyed
- InstallerView height/overlay measurement and screen-parameter observers — clean; only local AppKit/SwiftUI layout state is consumed.
- SettingsView geometry measurement and self-sizing frame logic — clean; no user input, secrets, network calls, or persistence added.
- SelfSizingHostingView promotion plus resize/clamp flags — clean; window frame math only, no auth or sandbox boundary changes.
- InstallerWindowController switch from `NSHostingView` to `SelfSizingHostingView` — clean; existing client/dismiss flow is unchanged.
- DEBUG-gated sizing instrumentation visible in the current GitHub PR diff — clean for security; it logs window/display geometry, not credentials, tokens, message content, or PII.
- InstallerWindowSizeTests additions — clean; synthetic sizing inputs only, no fixture secrets or live external surfaces.