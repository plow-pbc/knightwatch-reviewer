## [architecture] findings

### Surveyed
- Release flow boundary: `just app release` is the documented point that packages and uploads the versioned DMG — see Finding 1
- DMG staging path: custom `.VolumeIcon.icns` staging and UDRW custom-icon mutation are removed — clean
- Artifact verifier placement: verifier runs after staple and before S3 upload — see Finding 1
- macOS CI lane: plowd tests now run where real `hdiutil` exists — clean
- Deleted DMG volume icon asset: removes an orphaned release asset rather than adding another conditional path — clean

### Finding 1 — medium
The release verifier is not actually a single mandatory release contract because `PLOW_SKIP_DMG_VERIFY=1` skips it in the production packaging script. The documented release flow says `just app release` packages and uploads the versioned DMG (`docs/phoenix-sparkle-build.md:73`, `docs/vm-publish.md:208`), and this PR’s intent is to block releases that ship the confusing custom volume icon. But line 299 lets any inherited release environment bypass the guard, and the script still uploads at lines 315-316. Broken-Glass Test, Concise Code, and Fail-Fast all point the same way here: removing the env bypass reduces branch count and makes the verifier the one release path.
Files: app/plowd/scripts/plowd-beta-package-signed:299, app/plowd/scripts/plowd-beta-package-signed:315, docs/vm-publish.md:208