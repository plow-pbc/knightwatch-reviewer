## [simplification] findings

### Surveyed
- Kid prior-art surface — clean; no reported hits to triage
- Direct ULFO DMG creation after dropping `.VolumeIcon.icns` staging — clean
- `plowd-verify-dmg` public command shape — clean
- Mounted Plow volume detection across release paths — see Finding 1
- Darwin-only artifact guard tests for icon and volume-name regressions — clean
- macOS CI plowd test wiring — clean

### Finding 1 — low
The same mounted-volume probe is now maintained in three places: the release recipe, `plowd-beta-package-signed`, and the new verifier. The regex/sort/error branch is small, but this PR adds another copy of the same release invariant instead of putting it in the existing `app/plowd/scripts/_lib.sh`; future changes to the accepted mount shape or error wording now have to be remembered in multiple places. Under `DRY` / `Concise Code`, the cheaper remedy is one shared shell helper such as `plowd_mounted_plow_volumes` or `plowd_ensure_no_mounted_plow_volume`, sourced by the two plowd scripts; leave the just recipe to call the packaged script’s check or use the same helper if sourced there.
Files: app/plowd/scripts/plowd-verify-dmg:46, app/plowd/scripts/plowd-beta-package-signed:124, app/justfile:206