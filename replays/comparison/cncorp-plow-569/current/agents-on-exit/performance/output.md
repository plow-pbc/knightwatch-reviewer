## [performance] findings

### Surveyed
- Direct `hdiutil create -format ULFO` release path replacing UDRW mount/convert — clean; removes extra disk-image work in a release-only script.
- Mandatory final `plowd-verify-dmg` invocation before upload — clean; one additional `hdiutil info`/attach/detach on the release path, not request-time or user-scale work.
- `awk` mount-point parsing in `plowd-beta-package-signed` and `plowd-verify-dmg` — clean; linear scan over tiny `hdiutil attach` output.
- macOS CI addition of `cd app/plowd && just test` — clean; PR checks show the macOS app-build job still completes comfortably under its 20-minute timeout.
- `plowd-record-dmg-layout` staging and writable DMG flow — clean; manual authoring tool, not CI or production runtime.
- Cross-platform fake-`hdiutil` verifier tests and fake mount copying — clean; bounded test fixtures, no production cost.