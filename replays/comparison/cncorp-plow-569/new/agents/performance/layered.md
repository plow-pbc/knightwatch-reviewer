## [performance] findings

### Surveyed
- Direct ULFO DMG creation in `app/plowd/scripts/plowd-beta-package-signed:263` — clean; removes the older writable-DMG/convert pass, so release I/O goes down overall.
- Mandatory final artifact verification in `app/plowd/scripts/plowd-beta-package-signed:301` — clean; one extra `hdiutil attach`/detach on a release-only path before upload.
- `plowd-verify-dmg` mount detection and checks in `app/plowd/scripts/plowd-verify-dmg:53` and `app/plowd/scripts/plowd-verify-dmg:82` — clean; bounded by mounted volume count and a single DMG mount.
- macOS CI plowd test wiring in `.github/workflows/test.yml:31` — clean for this PR; it duplicates the daemon suite on macOS, but that is CI-only and not a current timeout/OOM risk from the diff.
- Real-`hdiutil` regression tests in `app/plowd/tests/test_release_scripts.py:456` and `app/plowd/tests/test_release_scripts.py:522` — clean; they create a handful of tiny DMGs and do not scale with user data.
- Interactive layout recorder in `app/plowd/scripts/plowd-record-dmg-layout:154` — clean; expensive app copy and writable DMG creation are manual authoring steps, not request/release hot paths.