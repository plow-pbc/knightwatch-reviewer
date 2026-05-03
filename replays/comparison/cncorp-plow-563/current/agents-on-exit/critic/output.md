## Critic counterarguments

### [simplification] Finding 1 — REFRAME-AS-QUESTION
The finding assumes the Settings and status-popover controls should share one product contract; the live code uses different chrome/copy in [SettingsView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/SettingsView.swift:181) vs [StatusView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/StatusView.swift:431), and the cited tooltip divergence is not present in the diff.
Reframe:
> Will both Keep Mac Awake surfaces stay intentionally identical in copy and affordance? If yes, extract a tiny shared row. If not, leave the rows local — a shared component adds complexity and makes PMF iteration harder.

**Estimated remedy LOC:** ~25 LOC across 2 files.

**Calibration questions for go-deep investigation:**
- Will users at this early-product operating point hit inconsistent behavior here, or is the only evidence potential future copy drift with no observed instances?
- Could this be handled by deleting one duplicate surface or aligning copy inline, instead of adding a shared view component?

### [simplification] Finding 2 — AGREE
Can `StatusView` route the four installer-opening actions through one local helper? Yes: all four calls are identical at [StatusView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/StatusView.swift:258), :264, :271, and :360, and a file-local helper is branch-negative cleanup.

**Estimated remedy LOC:** ~5 LOC across 1 file.

### [tests] Finding 1 — AGREE
Will automated coverage accept a new OS assertion owner with no success/release behavior test? The concern survives, but the evidence is stale: current tree has no `app/PhoenixTests/KeepMacAwakeTests.swift`, so failure rollback is also untested, not just release/teardown.

**Estimated remedy LOC:** ~80 LOC across 3 files.

**Calibration questions for go-deep investigation:**
- Will this feature’s core failures be user-visible at launch/toggle time? Yes: a missed release or stale assertion state maps directly to the Mac sleeping or an assertion lingering.
- Can the remedy stay to 1-2 behavior tests plus one small assertion/defaults seam, instead of broad test-target or UI automation churn?

### [tests] Finding 2 — FALSE POSITIVE
The cited `CountingUserDefaults` helper and line references do not exist in the current tree; `rg` finds no `KeepMacAwakeTests.swift` at all. This should not be raised as a brittle-test cleanup.

### [shape] Finding 1 — AGREE
Does PLO-30 need a second installer layout-sizing system? The live diff does add measured height state and preference keys in [InstallerView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/InstallerView.swift:14) and [SettingsView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/SettingsView.swift:32), which is adjacent to the stated keep-awake intent and adds complexity and makes PMF iteration harder.

**Estimated remedy LOC:** ~0 added LOC across 2 files; likely removes ~55 LOC.

## Missed findings (if any)
- [low] Will the UI promise reachability in states the implementation explicitly cannot control? [KeepMacAwake.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/KeepMacAwake.swift:5) documents battery downgrade and clamshell sleep limits, but [SettingsView.swift](/tmp/tmp.xNLg23mTYM/repo/app/Phoenix/SettingsView.swift:191) says “so your agent stays reachable,” which can overpromise the feature’s actual contract.