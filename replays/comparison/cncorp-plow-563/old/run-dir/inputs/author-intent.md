## PR Title
feat(phoenix): keep Mac awake while Plow runs (PLO-30)

## PR Description (author's own explanation)

## Summary

- Adds a "Keep Mac Awake" toggle (Phoenix menu-bar app) backed by `IOPMAssertionCreateWithName` with `kIOPMAssertionTypePreventSystemSleep`, so the agent stays reachable while the Mac is unattended. State persists via `UserDefaults`; the assertion is held for the lifetime of the toggle being on, and released on `applicationWillTerminate`.
- Toggle surfaces in two places: the installer's Settings card (its own "System" section, separate from Connectors) and the connected status popover.
- On acquire failure the toggle reverts to OFF so the UI can't lie about whether sleep is actually being prevented; failures are logged via `NSLog`.
- Installer window now auto-sizes its height to settings content + `DownloadBarView` overlay, with a screen-height clamp and `ScrollView` fallback for unusually-tall content.

## Implementation notes

- `KeepMacAwake` is `@MainActor`, `@Observable`, with `isEnabled` as a stored property so all observers re-render on toggle.
- Two SwiftUI `PreferenceKey`s drive window sizing: `InstallerContentHeightKey` measures the settings VStack, `InstallerOverlayHeightKey` measures the download bar.
- Iterated through two rounds of cross-model code review (claude implementer + codex adversarial reviewer).

## Test plan

- [ ] Toggle "Keep Mac Awake" ON — confirm `pmset -g assertions` shows a `PreventSystemSleep` assertion held by Plow.
- [ ] Toggle OFF — assertion is released within ~1s.
- [ ] Quit the app while toggle is ON — assertion drops (kernel reaps even without `applicationWillTerminate`, but `teardown()` runs the courteous release first).
- [ ] Relaunch with toggle previously ON — assertion re-acquires on launch.
- [ ] Installer window has no scrollbar at default content size; scrollbar reappears only when content genuinely exceeds screen.
- [ ] During the warming-up phase (DownloadBarView visible, including retry state), bottom rows are not hidden under the bar.
- [ ] Toggle visible in both the installer's "System" card and the status popover when connected.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
