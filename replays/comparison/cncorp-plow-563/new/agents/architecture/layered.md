## [architecture] findings

### Surveyed
- Current Phoenix runtime ownership: Swift app launches and stops PlowD/VM today — clean
- `KeepMacAwake` as one `@MainActor` app-level singleton in `PhoenixAppDelegate` — clean
- IOKit assertion lifecycle and quit teardown — clean
- Installer settings placement in a separate `System` card — clean
- Status popover toggle surface — see Finding 1
- Reverted installer auto-sizing work: current PR keeps fixed installer heights — clean
- Test-only injection seam for IOKit/UserDefaults failures — clean

### Finding 1 — low
Broken-Glass Test asks: Will users normally discover and toggle Keep Mac Awake from the status popover after setup rather than from installer Settings? If yes, this PR splits one product contract across two surfaces: Settings carries the real OS constraints in the subtitle/help, but the connected status panel exposes only `Keep Mac Awake` plus a switch. A user toggling from the status panel can still expect lid-close or battery behavior the assertion cannot deliver. The low-cost remedy is to collapse to one shared row/copy or carry the same help text here; that removes contract drift without adding defensive branches.
Files: app/Phoenix/StatusView.swift:434, app/Phoenix/SettingsView.swift:179

---

## Critic counter-arguments

### [architecture] Finding 1 — AGREE
Will status-popover users rely on that row as the primary control? If yes, the diff really does put the explanatory sleep-limit copy only in `SettingsView.swift:191`, while `StatusView.swift:431-441` carries a label-only toggle. Low severity is calibrated; this is copy parity, not a blocker.
**Estimated remedy LOC:** ~3 LOC across 1 file.


