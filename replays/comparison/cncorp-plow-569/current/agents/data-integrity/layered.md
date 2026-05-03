## [data-integrity] findings

### Surveyed
- Final DMG creation changed from UDRW→convert to direct ULFO — clean; upload still happens only after create, attach/codesign verify, notarization, staple, and the new artifact check.
- `plowd-verify-dmg` mounted-volume lifecycle — clean; it refuses pre-existing `/Volumes/Plow*`, detaches on failure without masking the original error, and makes detach failure fatal on the success path.
- `.VolumeIcon.icns` removal from staging and final artifact verification — clean; the staged source no longer includes the icon and the shipping DMG is mounted before checksum/upload to assert the root icon is absent.
- Volume-name contract for the mounted DMG — clean; the verifier rejects any mounted name other than exactly `Plow`, avoiding silently shipping a renamed installer volume.
- Retry behavior after partial release failure — clean for this PR’s surface; failed verification occurs before checksum/S3 upload, and leaked successful mounts are treated as release failures rather than allowing a retry to proceed on polluted state.
- macOS-only CI coverage for real `hdiutil` paths — clean; the Darwin lane now runs plowd tests so the artifact-level verifier is not only exercised by Linux-stubbed release-script tests.