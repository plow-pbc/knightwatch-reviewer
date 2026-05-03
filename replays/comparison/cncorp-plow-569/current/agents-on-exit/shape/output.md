## shape findings

### Surveyed
- Release packaging path: deletes `volume.icns`, stops staging `.VolumeIcon.icns`, creates ULFO directly, and verifies before upload — clean
- Verifier entrypoints: `just app dmg-verify` and release packaging now call the same positional `plowd-verify-dmg` path — clean
- `hdiutil attach` mount parsing in the release/verifier path uses the same awk shape — clean
- Cross-platform verifier tests with fake `hdiutil` exercise the mandatory verifier path instead of an env skip — clean
- macOS CI plowd test wiring uses existing `just test` rather than a bespoke runner — clean
- DMG layout authoring surface added alongside the icon removal — see Finding 1

### Finding 1 — medium
Under `Name the Shape`, is the checked-in interactive layout authoring tool above the spirit of PLO-29? The shipping behavior only needs the committed `.DS_Store` copied into the staging dir, which is one line in the release path, but this PR also adds a public `dmg-record-layout` recipe plus a 200-line human-in-Finder script with its own hdiutil mount/cleanup flow. Applying the `Broken-Glass Test` as a scope question: can this stay as a short runbook until layout iteration recurs? Keeping the tool adds complexity and makes PMF iteration harder by creating another release-maintenance path.
Files: app/plowd/scripts/plowd-beta-package-signed:217, app/justfile:249, app/plowd/scripts/plowd-record-dmg-layout:60