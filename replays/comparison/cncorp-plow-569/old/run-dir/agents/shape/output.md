## [shape] findings

### Surveyed
- Standards § Name the Shape — clean; this PR names the problem as artifact verification / release packaging and adds the guard at the artifact boundary.
- `app/plowd/scripts/plowd-beta-package-signed` DMG creation path — clean; it removes the custom icon staging and FinderInfo write instead of adding a parallel override path.
- `app/plowd/scripts/plowd-verify-dmg` — clean; standalone shell verifier matches the existing plowd release-script shape for argument parsing, repo-root resolution, `hdiutil` use, and fail-fast errors.
- Existing mounted-volume handling in `app/justfile` and `plowd-beta-package-signed` — clean; the new verifier follows the established `/Volumes/Plow` detection pattern rather than inventing a different state source.
- `app/justfile` `dmg-verify` recipe — clean; it exposes the verifier through the existing `just app ...` release tooling surface.
- `.github/workflows/test.yml` macOS plowd test step — clean; it extends the existing macOS CI lane to exercise Darwin-only artifact checks instead of creating a separate workflow pattern.
- `app/plowd/tests/test_release_scripts.py` hdiutil coverage — clean; the tests use the existing subprocess-based release-script test style and reserve real `hdiutil` for Darwin-only artifact behavior.