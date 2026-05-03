## PR Title
PLO-29: drop custom DMG volume icon

## PR Description (author's own explanation)

## Summary

- The mounted Plow installer DMG showed an icon that looked like the running app, causing confusion in Finder ("Plow" the volume vs "Plow" the app).
- Strip the custom volume icon from every DMG-producing path; the volume now uses the default macOS removable-volume icon. Volume name remains "Plow" (matches OrbStack / Claude convention).
- Add a real-`hdiutil` regression guard (`plowd-verify-dmg` / `just app dmg-verify`) wired into `plowd-beta-package-signed` between staple and S3 upload, so a future reintroduction fails the release build. The Darwin-only pytest now runs on the macOS CI lane.

Resolves PLO-29.

## Test plan

- [ ] `just app dmg-verify` passes on a freshly built DMG locally (volume mounts, no `.VolumeIcon.icns` at root, volume name is "Plow").
- [ ] CI macOS app-build job runs the plowd test suite (25 tests), including the artifact-level guard test that builds clean / `.VolumeIcon`-staged / wrong-`volname` DMGs and asserts the guard's behavior.
- [ ] Smoke: temporarily reintroduce the icon-staging line locally; the release path fails at the verify step.
- [ ] `hdiutil detach` failure on the success path now exits the script non-zero with "failed to detach" on stderr (covered by the new injected-failure pytest).
