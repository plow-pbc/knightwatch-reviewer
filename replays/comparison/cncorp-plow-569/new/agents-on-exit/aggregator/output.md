_It appears @swagatpatel is working towards making the Plow installer DMG mount with the default macOS volume icon while preserving the normal “Plow” volume name by removing `app/plowd/dmg/volume.icns`, stopping `plowd-beta-package-signed` from staging `.VolumeIcon.icns`/FinderInfo custom-icon metadata, and adding `app/plowd/scripts/plowd-verify-dmg` plus macOS CI coverage to block releases that ship the custom icon again — reviewing against that goal._

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