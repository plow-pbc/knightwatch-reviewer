## [simplification] findings

### Surveyed
- Reuse of `SelfSizingHostingView` for installer sizing instead of adding a second window-resize mechanism — clean
- New `animatesWindowResize` / `clampsToScreen` knobs on the shared hosting view — clean; two consumers is still small enough that booleans beat a new policy type here
- New `InstallerContentHeightKey` / `InstallerOverlayHeightKey` versus the existing `ScrollContentHeightKey` pattern in `StatusView` — clean; similar plumbing, but the aggregation semantics differ enough that a shared helper would be premature
- Extraction of `installerWindowHeight(...)` as the only pure sizing decision point — clean
- `InstallerWindowSizeTests` coverage shape — clean; bounded to the extracted helper rather than duplicating UI setup
- Semantic-duplication surface from `.codex-scratch/prior-art.md` — clean; no strong prior-art hits to reconcile
- Legacy installer window identifier after the PR removes identifier-based sizing — see Finding 1

### Finding 1 — low
This PR removes the old “find the installer window by identifier and resize it imperatively” path, but it still leaves `window.identifier = NSUserInterfaceItemIdentifier("installer")` behind. That identifier no longer has a consumer in-tree, so it is now just stale state in a touched file. Per `Incremental Improvement`, the remedy cost is a one-line deletion and slightly less mental overhead for the next person reading the installer window setup.  
Files: app/Phoenix/PhoenixApp.swift:153, app/Phoenix/PhoenixApp.swift:181