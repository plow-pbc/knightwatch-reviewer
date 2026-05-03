## [architecture] findings

### Surveyed
- Product intent vs implementation: removed `.VolumeIcon.icns` staging and FinderInfo writes while preserving `-volname "Plow"` — clean | matches the stated UX goal without adding a new release variant.
- Release packaging path in `app/plowd/scripts/plowd-beta-package-signed:258` through `app/plowd/scripts/plowd-beta-package-signed:301` — clean | keeps the single signed/notarized/upload path and verifies before S3 upload.
- New verifier boundary in `app/plowd/scripts/plowd-verify-dmg:75` through `app/plowd/scripts/plowd-verify-dmg:87` — clean | artifact-level check is small, fail-fast, and does not introduce fallback packaging logic.
- Local operator entrypoint in `app/justfile:228` through `app/justfile:231` — clean | thin wrapper over the same verifier rather than a second implementation.
- macOS CI placement in `.github/workflows/test.yml:23` through `.github/workflows/test.yml:32` — clean | exercises Darwin-only artifact behavior on the existing app-build lane instead of adding a separate release architecture.
- File-taxonomy boundary from `docs/architecture/file-taxonomy.md:17` through `docs/architecture/file-taxonomy.md:26` — clean | touched packaging assets/scripts are Plow-owned wrapper/release code, not upstream runtime or per-install state.