## [consumers] findings

### Surveyed
- `app/plowd/scripts/plowd-beta-package-signed` release entrypoint — clean; existing callers still use the same script/options, and its verifier call matches the new positional CLI at `app/plowd/scripts/plowd-beta-package-signed:305`.
- `app/plowd/scripts/plowd-verify-dmg` new public verifier CLI — clean; internal callers use zero or one positional arg, matching `Usage: plowd-verify-dmg [<dmg-path>]` at `app/plowd/scripts/plowd-verify-dmg:8`.
- `just app dmg-verify` recipe — clean; it is a thin positional pass-through to the verifier at `app/justfile:232`.
- Removed `app/plowd/dmg/volume.icns` / `.VolumeIcon.icns` staging — clean; repo grep finds no production consumers, only verifier guards and regression tests.
- Checked-in `app/plowd/dmg/.DS_Store` packaging dependency plus `plowd-record-dmg-layout` authoring path — clean; the package script stages the asset at `app/plowd/scripts/plowd-beta-package-signed:217`, and the recorder writes the same destination at `app/plowd/scripts/plowd-record-dmg-layout:131`.
- CI `cd app/plowd && just test` consumer — clean; `app/plowd/justfile:37` exposes the `test` recipe used by the new macOS workflow step.