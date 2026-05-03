## Static-tool candidates (verified)

(none — pre-pass had no tool output).

## Modified public symbols — caller analysis

### `plowd-beta-package-signed` at `app/plowd/scripts/plowd-beta-package-signed:7` (modified)
Old shape: `plowd-beta-package-signed [options]`; packaged DMG staging depended on custom volume icon asset and staged `.VolumeIcon.icns`.
New shape: `plowd-beta-package-signed [options]`; same CLI options, packages ULFO DMG without custom volume icon and verifies final DMG via `plowd-verify-dmg --dmg`.
Callers found:
- `app/justfile:219` — matches new shape; passes unchanged supported options.
- `docs/distribution/CODE_SIGNING.md:153` — matches new shape; direct call uses unchanged `--identity`.
- `app/plowd/tests/test_release_scripts.py:209` — matches new shape; test caller passes unchanged supported options.
Verdict: clean

### `app/plowd/dmg/volume.icns` at `app/plowd/dmg/volume.icns:1` (removed)
Old shape: custom DMG volume icon source asset consumed by release packaging.
New shape: asset removed; release packaging no longer references `volume.icns`.
Callers found:
- (none; same-repo grep for `volume.icns` / `dmg_volume_icon` found no remaining production consumers)
Verdict: dead (zero callers)

### `.VolumeIcon.icns` DMG root payload at `app/plowd/scripts/plowd-beta-package-signed:216` (removed)
Old shape: release packaging staged `${stage_dir}/.VolumeIcon.icns` into the DMG root.
New shape: release packaging does not stage `.VolumeIcon.icns`; verifier rejects final DMGs that contain it.
Callers found:
- `app/plowd/scripts/plowd-verify-dmg:82` — matches new shape; rejects old payload if present.
- `app/plowd/tests/test_release_scripts.py:250` — matches new shape; asserts staged source folder omits `.VolumeIcon.icns`.
- `app/plowd/tests/test_release_scripts.py:304` — test-of-itself fixture creates old payload to verify rejection.
Verdict: dead (zero callers expecting the removed payload)

## Unreachable conditionals

(none)