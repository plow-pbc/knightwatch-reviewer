## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `SelfSizingHostingView<Content>` at `app/Phoenix/MenuBarController.swift:396` (modified)
Old shape: `private final class SelfSizingHostingView<Content: View>: NSHostingView<Content>`; no configurable resize animation/screen-clamp properties.
New shape: `final class SelfSizingHostingView<Content: View>: NSHostingView<Content>`; same inherited `init(rootView:)`, with `animatesWindowResize` and `clampsToScreen` configuration.
Callers found:
- `app/Phoenix/MenuBarController.swift:375` — matches new shape; default properties preserve menu-bar panel behavior.
- `app/Phoenix/MenuBarController.swift:377` — matches new shape; default properties preserve menu-bar panel behavior.
- `app/Phoenix/MenuBarController.swift:380` — matches new shape; default properties preserve menu-bar panel behavior.
- `app/Phoenix/PhoenixApp.swift:159` — matches new shape; constructs with inherited `init(rootView:)`.
Verdict: clean

### `SelfSizingHostingView.invalidateIntrinsicContentSize()` at `app/Phoenix/MenuBarController.swift:415` (modified)
Old shape: `override func invalidateIntrinsicContentSize()`
New shape: `override func invalidateIntrinsicContentSize()`
Callers found:
- `app/Phoenix/MenuBarController.swift:415` — framework hook override; signature unchanged for AppKit dispatch.
Verdict: clean

### `SelfSizingHostingView.viewDidMoveToWindow()` at `app/Phoenix/MenuBarController.swift:420` (modified)
Old shape: `override func viewDidMoveToWindow()`
New shape: `override func viewDidMoveToWindow()`
Callers found:
- `app/Phoenix/MenuBarController.swift:420` — framework hook override; signature unchanged for AppKit dispatch.
Verdict: clean

## Unreachable conditionals

(none)