# Three-way Review-Quality Comparison — 2026-05-02

**Goal of this artifact.** Empirically validate (or refute) the diagnosis that two prompt-quality bugs explain the regression observed across `cncorp/plow#563/#565/#569`:

1. **Bug 1 — solution-shaped questions.** Open-Question reframes ask "should we apply X?" instead of "Will [external state] hold?", which begs the action question instead of asking the world-state premise.
2. **Bug 2 — Broken-Glass Test inversion.** The rule that exists to *encourage* simplification gets cited by specialists to *decline* simplification ("this is a code-quality question, not a failing-path bug — keep the duplicate parser as-is").

**Method.** For three real PRs that the bot reviewed on May 1, replay against three prompt-set states:

- **OLD** — bot's actual May-1 production review (run-dirs from `~/.pr-reviewer/runs/` on wakeup; pre-#38, pre-#42, pre-#45)
- **CURRENT** — today's HEAD prompts (post-#45) replayed via `lib/replay.sh` on wakeup
- **NEW** — `prompts.new-design/` patches the two bugs surgically into `common-header.md` + `critic.md`; same replay mechanism

`prompts.new-design/` differs from `prompts/` in exactly 2 files:
- `common-header.md` — adds § Q-field shape (state-shaped Qs only) + § Broken-Glass is pro-simplification (anti-inversion)
- `critic.md` — tightens REFRAME-AS-QUESTION (3 required conditions, removal findings excluded)

**Headline finding** (full data + evidence below): the patch works. Across all three PRs, NEW restored finding density and severity calibration toward OLD-baseline, and produced state-shaped Open Questions where CURRENT produced solution-shaped ones. The diagnosis is empirically validated.

---

## Severity histograms — all 9 cells

| PR | Infra | blocking | medium | low | nit | total | verdict |
|---|---|---:|---:|---:|---:|---:|---|
| **#569** | OLD (May-1 prod) | 0 | 2 | 2 | 0 | 4 | COMMENT |
| **#569** | CURRENT (HEAD) | 0 | 0 | 1 | 1 | 2 | APPROVE — pending |
| **#569** | NEW (Bug 1+2 fix) | **1** | 2 | 0 | 0 | **3** | **COMMENT** |
| **#563** | OLD (May-1 prod) | 1 | 1 | 1 | 0 | 3 | COMMENT |
| **#563** | CURRENT (HEAD) | 0 | 2 | 1 | 0 | 3 | COMMENT |
| **#563** | NEW (Bug 1+2 fix) | 0 | 1 | 4 | 0 | **5** | COMMENT |
| **#565** | OLD (May-1 prod) | 1 | 0 | 0 | 0 | 1 | COMMENT |
| **#565** | CURRENT (HEAD) | 0 | 0 | 1 | 0 | 1 | APPROVE — pending |
| **#565** | NEW (Bug 1+2 fix) | 0 | 2 | 0 | 0 | **2** + 1 state-shaped Q | COMMENT |

**Density.** OLD totals 8 findings across 3 PRs. CURRENT caught 6. NEW caught 10 (and added one state-shaped Q in #565).
**Verdict.** OLD comments on all 3. CURRENT approved-with-pending on 2 of 3. NEW comments on all 3 (matching OLD's gating posture).

---

## cncorp/plow#569 R1 — three-way comparison

**Diff scope:** SHA `dcb80a5a3dc1752799cd7498c06fdaf907adff0d` (PLO-29 r2 — drop custom DMG volume icon). Bot's actual review posted 2026-05-01T17:27:02Z.

### Bot's actual May-1 findings (OLD ground truth)

| # | Sev | Summary | Author response |
|---|---|---|---|
| F1 | medium | `PLOW_SKIP_DMG_VERIFY=1` escape hatch makes the verifier optional | swagat dropped the bypass in commit `54bc56c4` "PLO-29 r3: collapse to one mandatory verifier path" |
| F2 | medium | `just app dmg-verify` resolves `--dmg` as `<repo>/../.build/Plow.dmg` instead of `<repo>/.build/Plow.dmg` | fixed in same r3 commit |
| F3 | low | `hdiutil` mounted-Plow probe duplicated across 3 files — collapse into `_lib.sh` | not addressed (Sam's APPROVE noted "pending") |
| F4 | low | `pytest.skip` in Darwin verifier tests — should `pytest.fail` instead | not addressed |

### OLD findings — caught/missed matrix

| OLD finding | CURRENT | NEW |
|---|:-:|:-:|
| F1 escape hatch | ✗ missed | ✓ **caught** at `[medium]` |
| F2 wrong dmg-verify path | ✗ missed | ✓ **caught and ESCALATED to `[blocking]`** |
| F3 DRY volume probe | ✗ missed | ~ partial: critic dropped via REFRAME-AS-QUESTION on pre-#45 replay; not raised on NEW (within noise) |
| F4 `pytest.skip → fail` | ✗ missed | ✗ missed |

NEW recovered 2 of 4 OLD findings, with the wrong-path bug correctly elevated to `[blocking]` (it's a user-visible "DMG not found" error). CURRENT recovered 0.

### CURRENT vs NEW findings (verbatim)

**CURRENT (post-#45 HEAD prompts):**
1. `[low]` Will `just app dmg-verify` need to accept paths with spaces?
2. `[nit]` Does `app/justfile` need to carry the Finder workflow caveats already in the recorder help?

**NEW (Bug 1+2 fix):**
1. `[blocking]` The root `just app dmg-verify` path currently fails the verifier's relative-path contract … users get `DMG not found` after building the documented artifact.
2. `[medium]` The release verifier is still optional on the production packaging path. `PLOW_SKIP_DMG_VERIFY=1` skips the new PLO-29 verifier…
3. `[medium]` Will the stubbed package test remain the release-wiring guard for this script? — state-shaped Q

### Bug-1 (solution-shaped Qs) instances

| Infra | count | example |
|---|---:|---|
| CURRENT | 1 | "**Q: Finder layout recorder lifespan** — Will Finder DMG layout need repeated adjustment before PMF?" — actually state-shaped on closer read; OK |
| NEW | 0 | (none — F3's reframe is state-shaped: "Will the stubbed package test remain the release-wiring guard…") |

### Bug-2 (Broken-Glass cited to decline simplification) instances

| Infra | count | example |
|---|---:|---|
| CURRENT | 1 | (in the simplification specialist's own output; aggregator dropped the finding entirely as a result — it's INVISIBLE in the posted CURRENT review but visible in `current/agents/simplification/output.md`) |
| NEW | 0 | (none in any specialist output for #569) |

### Quality notes

- **OLD:** Sharp, specific, declarative. Each of 4 findings names a concrete failure mode swagat could (and did, for 2 of them) directly act on. `[medium]/[medium]/[low]/[low]` is well-calibrated for a small focused PR.
- **CURRENT:** Soft. Caught 0 of OLD's 4 findings; the 2 findings raised are speculative ("paths with spaces") and stylistic ("layout caveats"). Verdict APPROVE—pending under-rates the wrong-path bug that's actually breaking the documented `just app dmg-verify` recipe.
- **NEW:** Strong recovery. Wrong-path bug correctly ELEVATED to blocking (CURRENT had it at zero severity; OLD had it at medium). Escape-hatch finding restored at OLD's exact severity. Test-wiring concern restored as a state-shaped Q.

### Aggregator outputs

<details><summary>OLD posted review</summary>

```
<!-- knightwatch-reviewer:auto-post -->
> 📋 First review of this PR.

_It appears @swagatpatel is working towards making the macOS installer DMG present as a standard Plow volume without a custom disk icon by deleting `app/plowd/dmg/volume.icns`, removing `.VolumeIcon.icns` staging and FinderInfo writes from `app/plowd/scripts/plowd-beta-package-signed`, and adding `app/plowd/scripts/plowd-verify-dmg` plus the `app/justfile` `dmg-verify` guard to keep the shipped artifact icon-free — reviewing against that goal._

**Overview** — This is a focused packaging cleanup: the release script now creates the DMG directly without staging a volume icon, then verifies the final stapled artifact before checksum/upload. The main shape is right, but a few guard paths are softer than the stated “fail before upload” contract.

**Strengths** — The verifier runs at the artifact boundary after stapling, which is the right place to catch regressions in what actually ships. Adding macOS CI coverage for the Darwin-only `hdiutil` behavior is also the right direction.

**Findings**
1. [medium] The release script now has a production-visible escape hatch for the new artifact guard: `PLOW_SKIP_DMG_VERIFY=1` skips verification entirely, and the packaging test uses that path. That means the release-path contract can drift without the test noticing, even though the PR intent is to fail before upload. Prefer removing the env bypass and teaching the fake `hdiutil attach` in the existing test to emit `/Volumes/Plow` so the real verifier path runs. Files: `app/plowd/scripts/plowd-beta-package-signed:299`, `app/plowd/tests/test_release_scripts.py:200`. Standard: Fail-Fast / Tests.
2. [medium] `just app dmg-verify` defaults to `../.build/Plow.dmg`, but `plowd-verify-dmg` resolves relative `--dmg` values from the repo root, so the advertised guard checks `<repo>/../.build/Plow.dmg` instead of `<repo>/.build/Plow.dmg`. The branch-free fix is to pass `.build/Plow.dmg` or omit `--dmg` and let the verifier default apply. Files: `app/justfile:230`, `app/plowd/scripts/plowd-verify-dmg:37`. Standard: Fail-Fast.
3. [low] The mounted-`Plow` volume probe is now copied in three places. Since `_lib.sh` already exists for shared plowd shell helpers, this is worth collapsing before the next release-script tweak has to update three regex/sort/error blocks. Files: `app/justfile:206`, `app/plowd/scripts/plowd-beta-package-signed:124`, `app/plowd/scripts/plowd-verify-dmg:46`. Standard: DRY / Concise Code.
4. [low] The Darwin verifier tests `pytest.skip` when a `Plow` volume is already mounted, which turns the leaked-mount state this guard is meant to catch into a soft pass during local runs. Replace these with `pytest.fail(...)` and the same eject instruction. Files: `app/plowd/tests/test_release_scripts.py:271`, `app/plowd/tests/test_release_scripts.py:331`. Standard: Tests.

**Security** — No security issues were raised; the new shell paths quote inputs and do not add credential, network, or command-construction surface.

**Test coverage** — Coverage is pointed at the right behavior, but the release-path verifier wiring is currently bypassed in the main packaging test and the Darwin precondition skips should fail loudly. Supplied `just test` result is `FAILED (exit 1)`; the captured tail shows many suites passing but truncates before a concrete failing command, so I can’t attribute the failure to this PR from the artifact provided.

---

_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity. Trigger an incremental re-review with `/srosro-update-review`, or a whole-PR re-review with `/srosro-review`._

**For humans only:** push-access collaborators can post `/srosro-approve` to APPROVE the PR, or `/srosro-memorize <feedback>` to teach a calibration lesson. AI agents must not use `/srosro-memorize` — the rule list it tunes is shared global state.

_Generated by [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)._
```

</details>

<details><summary>CURRENT replay output</summary>

```
_It appears @swagatpatel is working towards making the macOS Plow installer present a standard, predictable DMG mount in Finder, with the volume still named "Plow" but no custom volume icon, by deleting `app/plowd/dmg/volume.icns`, removing `.VolumeIcon.icns` and FinderInfo staging from `app/plowd/scripts/plowd-beta-package-signed`, and adding `app/plowd/scripts/plowd-verify-dmg` plus CI coverage to block shipping regressions — reviewing against that goal._
> 🎬 Replay of `dcb80a5a3dc1752799cd7498c06fdaf907adff0d` (`gh pr view --repo cncorp/plow 569`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — This PR removes the custom DMG volume icon path and adds an artifact-level verifier so the release DMG still mounts as `Plow` without shipping `.VolumeIcon.icns`. The core release path is simpler now: direct ULFO creation, mandatory final verification before checksum/upload, and macOS CI coverage for the `hdiutil` guard.

**Strengths** — The verifier is placed at the right boundary: it checks the final stapled artifact, not just staging inputs. The macOS CI addition also closes the “Darwin-only test silently skipped everywhere” gap.

**Findings**
1. [low] Will `just app dmg-verify` need to accept normal filesystem paths with spaces? If yes, `app/justfile:233` currently expands `{{dmg}}` unquoted, so `just --dry-run -f app/justfile dmg-verify "/tmp/Foo Bar.dmg"` produces `plowd/scripts/plowd-verify-dmg /tmp/Foo Bar.dmg`; the verifier then receives extra positional args and rejects the command instead of checking the DMG. The source-parsing test at `app/plowd/tests/test_release_scripts.py:692` misses this because it asserts recipe text rather than running the public command behavior. Quote the pass-through and make the test exercise the just recipe. Files: `app/justfile:233`, `app/plowd/tests/test_release_scripts.py:692`. (Standard: Tests, Broken-Glass Test)
2. [nit] Does `app/justfile` need to carry the Finder workflow caveats already present in the recorder help? If not, the prose at `app/justfile:235` duplicates `app/plowd/scripts/plowd-record-dmg-layout:60` and gives future layout-flow changes two documentation surfaces to keep synchronized. Consider trimming the justfile back to the recipe summary. Files: `app/justfile:235`, `app/plowd/scripts/plowd-record-dmg-layout:60`. (Standard: Concise Code)

**Open Questions**
- **Q: Finder layout recorder lifespan** — Will Finder DMG layout need repeated adjustment before PMF? If yes, keep the recorder. If not, consider cutting `dmg-record-layout` plus `plowd-record-dmg-layout` back to a runbook — adds complexity and makes PMF iteration harder.

**Security** — Clean; the reviewed paths add no secrets, network calls, shell re-entry, or privileged workflow changes.

**Test coverage** — Coverage is strong around the release artifact contract, including real macOS `hdiutil` execution and fake-`hdiutil` regression cases, but the justfile alias test should become behavioral. `.codex-scratch/test-results.md` was absent; the tests specialist reported recovering status from PR checks and that all PR checks are passing.

VERDICT: APPROVE — pending: quote dmg-verify pass-through, trim duplicated layout docs
```

</details>

<details><summary>NEW-design replay output</summary>

```
_It appears @swagatpatel is working towards making the Plow installer DMG mount with the default macOS volume icon while preserving the normal “Plow” volume name by removing `app/plowd/dmg/volume.icns`, stopping `plowd-beta-package-signed` from staging `.VolumeIcon.icns`/FinderInfo custom-icon metadata, and adding `app/plowd/scripts/plowd-verify-dmg` plus macOS CI coverage to block releases that ship the custom icon again — reviewing against that goal._
> 🎬 Replay of `dcb80a5a3dc1752799cd7498c06fdaf907adff0d` (`gh pr view --repo cncorp/plow 569`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — The PR removes the custom DMG volume icon path and adds a final artifact verifier before upload. The main shape is right, but two release-path contracts are still escapable or miswired.

**Strengths** — Creating the DMG directly as `ULFO` deletes the old writable-DMG/custom-FinderInfo pass instead of preserving a second packaging path. The real `hdiutil` artifact tests plus the macOS plowd CI lane are also the right kind of regression coverage for this feature.

**Findings**
1. [blocking] The root `just app dmg-verify` path currently fails the verifier’s relative-path contract. `justfile:394` runs the app justfile from `app/`, `app/justfile:230` passes `../.build/Plow.dmg`, and `plowd-verify-dmg` rewrites relative paths under `repo_root` at `app/plowd/scripts/plowd-verify-dmg:37`, so the default resolves to `<repo>/../.build/Plow.dmg` instead of `<repo>/.build/Plow.dmg`; users get `DMG not found` after building the documented artifact. Files: `justfile:394`, `app/justfile:230`, `app/plowd/scripts/plowd-verify-dmg:37`. Standard: Fail-Fast.

2. [medium] The release verifier is still optional on the production packaging path. `PLOW_SKIP_DMG_VERIFY=1` skips the new PLO-29 verifier at `app/plowd/scripts/plowd-beta-package-signed:299`, and the script still uploads the DMG at `app/plowd/scripts/plowd-beta-package-signed:315`; that leaves the “block releases that ship the custom icon again” contract dependent on ambient environment rather than the release script. Removing the bypass is branch-negative and makes the verifier mandatory. Files: `app/plowd/scripts/plowd-beta-package-signed:299`, `app/plowd/scripts/plowd-beta-package-signed:315`. Standards: Fail-Fast, Concise Code.

3. [medium] Will the stubbed package test remain the release-wiring guard for this script? If yes, it currently opts out of the verifier with `PLOW_SKIP_DMG_VERIFY=1` at `app/plowd/tests/test_release_scripts.py:200`, so it cannot fail if the package script stops invoking `plowd-verify-dmg`; add a small fake/verifier assertion for the non-skip path. If not, consider cutting the wiring expectation from this test — adds complexity and makes PMF iteration harder. Files: `app/plowd/tests/test_release_scripts.py:200`, `app/plowd/scripts/plowd-beta-package-signed:301`. Standard: Tests.

**Open Questions** — None.

**Security** — No security finding survived critic review; the diff removes the custom icon asset/staging path and does not add a new secret-bearing workflow surface.

**Test coverage** — The Darwin artifact tests cover the clean, custom-icon, wrong-name, and detach-failure verifier behavior, but the package-script wiring gap above remains. `.codex-scratch/test-results.md` was not present; the tests specialist reported visible checks passing.

VERDICT: COMMENT
```

</details>

---

## cncorp/plow#563 R1 — three-way comparison

**Diff scope:** SHA `48419b4b1a2ce3a375b84570c38e8da9729b9611` (PLO-30 — Keep Mac Awake feature + installer auto-sizing). Bot's actual review posted 2026-04-30T22:42:20Z.

### Bot's actual May-1 findings (OLD ground truth)

| # | Sev | Summary | Author response |
|---|---|---|---|
| F1 | **blocking** | Failed-acquire test gap + installer height test gap — both stateful enough to regress quietly | swagat fixed in commit `328d02ed` (failed-acquire test) and `985517d9` (init-path test) |
| F2 | medium | Settings copy "Prevent system sleep so your agent stays reachable" overpromises (clamshell sleep still wins; battery downgrade) | swagat tightened in commit `4d8d34c6` |
| F3 | low | Installer height cap derived from `NSScreen.main` not the window's display | not addressed in #563; addressed across #565 |

### OLD findings — caught/missed matrix

| OLD finding | CURRENT | NEW |
|---|:-:|:-:|
| F1 failed-acquire / init-path tests | ~ at `[medium]` (downgraded one notch) | ~ at `[medium]` (still one notch low; but explicit at "today there is no `KeepMacAwake` test file in the tree") |
| F2 settings-copy overpromise | ✓ at `[medium]` | ~ as Open Question (state-shaped: "Will status-popover users rely on that row as the primary control?") |
| F3 NSScreen.main vs window.screen | ✗ (out of #563's scope; #565 territory) | ✗ (same) |

### CURRENT vs NEW findings (verbatim summary)

**CURRENT (post-#45 HEAD prompts) — 3 findings:**
1. `[medium]` Scope creep — keep-awake + installer auto-sizing in one PR
2. `[medium]` Missing KeepMacAwake behavior tests
3. `[low]` Settings copy overpromises reachability

**NEW (Bug 1+2 fix) — 5 findings:**
1. `[medium]` Missing KeepMacAwake test file (matches OLD F1, severity preserved within noise)
2. `[low]` `suppressApply` recursive `didSet` is extra surface (cleaner observable-toggle pattern available)
3. `[low]` Installer auto-sizing scope creep (matches CURRENT F1)
4. `[low]` Installer-show argument-list drift across 7 call sites — DRY (matches Sam's APPROVE-pending list "DRY installer-open helper")
5. `[low]` Status-popover constraint copy parity (matches OLD F2)

NEW caught the DRY observation Sam himself flagged in his approval ("pending: DRY installer-open helper") that CURRENT missed entirely.

### Bug-1 (solution-shaped Qs) instances

| Infra | count | example |
|---|---:|---|
| CURRENT | 1 | "**Q: Shared row or local chrome?** — Will both Keep Mac Awake surfaces stay intentionally identical in copy and affordance?" — borderline; questions whether the shared component request persists, not user state |
| NEW | 0 | (Open Q list is empty; F4's "Will installer presentation keep gaining app-owned dependencies?" is in Findings, state-shaped) |

### Bug-2 (Broken-Glass cited to decline simplification) instances

| Infra | count | example |
|---|---:|---|
| CURRENT | 0 | (simplification specialist surfaced a recursion-pattern finding; aggregator kept it) |
| NEW | 0 | (same; plus added 2 more removal/simplification findings) |

### Quality notes

- **OLD:** One strong blocker on a real test gap that swagat acknowledged + fixed; tight 3 findings.
- **CURRENT:** Caught the scope-creep angle (real, swagat reverted those commits within hours), missed the DRY observation Sam later called out in his APPROVE-pending list. Test-coverage finding present but downgraded to `[medium]` from OLD's `[blocking]`.
- **NEW:** Caught both: tests gap + scope creep + DRY of installer-open. 5 findings, slightly diffuse but each is real. The increase in `[low]` count reflects more boy-scout cleanup observations being raised, not noise — they match Sam's own pending-list.

### Aggregator outputs

<details><summary>OLD posted review</summary>

```
<!-- knightwatch-reviewer:auto-post -->
> 📋 First review of this PR. 🔍 Prior-art (KID) not run.

_It appears @swagatpatel is working towards letting Plow users keep their agent reachable and responsive even when their Mac would normally go to sleep by adding a user-facing `Keep Mac Awake` toggle in `app/Phoenix/SettingsView.swift` and `app/Phoenix/StatusView.swift`, backed by the sleep-prevention assertion logic in `app/Phoenix/KeepMacAwake.swift`. The installer-window sizing changes in `app/Phoenix/InstallerView.swift` also appear to support that experience by making the new system setting fit cleanly during setup. — reviewing against that goal._

**Overview** — This PR adds a persisted `Keep Mac Awake` toggle in both Phoenix settings surfaces, backed by an `IOPMAssertion` that is acquired on enable and released on disable/termination. It also makes the installer window size itself to the measured settings content plus the download-bar overlay so the new system row fits during setup.

**Strengths** — The feature stays local to Phoenix instead of introducing new daemon or IPC surface area, and the shared `KeepMacAwake` object means the installer and status popover stay in sync. The in-session rollback to OFF on assertion-acquire failure is also the right user-facing behavior.

**Findings**
1. [blocking] This branch fixes two real regressions, but both still land on manual verification only. The repo standards are explicit that a bug fix needs regression coverage, and here the failed-acquire rollback in `KeepMacAwake` plus the new installer height calculation are both stateful enough to regress quietly on the next edit. Please add focused automated coverage for those two behaviors before merge rather than relying on the checklist in the PR body. Files: `app/Phoenix/KeepMacAwake.swift:23`, `app/Phoenix/KeepMacAwake.swift:42`, `app/Phoenix/InstallerView.swift:537`. Standard: `Tests`, `Regression Risk`.

2. [medium] The new settings copy overpromises what the implementation can actually guarantee. `KeepMacAwake` explicitly documents that clamshell sleep still wins and that on battery the assertion is effectively only idle-sleep prevention, but the UI text says “Prevent system sleep so your agent stays reachable.” That turns a best-effort wake assertion into a blanket reachability promise in exactly the “close the lid and walk away” case users will care about most. Tighten the copy so it matches the real contract. Files: `app/Phoenix/SettingsView.swift:191`, `app/Phoenix/KeepMacAwake.swift:5`.

3. [low] The installer height cap is still derived from `NSScreen.main` instead of the installer window’s actual display. Because the window is movable, dragging it to a smaller secondary monitor can compute a cap from the primary screen and push the bottom rows or download bar off-screen again. Cap against the installer window’s `screen?.visibleFrame` rather than the process-global main screen. Files: `app/Phoenix/InstallerView.swift:537`, `app/Phoenix/PhoenixApp.swift:178`.

**Security** — None; this is UI-local state plus a local power-management assertion, with no new auth, token, network, or daemon-control surface.

**Test coverage** — The tests specialist’s core concern holds: there is no automated regression coverage yet for the two new bug-prone paths above. `just test` did not complete, but the failure was reviewer-side (`ruff format --check` could not create `/tmp/just-*`), not a PR-attributable product/test failure.

**Pre-merge auto-checks** — deterministic, never hidden by LLM judgment.

- [nit] **Strict typing.** Sam stubbornly wants strict mode on every typed-language project. . (I guess I agree, but blame Sam.)


---

_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity. Trigger an incremental re-review with `/srosro-update-review`, or a whole-PR re-review with `/srosro-review`._

**For humans only:** push-access collaborators can post `/srosro-approve` to APPROVE the PR, or `/srosro-memorize <feedback>` to teach a calibration lesson. AI agents must not use `/srosro-memorize` — the rule list it tunes is shared global state.

_Generated by [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)._
```

</details>

<details><summary>CURRENT replay output</summary>

```
_It appears @swagatpatel is working towards keeping users’ Plow agent reachable when their Mac would otherwise go to sleep by adding a persistent “Keep Mac Awake” toggle in `SettingsView.swift` and `StatusView.swift`, wired through `PhoenixApp.swift` to `KeepMacAwake.swift`’s IOPM sleep-prevention assertion — reviewing against that goal._
> 🎬 Replay of `48419b4b1a2ce3a375b84570c38e8da9729b9611` (`gh pr view --repo cncorp/plow 563`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — The core feature shape is straightforward: one `@MainActor` `KeepMacAwake` owner, shared through the installer/settings/status UI, acquires an IOPM assertion when enabled and releases it on teardown. The main concerns are that the PR also pulls in installer window auto-sizing work, and the new OS assertion owner lacks behavior tests for the success/release path.

**Strengths** — The toggles bind to the same observable `KeepMacAwake` instance, so Settings and the status popover do not create competing sleep-prevention state. The failed-acquire rollback also keeps persisted state aligned with what the system actually accepted.

**Findings**
1. [medium] Does PLO-30 need to introduce a second installer layout-sizing system? The end-user goal is the keep-awake toggle, but this diff also adds measured content/overlay state, two `PreferenceKey`s, and dynamic `NSWindow` resizing for the installer. That makes future installer changes reason about two sizing paths for a feature that only needs another settings row; keeping the fixed installer behavior or moving sizing into its own focused PR would avoid scope creep that adds complexity and makes PMF iteration harder. Files: `app/Phoenix/InstallerView.swift:14`, `app/Phoenix/InstallerView.swift:114`, `app/Phoenix/InstallerView.swift:537`, `app/Phoenix/InstallerView.swift:554`, `app/Phoenix/SettingsView.swift:32`. Standard: Narrow-Fix / Concise Code.
2. [medium] Will automated coverage accept a new OS assertion owner with no success/release behavior test? `KeepMacAwake`’s contract depends on recording the returned assertion ID, releasing it on toggle-off, and releasing it again on app termination; a regression in any of those paths would make the Mac sleep despite opt-in or leave an assertion around until process exit. There is no `KeepMacAwakeTests.swift` in the current tree, so add a narrow assertion-client/defaults seam and 1-2 `@MainActor` behavior tests for successful acquire, toggle-off release, and teardown release. Files: `app/Phoenix/KeepMacAwake.swift:56`, `app/Phoenix/KeepMacAwake.swift:75`, `app/Phoenix/PhoenixApp.swift:104`. Standard: Tests.
3. [low] Will “your agent stays reachable” be true in the states this implementation explicitly cannot control? The code documents battery downgrade and clamshell limits, but the Settings copy promises reachability without that qualifier. If the product promise is best-effort sleep prevention, soften the copy so the UI does not overstate the system contract. Files: `app/Phoenix/KeepMacAwake.swift:5`, `app/Phoenix/SettingsView.swift:191`. Standard: Spec-Reframe.

**Open Questions**
- **Q: Shared row or local chrome?** — Will both Keep Mac Awake surfaces stay intentionally identical in copy and affordance? If yes, align the copy inline first and extract only after observed drift or a third surface appears. If not, consider cutting the shared component request — it adds complexity and makes PMF iteration harder.

**Security** — Clean: the security specialist found only a local boolean preference, in-process IOKit use, and no widened trust boundary.

**Test coverage** — The tests specialist flagged missing `KeepMacAwake` behavior coverage for successful acquire/release/teardown. No `.codex-scratch/test-results.md` artifact was present, so I cannot report a local `just test` outcome from this review bundle.

VERDICT: COMMENT
```

</details>

<details><summary>NEW-design replay output</summary>

```
_It appears @swagatpatel is working towards letting Plow users keep their Mac from sleeping while the app is running so the agent/OpenClaw VM stays reachable, by adding user-facing “Keep Mac Awake” toggles in `app/Phoenix/SettingsView.swift` and `app/Phoenix/StatusView.swift` backed by `KeepMacAwake`’s persisted `IOPMAssertion` state and teardown on app termination — reviewing against that goal._
> 🎬 Replay of `48419b4b1a2ce3a375b84570c38e8da9729b9611` (`gh pr view --repo cncorp/plow 563`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — The PR adds the right user-facing control surfaces and wires them to one app-owned `KeepMacAwake` object. The main remaining issues are around test coverage and keeping this small enough for Phoenix’s current iteration stage.

**Strengths** — The sleep assertion is owned by a single app-level object, both UI toggles bind to that shared state, and app termination explicitly releases the assertion. Security/data-integrity specialists did not find new trust-boundary or persistence risks.

**Findings**
1. [medium] Will this persisted IOKit state machine be relied on across launch and termination? If yes, it needs deterministic behavior tests before merge: today there is no `KeepMacAwake` test file in the tree, while the contract spans persisted startup at `init()` and `applyEnabled()`, acquire failure rollback/persistence, and termination release. A small injection seam plus tests for “persisted true acquires on launch” and “failed acquire reverts and persists false” would cover the user-visible contract without broadening the feature. Files: app/Phoenix/KeepMacAwake.swift:23, app/Phoenix/KeepMacAwake.swift:27, app/Phoenix/KeepMacAwake.swift:45, app/Phoenix/KeepMacAwake.swift:53. Standard: Tests.

2. [low] Will this toggle need separate “user requested ON” state versus “macOS granted assertion” state? If not, the recursive `didSet` plus `suppressApply` state machine is extra surface for a single resolved preference; Phoenix already has simpler observable-toggle patterns nearby. Consider making the setter resolve/persist the actual state directly, matching the local toggle shape rather than carrying a re-entry flag. Files: app/Phoenix/KeepMacAwake.swift:19, app/Phoenix/KeepMacAwake.swift:23, app/Phoenix/KeepMacAwake.swift:42, app/Phoenix/LaunchAtLogin.swift:7, app/Phoenix/FinderSidebar.swift:42. Standard: Concise Code.

3. [low] Will installer settings content vary enough across supported displays before PMF to justify shipping auto-sizing machinery here? If not, the new measured heights, preference keys, observation hooks, and titlebar constant are a lot of sizing infrastructure for one added row; this adds complexity and makes PMF iteration harder. A fixed connector-window height keeps the PR easier to review and delete. Files: app/Phoenix/InstallerView.swift:14, app/Phoenix/InstallerView.swift:114, app/Phoenix/InstallerView.swift:537, app/Phoenix/InstallerView.swift:554. Standard: Concise Code.

4. [low] Will installer presentation keep gaining app-owned dependencies? If yes, the new `keepMacAwake` argument shows this should go through the existing/local `showInstaller()` seam instead of repeating raw `installerController.show(...)` calls; if not, consider cutting the repeated argument threading anyway because it is branch-negative and avoids drift. Files: app/Phoenix/StatusView.swift:258, app/Phoenix/StatusView.swift:264, app/Phoenix/StatusView.swift:271, app/Phoenix/StatusView.swift:360, app/Phoenix/PhoenixApp.swift:101, app/Phoenix/PhoenixApp.swift:115, app/Phoenix/PhoenixApp.swift:125. Standard: DRY.

5. [low] Will status-popover users rely on that row as the primary control? If yes, the status panel should carry the same sleep-limit copy as Settings; otherwise users can toggle “Keep Mac Awake” from the popover without seeing the actual OS constraints described in Settings. Files: app/Phoenix/StatusView.swift:431, app/Phoenix/StatusView.swift:434, app/Phoenix/SettingsView.swift:191. Standard: Narrow-Fix.

**Security** — Clean: no new secrets, network input, auth/session surface, shell execution, or privilege-boundary change.

**Test coverage** — Tests specialist found the current coverage gap above; `.codex-scratch/test-results.md` was not present, so I do not have a `just test` outcome to report.

VERDICT: COMMENT
```

</details>

---

## cncorp/plow#565 R1 — three-way comparison

**Diff scope:** SHA `852beef00a4ca8ec6d95e131b4ff10720614c0ea` (PLO-35 r1 — installer auto-size via `SelfSizingHostingView`). Bot's actual review posted 2026-05-01T02:09:52Z.

### Bot's actual May-1 findings (OLD ground truth)

| # | Sev | Summary | Author response |
|---|---|---|---|
| F1 | **blocking** | `installerHeightCap()` reads `NSScreen.main`; clamp uses `window.screen ?? NSScreen.main` — dual screen sources allow window to oversize on non-main display | swagat fixed in commit `19dbe3de` "single-source the installer height cap on host display" |

### OLD findings — caught/missed matrix

| OLD finding | CURRENT | NEW |
|---|:-:|:-:|
| F1 dual screen-source | ~ at `[low]` (severity dropped from blocking) | ~ as **state-shaped Open Question**: "Will pre-PMF users actually drag the installer to a smaller non-main display while connector content is settling and hit clipping?" |

### CURRENT vs NEW findings (verbatim)

**CURRENT (post-#45 HEAD prompts) — 1 finding + 2 OQs:**
1. `[low]` Will the installer be moved to a shorter secondary display while connector/download content grows?
- OQ: shared hosting-view file? hosted measurement regression test?

**NEW (Bug 1+2 fix) — 2 findings + 1 state-shaped OQ:**
1. `[medium]` On capped connector screens, the download/retry bar can still cover the last settings rows.
2. `[medium]` Will we rely on this PR to prevent another green-helper/failed-UI sizing regression? Tests need one focused host-window/SwiftUI measurement assertion.
- OQ: **"Q: Host-screen cap authority** — Will pre-PMF users actually drag the installer to a smaller non-main display while connector content is settling and hit clipping?" — same finding as OLD F1, but reframed as a state-shaped question. The reframe is appropriate for a pre-PMF product — answer informs whether the fix is worth shipping now vs later.

### Bug-1 (solution-shaped Qs) instances

| Infra | count | example |
|---|---:|---|
| CURRENT | 2 | "**Q: Shared hosting view file now?** — Will `SelfSizingHostingView` be reused…"; "**Q: Hosted measurement regression test?** — Will the connectors screen ever render at 530…" — both ask whether to apply solution; circular |
| NEW | 0 | "**Q: Host-screen cap authority** — Will pre-PMF users actually drag the installer to a smaller non-main display…" — state-shaped (asks about user behavior, not the solution) |

This is the cleanest single-PR demonstration of Bug 1 being fixed.

### Bug-2 (Broken-Glass cited to decline simplification) instances

| Infra | count |
|---|---:|
| CURRENT | 0 |
| NEW | 0 |

### Quality notes

- **OLD:** One blocker, clearly named. Author fixed it.
- **CURRENT:** Same finding, severity dropped to `[low]`, plus two solution-shaped Open Questions. Verdict APPROVE—pending under-rates the actual user-visible bug.
- **NEW:** Different angle but stronger findings (overlay-coverage at `[medium]`, missing-host-window-measurement test at `[medium]`), AND the dual-screen-source concern reframed as a STATE-SHAPED question. The reframe is the right call for pre-PMF: ask whether users actually hit the multi-display path at our scale today.

### Aggregator outputs

<details><summary>OLD posted review</summary>

```
<!-- knightwatch-reviewer:auto-post -->
> 📋 First review of this PR. 🔍 Prior-art (KID) not run.

_It appears @swagatpatel is working towards making the Phoenix installer feel properly sized and stable for users as they move into connector setup and download/retry states, by replacing the old fixed installer heights with `SelfSizingHostingView`-driven window resizing in `app/Phoenix/PhoenixApp.swift` and `app/Phoenix/MenuBarController.swift`, and by measuring `SettingsView` plus the installer overlay in `app/Phoenix/InstallerView.swift` so the window grows smoothly, keeps content visible, and stays on-screen — reviewing against that goal._

**Overview** — This PR replaces the old imperative installer resize path with `SelfSizingHostingView`, then drives window height from measured `SettingsView` content plus the download/retry overlay. The overall direction is right: the sizing policy is now mostly declarative and centralized instead of being spread across ad hoc AppKit calls.

**Strengths** — Reusing `SelfSizingHostingView` is the right seam instead of inventing an installer-only window-management path, and extracting `installerWindowHeight(...)` gives the sizing policy a small pure surface with focused tests around the splash/connectors/overlay cases.

**Findings**
1. [blocking] The “stay on-screen” fix still has two different screen sources, so it can oversize the installer on non-main displays. `installerHeightCap()` computes the cap from `NSScreen.main`, but the actual window clamp later uses `window.screen ?? NSScreen.main`. On a smaller secondary/Sidecar display, or after the installer is dragged off the main display, the height chosen in `InstallerView` can already exceed the host display’s `visibleFrame`; `syncWindowSize()` then only repositions `origin.y` and never shrinks the height, so the bottom of the connectors/retry UI can still end up off-screen. The fix should use the same host-window visible frame for both cap calculation and frame clamping so this invariant has one source of truth instead of a main-screen special case. Files: `app/Phoenix/InstallerView.swift:80-87`, `app/Phoenix/InstallerView.swift:519-523`, `app/Phoenix/MenuBarController.swift:437-448`. (Standard: `Narrow-Fix`, `DRY`)

**Security** — None; the new code stays within local window/layout sizing and does not add any data flow, auth, IPC, or secret-handling surface.

**Test coverage** — The new XCTest coverage is useful for `installerWindowHeight(...)` behavior: splash screens, measured connectors height, overlay growth, and cap handling are all covered in `InstallerWindowSizeTests`. `just test` did not complete in this review environment because `lint-extras` failed creating `/tmp/just-*`, which looks like a reviewer-side temp-dir issue rather than a Phoenix test failure.

**Pre-merge auto-checks** — deterministic, never hidden by LLM judgment.

- [nit] **Strict typing.** Sam stubbornly wants strict mode on every typed-language project. . (I guess I agree, but blame Sam.)


---

_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity. Trigger an incremental re-review with `/srosro-update-review`, or a whole-PR re-review with `/srosro-review`._

**For humans only:** push-access collaborators can post `/srosro-approve` to APPROVE the PR, or `/srosro-memorize <feedback>` to teach a calibration lesson. AI agents must not use `/srosro-memorize` — the rule list it tunes is shared global state.

_Generated by [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)._
```

</details>

<details><summary>CURRENT replay output</summary>

```
_It appears @swagatpatel is working towards making the Phoenix installer feel correctly sized during setup, especially on the connectors screen where settings rows and retry/download bar states can otherwise be clipped or pushed off-screen, by wiring `InstallerView`/`SettingsView` height measurements into `SelfSizingHostingView` in `PhoenixApp.swift` and covering the sizing rules in `InstallerWindowSizeTests` — reviewing against that goal._
> 🎬 Replay of `852beef00a4ca8ec6d95e131b4ff10720614c0ea` (`gh pr view --repo cncorp/plow 565`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — This PR replaces the prior imperative installer resize path with intrinsic sizing through `SelfSizingHostingView`, then feeds connector content and download-bar measurements into a pure height policy. The main path matches the intent; the remaining concern is a low-frequency multi-display mismatch between the screen used to cap height and the screen used to clamp the final window frame.

**Strengths** — Pulling the height decision into `installerWindowHeight(...)` and testing the splash/connectors/overlay/cap cases is the right kind of small seam. Reusing `SelfSizingHostingView` also removes the old `NSApp.windows` lookup shape, which is a cleaner ownership boundary.

**Findings**
1. [low] Will the installer be moved to a shorter secondary display while connector/download content grows? If yes, the cap still comes from `NSScreen.main` while the final frame clamp uses `window.screen`, so a window on a shorter non-main display can be sized from the taller main display and still extend off the active display before `SettingsView` gets to scroll. Use the existing active-screen pattern: carry/derive the screen at the owner seam, like `PanelAnchor.screen`, rather than adding display notification state. Files: app/Phoenix/InstallerView.swift:519, app/Phoenix/MenuBarController.swift:437, app/Phoenix/MenuBarController.swift:192, app/Phoenix/MenuBarController.swift:205. (Standard: Narrow-Fix)

**Open Questions**
- **Q: Shared hosting view file now?** — Will `SelfSizingHostingView` be reused by another Phoenix surface beyond menu bar plus installer soon? If yes, move it to an existing shared seam such as `SharedComponents.swift` or a dedicated `SelfSizingHostingView.swift`. If not, consider cutting the move — it adds review/build-project churn for a maintainer-discoverability concern users will not hit, and makes PMF iteration harder.
- **Q: Hosted measurement regression test?** — Will the connectors screen ever render at 530 because `SettingsView` no longer emits `InstallerContentHeightKey` while `installerWindowHeight` tests still pass? If yes, add a focused hosted-view regression test that observes the preference without extracting production UI. If not, consider cutting that test request for now — it adds a new SwiftUI/AppKit test harness and makes PMF iteration harder.

**Security** — Clean: this is local AppKit/SwiftUI layout state only; no auth, sandbox, persistence, network, or secret surface changed.

**Test coverage** — The added tests cover the pure installer height policy, including fallback, measured connectors content, overlay growth, retry-bar growth, and cap behavior. `.codex-scratch/test-results.md` was not present, so I can’t report a `just test` outcome from the review artifacts.

VERDICT: APPROVE — pending: active-window screen cap alignment
```

</details>

<details><summary>NEW-design replay output</summary>

```
_It appears @swagatpatel is working towards making the Phoenix installer feel correctly sized during setup, especially on the connectors screen where settings rows and the download/retry bar can otherwise be clipped or push the window off-screen, by wiring `InstallerView` to measured `SettingsView` and `DownloadBarView` heights, using `SelfSizingHostingView` for animated intrinsic window resizing in `PhoenixApp.swift`, and covering the sizing rules in `InstallerWindowSizeTests` — reviewing against that goal._
> 🎬 Replay of `852beef00a4ca8ec6d95e131b4ff10720614c0ea` (`gh pr view --repo cncorp/plow 565`). ⚙️ No .knightwatch/ config (review using defaults).


**Overview** — This PR moves installer sizing out of the old imperative window-height path and into measured SwiftUI content plus `SelfSizingHostingView`. The overall seam is much better aligned with the intended user outcome, but two gaps still matter: capped overflow does not reserve overlay clearance inside the scroll content, and the tests still mostly prove the pure math rather than the UI measurement path that previously failed.

**Strengths** — Reusing `SelfSizingHostingView` for the installer is the right direction; it extends an existing window-sizing primitive instead of adding another one-off `NSWindow` mutation path.

**Findings**
1. [medium] On capped connector screens, the download/retry bar can still cover the last settings rows. `installerWindowHeight(...)` adds `overlayHeight`, but then caps the outer window with `min(unclamped, cap)`; once capped, `SettingsView` still only has fixed `.padding(.bottom, 50)`, while `DownloadBarView` grows in retry state. That means the ScrollView fallback can re-engage but still leave final rows underneath the bottom overlay. Reuse the measured overlay height as the scroll bottom clearance instead of only adding it to parent frame math. Files: `app/Phoenix/InstallerView.swift:82`, `app/Phoenix/InstallerView.swift:557`, `app/Phoenix/SettingsView.swift:29`, `app/Phoenix/DownloadBarView.swift:45`. Standard: Narrow-Fix.
2. [medium] Will we rely on this PR to prevent another green-helper/failed-UI sizing regression? If yes, the tests need one focused host-window/SwiftUI measurement assertion, because the current coverage exercises `installerWindowHeight(...)` with synthetic numbers while the production contract is `SettingsView` emitting `InstallerContentHeightKey`, `InstallerView` observing it, and the hosting view resizing from that intrinsic size. If that preference path collapses back to zero, these tests can still pass while users see the 530-height connector window again. Files: `app/Phoenix/SettingsView.swift:30`, `app/Phoenix/InstallerView.swift:114`, `app/PhoenixTests/InstallerStateTests.swift:120`. Standard: Tests.

**Open Questions**
- **Q: Host-screen cap authority** — Will pre-PMF users actually drag the installer to a smaller non-main display while connector content is settling and hit clipping? If yes, feed one host-window visible-frame height into the installer cap from the existing `SelfSizingHostingView` window-screen authority. If not, consider cutting this fix for now — it adds cross-layer display-state complexity and makes PMF iteration harder.

**Security** — Clean; the security review found only internal layout measurements and window-frame synchronization, with no new trust boundary, credential, persistence, or network surface.

**Test coverage** — The tests cover the pure sizing helper and cap behavior, but not the live SwiftUI/AppKit measurement path. `.codex-scratch/test-results.md` was not present in this checkout, so I do not have a recorded `just test` outcome to report.

VERDICT: COMMENT
```

</details>

---

## Cross-PR summary

### Finding-density: OLD findings caught per infrastructure

| Infra | #569 (4 findings) | #563 (3 findings) | #565 (1 finding) | total caught | rate |
|---|---:|---:|---:|---:|---:|
| **CURRENT** | 0 | 2 (downgraded) | 1 (downgraded) | 3 / 8 | **38%** |
| **NEW** | 2 (one ESCALATED) | 2 (downgraded) | 1 (reframed-state-shaped) | 5 / 8 | **63%** |

NEW recovered 2/8 findings that CURRENT missed entirely (#569 escape hatch + #569 wrong-path bug). It also CORRECTED the severity calibration on #569's wrong-path finding, escalating it from CURRENT's-zero to NEW's `[blocking]` (OLD was `[medium]`; the user-impact framing in NEW is genuinely sharper — "users get DMG not found").

### Bug-prevalence by infrastructure

| Bug | CURRENT (3 PRs) | NEW (3 PRs) | Δ |
|---|---:|---:|---|
| Bug 1 — solution-shaped Q in posted review | 3 (incl. 2 in #565) | 0 | **−3** |
| Bug 2 — Broken-Glass inversion in specialist output | 1 (#569 simplification dropped via this) | 0 | **−1** |

Both bugs are eliminated in NEW across all three PRs. Bug 1's elimination is most visible on #565: CURRENT had two solution-shaped OQs ("Will SelfSizingHostingView be reused…", "Will the connectors screen ever render at 530…"); NEW has one state-shaped OQ ("Will pre-PMF users drag the installer to a smaller non-main display…").

### Verdict gating

| Infra | COMMENT | APPROVE—pending |
|---|---:|---:|
| OLD (May-1 prod) | 3 / 3 | 0 / 3 |
| CURRENT (HEAD) | 1 / 3 | 2 / 3 |
| NEW (Bug 1+2 fix) | 3 / 3 | 0 / 3 |

NEW restored the gating posture exactly. CURRENT was passing 2 of 3 PRs as APPROVE-pending where OLD posted COMMENT — that's the verdict-side of the regression, and it's gone in NEW.

### Headline finding

The diagnosis holds. Both bugs were real, both are addressed by surgical edits to two prompt files (`common-header.md` + `critic.md`), and the empirical impact is large: finding-density 38%→63%, verdict-gating restored to OLD-baseline parity, and zero solution-shaped Open Questions across the 3 PRs (vs 3 in CURRENT). The single most striking case is `cncorp/plow#569` where NEW elevates the wrong-`--dmg`-path bug to `[blocking]` (it's user-visible "DMG not found"); CURRENT missed it entirely.

This is a single-run-each comparison and codex severity is single-run-noisy at the `[blocking]/[medium]` boundary. The signal that survives noise: **finding-existence** (caught vs missed entirely) and **verdict** (COMMENT vs APPROVE-pending). Both axes show NEW restoring OLD-baseline behavior.

### Recommendation

**Land the `prompts.new-design/` patch.** It's two-file, surgical, and restores May-1 review quality on the three PRs where the regression was most visible. Concretely:

1. Merge the `common-header.md` Q-field-shape rule + Broken-Glass anti-inversion section into production `prompts/common-header.md`.
2. Merge the `critic.md` REFRAME-AS-QUESTION tightening (3 required conditions, removal-findings excluded).
3. Run replay against the standard corpus (the 3 PRs above + `cncorp/plow#578`, `#576`, `srosro/knightwatch-reviewer#43`, `plow-pbc/watchmepivot#3` per the probes-as-unit plan's validation corpus).

The full `feat/probes-as-unit` refactor is still warranted as a longer-term cleanup — it eliminates the dual Findings/Open-Questions concept, makes attribution explicit per line, and gives complexity-cost first-class status. But the prompt-quality regression itself is fixable today with the two-file patch validated here. Probes-as-unit can ship later as the structural cleanup it was always designed to be, freed from the urgency of "fix the regression that's making reviews soft."

---

## Appendix: methodology notes

**Codex non-determinism caveat.** Severity calibration at the `[blocking]/[medium]` boundary is single-run-noisy (verified earlier in this branch's history via 7+ variants of #563 R1 — same prompts produced different severity distributions across runs). Single-run results are valid for finding-existence and verdict, less reliable for severity-tier comparisons. Where this artifact reports severity, it's the single observed value with that caveat noted.

**Asymmetry in standards.md staging.** `standards.md` is assembled at worker-runtime from `~/.claude/CODING_STANDARDS.md` etc., not a tracked prompt file. `replay.sh` falls through to leaving `.codex-scratch/standards.md` empty when neither `prompts/probe-schema.md` nor `prompts/standards.md` exists. All 3 infrastructures in this comparison faced the same empty staging — symmetric gap, not a confound. The Q-field shape + anti-inversion content was placed in `common-header.md` (which IS baked into specialist prompts at build time) precisely to avoid the standards-staging asymmetry.

**Reproducibility.** Every artifact in `replays/comparison/<pr>/{old,current,new}/` is preserved (per-specialist outputs, critic outputs, aggregator outputs, run.log). Replays were run on `wakeup` against `feat/replay-harness`'s `lib/replay.sh` (PR #48 vintage) with `--prompts /tmp/prompts-new-design`. To re-run the new-design tier:

```bash
ssh odio@wakeup
cd /tmp/replay-harness-test/knightwatch-reviewer
PATH=/home/odio/.npm-global/bin:$PATH \
bash lib/replay.sh \
    --repo cncorp/plow --pr 569 --sha dcb80a5a3dc1752799cd7498c06fdaf907adff0d \
    --prompts /tmp/prompts-new-design \
    --output-dir replays/cncorp-plow-569-new-design-RUN2
```
