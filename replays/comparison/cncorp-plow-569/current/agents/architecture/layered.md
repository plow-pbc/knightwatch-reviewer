## [architecture] findings

### Surveyed
- Release packaging path in `app/plowd/scripts/plowd-beta-package-signed` — clean; it removes the UDRW/convert/FinderInfo branch and creates the shipping ULFO DMG directly.
- Mandatory post-staple verifier before S3 upload — clean; current branch has one release path, with no `PLOW_SKIP_DMG_VERIFY` or test-only bypass.
- `app/plowd/scripts/plowd-verify-dmg` as the artifact contract boundary — clean; the separate script keeps the release invariant reusable by both `just app dmg-verify` and the packaging script.
- Finder layout handling via checked-in `.DS_Store` plus `plowd-record-dmg-layout` — clean; the interactive authoring workflow is kept out of unattended CI/release packaging.
- macOS CI coverage for Darwin-only `hdiutil` behavior — clean; it extends the existing macOS app job rather than adding a parallel release architecture.
- PLO-29 spirit-vs-implementation — clean; the PR removes the custom volume-icon special case while preserving the stable “Plow” volume name and adding a final artifact guard without introducing a new product-facing distribution path.