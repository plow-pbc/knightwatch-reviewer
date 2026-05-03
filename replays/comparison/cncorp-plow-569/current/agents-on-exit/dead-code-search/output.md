## Static-tool candidates (verified)

(none — pre-pass had no tool output)

## Modified public symbols — caller analysis

### `app/plowd/scripts/plowd-beta-package-signed` at `app/plowd/scripts/plowd-beta-package-signed:7` (modified)
Old shape: executable release packager required `app/plowd/dmg/volume.icns`, staged `.VolumeIcon.icns`, created a writable `UDRW` DMG, set `com.apple.FinderInfo`, then converted to `ULFO`.
New shape: same CLI options; no volume icon asset dependency; creates `ULFO` directly; runs `app/plowd/scripts/plowd-verify-dmg --dmg "${output}"` unless `PLOW_SKIP_DMG_VERIFY=1`.
Callers found:
- `app/justfile:219` — matches new shape; invokes same script path with existing CLI args.
- `docs/distribution/CODE_SIGNING.md:153` — matches new shape; direct invocation still uses existing `--identity` arg.
- `app/plowd/tests/test_release_scripts.py:12` — test reference; matches same script path.
- `app/plowd/tests/test_runtime_distribution.py:11` — test reference; matches same script path.
Verdict: clean

### `app/plowd/dmg/volume.icns` at `.codex-scratch/diff.patch:36` (removed)
Old shape: tracked DMG volume icon asset, formerly consumed through `dmg_volume_icon="${dmg_assets_dir}/volume.icns"` and staged into `.VolumeIcon.icns`.
New shape: file removed; release packager no longer references `volume.icns` or `dmg_volume_icon`.
Callers found:
- `(none)` — `grep -rn "app/plowd/dmg/volume.icns\|volume.icns\|dmg_volume_icon"` found no non-diff references.
Verdict: dead (zero callers)

### `.VolumeIcon.icns` DMG root payload at `app/plowd/scripts/plowd-verify-dmg:82` (removed)
Old shape: release packager staged `.VolumeIcon.icns` into the DMG source folder, causing the final DMG to ship a custom volume icon.
New shape: release packager does not stage `.VolumeIcon.icns`; verifier rejects a mounted DMG if `.VolumeIcon.icns` exists.
Callers found:
- `app/plowd/scripts/plowd-verify-dmg:82` — matches new shape; absence guard rejects the removed payload.
- `app/plowd/tests/test_release_scripts.py:250` — matches new shape; asserts staged source folder does not contain `.VolumeIcon.icns`.
- `app/plowd/tests/test_release_scripts.py:304` — test-only regression setup creates `.VolumeIcon.icns` to verify rejection.
Verdict: dead (remaining refs are absence guards/tests, no consumers)

## Unreachable conditionals

(none)