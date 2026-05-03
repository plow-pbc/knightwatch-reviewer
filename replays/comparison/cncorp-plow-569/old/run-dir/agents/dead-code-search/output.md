## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `plowd-beta-package-signed` at `app/plowd/scripts/plowd-beta-package-signed:7` (modified)
Old shape: `plowd-beta-package-signed [options]`; release flow required `app/plowd/dmg/volume.icns`, staged `.VolumeIcon.icns`, created UDRW DMG, wrote FinderInfo, then converted to ULFO.
New shape: same CLI options; no `volume.icns` requirement or `.VolumeIcon.icns` staging; creates ULFO directly; runs `plowd-verify-dmg --dmg <output>` unless `PLOW_SKIP_DMG_VERIFY=1`.
Callers found:
- `app/justfile:219` — matches new shape; invokes existing options only.
- `app/plowd/tests/test_release_scripts.py:209` — matches new shape; invokes existing options only.
- `docs/distribution/CODE_SIGNING.md:153` — matches new shape; documented invocation uses existing `--identity` option only.
Verdict: clean

### `app/plowd/dmg/volume.icns` at `app/plowd/dmg/volume.icns:1` (removed)
Old shape: source `.icns` asset consumed by `plowd-beta-package-signed` as `${dmg_assets_dir}/volume.icns`.
New shape: file removed; package script no longer defines or requires `dmg_volume_icon`.
Callers found:
- (none; grep for `volume.icns` across same repo and included sibling repos returned no hits)
Verdict: dead (zero callers)

### `.VolumeIcon.icns` DMG root payload at `app/plowd/scripts/plowd-beta-package-signed:205` (removed)
Old shape: package script staged `${stage_dir}/.VolumeIcon.icns`, so the final mounted DMG shipped a custom volume icon file.
New shape: package script omits `.VolumeIcon.icns`; `plowd-verify-dmg` rejects a mounted DMG if `.VolumeIcon.icns` exists.
Callers found:
- `app/plowd/scripts/plowd-verify-dmg:82` — matches new shape; production verifier treats `.VolumeIcon.icns` presence as invalid.
- `app/plowd/tests/test_release_scripts.py:250` — matches new shape; asserts staged source folder omits `.VolumeIcon.icns`.
- `app/plowd/tests/test_release_scripts.py:304` — matches new shape; regression fixture creates `.VolumeIcon.icns` only to assert verifier rejection.
Verdict: clean

## Unreachable conditionals

(none)