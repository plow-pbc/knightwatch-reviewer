## [performance] findings

### Surveyed
- Direct ULFO DMG creation replacing UDRW create/attach/convert flow in `app/plowd/scripts/plowd-beta-package-signed` — clean; release-only path and it removes an extra image conversion.
- Post-staple `plowd-verify-dmg` mount check in the signed release script — clean; one additional `hdiutil attach` per release artifact, not request/user-scale work.
- `plowd-verify-dmg` implementation: `hdiutil info`, attach, basename check, `.VolumeIcon.icns` existence check, detach — clean; bounded filesystem work over one mounted volume.
- New `just app dmg-verify` target — clean; manual artifact validation, no runtime load.
- macOS CI addition running `app/plowd` tests after Swift tests — clean; CI-only cost and still within a single existing macOS job.
- Darwin-only tests that create clean/iconed/misnamed DMGs — clean; a few real `hdiutil create` calls in CI, no production scale concern.