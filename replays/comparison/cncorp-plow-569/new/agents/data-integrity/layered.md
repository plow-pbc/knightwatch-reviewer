## [data-integrity] findings

### Surveyed
- Direct ULFO DMG creation and removal of `.VolumeIcon.icns` staging in the release path — clean
- Final PLO-29 verifier runs before checksum generation and S3 upload, so rejected artifacts do not publish — clean
- Success-path detach handling now fails loud instead of returning green with a leaked mount — clean
- Existing `/Volumes/Plow` collision preflight before packaging/verifying — clean for the intended `Plow` volume name
- Mount-path parsing from `hdiutil attach` output — see Finding 1
- Stubbed and real-`hdiutil` verifier coverage for clean, iconed, and wrong-name DMGs — clean

### Finding 1 — low
`plowd-verify-dmg` can leak a successfully attached regression DMG when the bad volume name contains spaces. The parser assumes the mount point is `$NF`; for `hdiutil attach` output ending `/Volumes/Plow Installer`, `$NF` is `Installer`, so `mounted_volume` stays empty and the script exits before cleanup has a path to detach. The release still aborts before upload, but repeated verification of a bad spaced-name DMG leaves stale mounts that the existing `/Volumes/Plow( [0-9]+)?` preflight does not report. Fix cost should stay small: one robust mount-path parser, not per-name exceptions.
Files: app/plowd/scripts/plowd-verify-dmg:89, app/plowd/scripts/plowd-verify-dmg:90

---

## Critic counter-arguments

### [data-integrity] Finding 1 — FALSE POSITIVE
The parser is not `$NF`; current code uses `sed -n 's|.*\(/Volumes/.*\)$|\1|p'` at `app/plowd/scripts/plowd-verify-dmg:76`, which preserves `/Volumes/Plow Installer` including spaces, so cleanup still has a mount path.


