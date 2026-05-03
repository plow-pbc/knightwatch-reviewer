## [security] findings

### Surveyed
- Final DMG verification before S3 upload in `plowd-beta-package-signed` — clean
- `plowd-verify-dmg` argument handling, mount parsing, and cleanup path — clean
- Added macOS CI plowd test step — clean, no new secret-bearing workflow context
- Removal of custom volume icon staging/FinderInfo mutation — clean
- Checked-in and shipped Finder `.DS_Store` metadata capture — see Finding 1

### Finding 1 — low
`plowd-record-dmg-layout` copies Finder’s raw `.DS_Store` into the repo and release artifact, and the PR-head blob contains machine-local metadata visible via `strings`: `/private/tmp/plowd-dmg-record.../layout.dmg`, `Macintosh HD`, and volume UUIDs. That is unnecessary fingerprinting data in both the public repository and the shipped DMG. The low-cost remedy is data minimization around the recorded blob, not a defensive runtime branch: re-record/sanitize the metadata so only the layout contract remains. This is a Broken-Glass Test simplification-aligned fix because it removes accidental metadata without adding release-path complexity.
Files: app/plowd/scripts/plowd-record-dmg-layout:195, app/plowd/dmg/.DS_Store:1

---

## Critic counter-arguments

### [security] Finding 1 — FALSE POSITIVE
The cited recorder script is not present in this repo (`app/plowd/scripts/plowd-record-dmg-layout` is absent), and the diff does not add or copy `app/plowd/dmg/.DS_Store` into the staged DMG; `plowd-beta-package-signed` only copies `background.tiff` into `stage_dir` at `app/plowd/scripts/plowd-beta-package-signed:215-216`.


