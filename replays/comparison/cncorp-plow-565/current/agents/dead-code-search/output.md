## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `SelfSizingHostingView<Content: View>` at `app/Phoenix/MenuBarController.swift:396` (modified)
Old shape: `private final class SelfSizingHostingView<Content: View>: NSHostingView<Content>`; file-private to `MenuBarController.swift`, no configuration properties.
New shape: `final class SelfSizingHostingView<Content: View>: NSHostingView<Content>`; module-internal with `animatesWindowResize: Bool` and `clampsToScreen: Bool` configuration properties; initializer call shape unchanged.
Callers found:
- `app/Phoenix/MenuBarController.swift:375` — matches new shape; initializer call unchanged, uses default resize flags
- `app/Phoenix/MenuBarController.swift:377` — matches new shape; initializer call unchanged, uses default resize flags
- `app/Phoenix/MenuBarController.swift:380` — matches new shape; initializer call unchanged, uses default resize flags
- `app/Phoenix/PhoenixApp.swift:159` — matches new shape; initializer call unchanged
- `app/Phoenix/PhoenixApp.swift:160` — matches new shape; writes new `animatesWindowResize` property
- `app/Phoenix/PhoenixApp.swift:164` — matches new shape; writes new `clampsToScreen` property
Verdict: clean

## Unreachable conditionals

(none)