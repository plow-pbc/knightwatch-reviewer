## [data-integrity] findings

### Surveyed
- Release script removal of `.VolumeIcon.icns` staging and FinderInfo custom-icon write — clean; final verifier runs after stapling and before checksum/S3 upload.
- Direct `hdiutil create -format ULFO` path replacing UDRW/convert — clean; the script still mounts the produced DMG for app signature verification and aborts before upload on failure.
- `plowd-verify-dmg` mount lifecycle — clean; pre-mounted `/Volumes/Plow*` is rejected, success-path detach failure is fatal, and failure-path detach does not mask the original error.
- `just app dmg-verify` wrapper path semantics — see Finding 1.
- macOS CI plowd test addition for real `hdiutil` coverage — clean; it exercises the artifact guard on Darwin where the Linux lane skips it.
- Existing release-script output path convention — noted as pre-existing; the new verifier recipe repeats the same relative-path mismatch.

### Finding 1 — medium
`just app dmg-verify` defaults to `../.build/Plow.dmg`, but `plowd-verify-dmg` resolves every relative `--dmg` against `repo_root`, not the `app/` working directory. The supported command therefore checks `repo_root/../.build/Plow.dmg` instead of `repo_root/.build/Plow.dmg`, producing a false "DMG not found" or, worse, verifying a stale sibling artifact if that path exists. The release path passes an already-absolute output, so this is not blocking. The low-cost fix is branch-free: make the recipe default `.build/Plow.dmg` under the script’s repo-root convention.
Files: app/justfile:230, app/plowd/scripts/plowd-verify-dmg:37