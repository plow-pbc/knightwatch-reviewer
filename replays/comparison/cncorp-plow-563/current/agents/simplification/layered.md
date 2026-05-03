## [simplification] findings

### Surveyed
- `kid` prior-art surface — clean; `.codex-scratch/prior-art.md` was empty and repo grep found no existing `KeepMacAwake`/IOPM utility to reuse
- `KeepMacAwake` assertion acquisition, failure rollback, and test injection points — clean; the extra seams are tied to deterministic failure tests
- installer auto-sizing code in the stale scratch diff — clean; current PR head has reverted it and only keeps `keepMacAwake` pass-through
- Phoenix project file addition for `KeepMacAwakeTests.swift` — clean; the final IDs are isolated to the test file entry
- duplicated Keep Mac Awake UI rows — see Finding 1
- repeated installer-opening calls in `StatusView` — see Finding 2

### Finding 1 — low
Under the Broken-Glass Test, can the Keep Mac Awake control stay single-source? The PR adds two hand-copied controls with the same title, binding, empty-label `Toggle`, switch style, and tint; the later accuracy tooltip only landed on the Settings version, so the duplicate has already diverged. A small shared view/helper for the label+toggle, with each surface keeping its own chrome, would avoid conditionals and special cases while satisfying Concise Code.
Files: app/Phoenix/SettingsView.swift:170, app/Phoenix/SettingsView.swift:176, app/Phoenix/SettingsView.swift:186, app/Phoenix/SettingsView.swift:191, app/Phoenix/StatusView.swift:433, app/Phoenix/StatusView.swift:437, app/Phoenix/StatusView.swift:440

### Finding 2 — nit
Can `StatusView` collapse the repeated installer-opening command before the dependency bundle grows further? The exact `installerController.show(downloadManager: client: keepMacAwake:)` call now appears in four button/menu actions, and this PR had to touch each one just to thread the new dependency. A file-local `showInstaller()` helper is a low-cost Concise Code cleanup: one method, no defensive branches, no new abstraction outside the view.
Files: app/Phoenix/StatusView.swift:258, app/Phoenix/StatusView.swift:264, app/Phoenix/StatusView.swift:271, app/Phoenix/StatusView.swift:363

---

## Critic counter-arguments

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



---

## Go-deep tech-lead investigation

### Investigation of Finding 1

**Calibration answers:**

**Q1: Will users at this early-product operating point hit inconsistent behavior here, or is the only evidence potential future copy drift with no observed instances?**
A: Users can hit two presentations of the same control, but the current code does not show inconsistent behavior: both surfaces bind to `$keepMacAwake.isEnabled` and use the same switch/tint at `app/Phoenix/SettingsView.swift:198` and `app/Phoenix/StatusView.swift:437`. The copy/chrome is intentionally different today: Settings has icon + subtitle at `app/Phoenix/SettingsView.swift:185` and `app/Phoenix/SettingsView.swift:191`, while Status has only a compact `HStack` label at `app/Phoenix/StatusView.swift:433`. The claimed tooltip drift is not present: tooltip/help grep finds Settings tooltips elsewhere and only `StatusView`’s Tools help at `app/Phoenix/StatusView.swift:414`, not a Keep Mac Awake tooltip. Firing-rate evidence for an actual user-visible inconsistency is therefore zero observed instances; the evidence is future drift risk. Confidence: high.

**Q2: Could this be handled by deleting one duplicate surface or aligning copy inline, instead of adding a shared view component?**
A: Yes. The simpler contract is “one shared `KeepMacAwake` model, local UI chrome per surface.” That is already what the code does: `PhoenixApp` owns one model at `app/Phoenix/PhoenixApp.swift:42`, Settings receives it at `app/Phoenix/SettingsView.swift:6`, and Status receives it at `app/Phoenix/StatusView.swift:177`. Deleting one surface would change the inferred product intent, which explicitly says the PR adds a persistent toggle in both `SettingsView.swift` and `StatusView.swift` (`.codex-scratch/inferred-intent.md:1`). If exact copy matters, inline alignment is smaller than a shared component: add/remove the one subtitle line cluster around `app/Phoenix/SettingsView.swift:191`, or add matching copy near `app/Phoenix/StatusView.swift:434`. Confidence: high.

**Pattern search:**
- Existing Phoenix UI patterns favor local helpers inside the owning surface: `SettingsView` keeps `settingsRow` local at `app/Phoenix/SettingsView.swift:416`, and `StatusView` keeps `toolsMenu` and `statusHeaderView` local at `app/Phoenix/StatusView.swift:326` and `app/Phoenix/StatusView.swift:418`.
- `git grep -n "Keep Mac Awake" -- app app/PhoenixTests` returns only the two UI labels at `app/Phoenix/SettingsView.swift:188` and `app/Phoenix/StatusView.swift:434`; there are no tests documenting a requirement that the two rows remain text-identical.
- Related history shows the two surfaces were added separately: commit `e0b51774347e324a735abe4f322ee9cd803fe0cb` added the Settings System section, and commit `48419b4b1a2ce3a375b84570c38e8da9729b9611` added the Status panel toggle. The existing extraction precedent is intra-file reuse, not cross-surface components.
- Original remedy is ~25 LOC across 2 files; inline copy alignment would be ~1-4 LOC, and leaving local chrome unchanged is 0 LOC.

**Decline-history check:**
- No prior decline. `.codex-scratch/decline-history.md` has no non-empty lines.

**Recommendation:** REFRAME
- The duplicate is real, but under the early-product operating point it is not broken glass users are currently cutting themselves on. The current shared contract is the important one: both rows drive the same observable model. A cross-file shared component would make the UI harder to iterate while the product is still discovering where this toggle belongs.
- Will both Keep Mac Awake surfaces stay intentionally identical in copy and affordance? If yes, align the copy inline first and extract only after observed drift or a third surface appears. If not, consider cutting the shared component request — it adds complexity and makes PMF iteration harder.