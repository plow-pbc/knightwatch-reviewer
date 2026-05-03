## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `SelfSizingHostingView` at `app/Phoenix/MenuBarController.swift:396` (modified)
Old shape: `private final class SelfSizingHostingView<Content: View>: NSHostingView<Content>` with unconditional `syncWindowSize()` calls that always ended in `window.setFrame(..., animate: false)`
New shape: `final class SelfSizingHostingView<Content: View>: NSHostingView<Content>` plus configurable `animatesWindowResize` / `clampsToScreen` properties and `syncWindowSize(animate:)`
Callers found:
- `app/Phoenix/MenuBarController.swift:375` — matches new shape
- `app/Phoenix/MenuBarController.swift:377` — matches new shape
- `app/Phoenix/MenuBarController.swift:380` — matches new shape
- `app/Phoenix/PhoenixApp.swift:159` — matches new shape
- `app/Phoenix/PhoenixApp.swift:160` — matches new shape (`animatesWindowResize = true`)
- `app/Phoenix/PhoenixApp.swift:164` — matches new shape (`clampsToScreen = true`)
Verdict: clean

## Unreachable conditionals

(none)