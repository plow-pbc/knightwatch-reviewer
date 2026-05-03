## [consumers] findings

### Surveyed
- `plowd-beta-package-signed` CLI shape and existing callers — clean
- Removed `app/plowd/dmg/volume.icns` and `.VolumeIcon.icns` staging contract — clean
- New `plowd-verify-dmg --dmg` call sites — see Finding 1
- Darwin-only plowd CI invocation from `.github/workflows/test.yml` — clean
- Same-repo greps for `volume.icns`, `.VolumeIcon.icns`, `plowd-verify-dmg`, and `dmg-verify` — see Finding 1

### Finding 1 — blocking
The new app recipe’s default is stale for the verifier’s path contract. `just app ...` dispatches into the `app/` working directory, and `dmg-verify` passes `../.build/Plow.dmg`; then `plowd-verify-dmg` rewrites every relative `--dmg` as `${repo_root}/${dmg_path}`, so the default resolves to `<repo>/../.build/Plow.dmg` instead of the documented `<repo>/.build/Plow.dmg`. Users running `just app dmg-verify` after a release get `DMG not found`. Remedy cost is just aligning this one caller/default, with no new fallback branch.
Files: justfile:394, app/justfile:230, app/plowd/scripts/plowd-verify-dmg:37, docs/distribution/CODE_SIGNING.md:122

---

## Critic counter-arguments

### [consumers] Finding 1 — AGREE
This is a direct user-visible break: root `just app` runs with `--working-directory app` at `justfile:394-395`, `app/justfile:230-231` passes `../.build/Plow.dmg`, and `plowd-verify-dmg:37-39` resolves it under repo root as `<repo>/../.build/Plow.dmg`.
**Estimated remedy LOC:** ~1 LOC across 1 file.


