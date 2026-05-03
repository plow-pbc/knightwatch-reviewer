## [consumers] findings

### Surveyed
- `plowd-beta-package-signed` CLI callers in `app/justfile`, plowd tests, and signing docs — clean; existing options still match the script
- Removed `app/plowd/dmg/volume.icns` asset references across this repo and included sibling roots — clean; no remaining consumers
- Removed `.VolumeIcon.icns` DMG root payload expectations — clean; tests and verifier now treat presence as invalid
- New `plowd-verify-dmg --dmg` path contract versus its `app/justfile` caller — see Finding 1
- Included sibling search roots from `.codex-scratch/search-roots.md` — clean; no cross-repo callers of the changed DMG packaging symbols

### Finding 1 — blocking
`dmg-verify` passes `../.build/Plow.dmg`, but `plowd-verify-dmg` rewrites every relative `--dmg` as repo-root-relative, so `just app dmg-verify` resolves to `<repo>/../.build/Plow.dmg` instead of the documented `<repo>/.build/Plow.dmg`. The operator-facing guard can fail with “DMG not found” or validate a stale sibling artifact. Remedy cost is low: pass `.build/Plow.dmg` from the target, or omit `--dmg` and use the script default; no fallback branches needed.
Files: app/justfile:230, app/plowd/scripts/plowd-verify-dmg:37, docs/distribution/CODE_SIGNING.md:120