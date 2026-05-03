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