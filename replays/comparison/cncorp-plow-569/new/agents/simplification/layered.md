## [simplification] findings

### Surveyed
- Kid/prior-art surface — clean: `.codex-scratch/prior-art.md` is empty, so there were no score ≥ 0.75 hits to keep or dismiss.
- DMG packaging path in `plowd-beta-package-signed` — clean: the PR deletes the old UDRW/custom-icon staging path and creates ULFO directly.
- New `plowd-verify-dmg` script — see Finding 1
- New Darwin `hdiutil` tests — see Finding 2
- Existing release-script fake command table touched by this test module — see Finding 3
- `just app dmg-verify` wrapper and macOS CI step — clean: both are thin entrypoints without meaningful duplicated logic beyond invoking the verifier.

### Finding 1 — low
Will `hdiutil info` keep reporting mounted Plow volumes with the same `/Volumes/Plow( N)?` suffix across the macOS versions this release lane supports? If that OS contract is important enough to gate releases, carrying the same parser in three places makes future drift fixes harder than a single helper in `app/plowd/scripts/_lib.sh`. Broken-Glass Test and Concise Code favor collapsing this duplicate shell into one `plowd_mounted_plow_volumes` helper; the remedy cost is one sourced helper and fewer regex copies, not new branching.
Files: app/plowd/scripts/plowd-verify-dmg:46, app/plowd/scripts/plowd-beta-package-signed:124, app/justfile:206

### Finding 2 — low
Will macOS-only artifact guards keep expanding as release packaging changes before the release lane settles? These two new tests repeat the same “skip if Plow is mounted” preflight and real-DMG staging/creation setup, with only the scenario assertions changing. A module-level `_skip_if_plow_volume_mounted()` plus `_make_real_dmg(stage, path, volname)` would delete the repeated setup while keeping the test intent sharper; the remedy cost is two small helpers, no new conditionals or defensive behavior.
Files: app/plowd/tests/test_release_scripts.py:268, app/plowd/tests/test_release_scripts.py:278, app/plowd/tests/test_release_scripts.py:328, app/plowd/tests/test_release_scripts.py:338

### Finding 3 — nit
This touched test module still has a duplicate `generate_appcast` key in the fake command table, so the earlier entry is silently overwritten and `_fake_generate_appcast_script()` is dead code. Since this PR is already editing the release-script tests, deleting the first mapping and the unused helper is a zero-abstraction Concise Code cleanup that leaves the file easier to inspect.
Files: app/plowd/tests/test_release_scripts.py:865, app/plowd/tests/test_release_scripts.py:880, app/plowd/tests/test_release_scripts.py:933

---

## Critic counter-arguments

### [simplification] Finding 1 — REMEDY-BLOAT
Will this tiny `hdiutil info | grep -Eo '/Volumes/Plow( [0-9]+)?$'` shape drift often enough to justify sourcing shared shell across a just recipe and scripts? With no observed drift, extracting `_lib.sh` plumbing for three one-liners adds complexity and makes PMF iteration harder.

### [simplification] Finding 2 — REMEDY-BLOAT
Will these two Darwin-only tests expand into enough cases that helper indirection pays for itself? Right now the duplication is local test setup at `app/plowd/tests/test_release_scripts.py:268-338`; adding helpers for two tests is cleanup theater and adds complexity and makes PMF iteration harder.

### [simplification] Finding 3 — AGREE
Is cleanup in scope because this PR already touches the fake release command table? Yes: the duplicate `generate_appcast` key at `app/plowd/tests/test_release_scripts.py:865` and `:880` makes `_fake_generate_appcast_script()` at `:933` dead code; deletion is branch-negative.
**Estimated remedy LOC:** ~0 LOC across 1 file.


