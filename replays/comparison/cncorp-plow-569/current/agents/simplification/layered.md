## [simplification] findings

### Surveyed
- Removal of `.VolumeIcon.icns` staging and direct `ULFO` DMG creation — clean
- Mandatory release-path call to `plowd-verify-dmg` with no skip branch — clean
- New verifier argument shape and `just app dmg-verify` pass-through — clean
- Repeated Plow-volume mount detection and hdiutil mountpoint parsing — see Finding 1
- New Finder-layout recording script and justfile documentation surface — see Finding 2
- Test fake `hdiutil` changes for exercising the real verifier path — clean

### Finding 1 — low
Broken-Glass Test / Concise Code: could the DMG mount primitives move into `app/plowd/scripts/_lib.sh` now that this PR carries multiple copies? `plowd-verify-dmg` and `plowd-record-dmg-layout` both duplicate the “already mounted `/Volumes/Plow`” probe, while `plowd-beta-package-signed` and `plowd-verify-dmg` duplicate the awk mountpoint parser and `plowd-record-dmg-layout` still uses the old sed parser. A tiny shared `plowd_mounted_plow_volumes` / `plowd_hdiutil_mountpoint` helper would reduce repeated shell parsing without adding conditionals, special cases, or a new abstraction layer beyond the existing `_lib.sh`.
Files: app/plowd/scripts/plowd-verify-dmg:53, app/plowd/scripts/plowd-record-dmg-layout:134, app/plowd/scripts/plowd-beta-package-signed:271

### Finding 2 — nit
Broken-Glass Test / Concise Code: could the `justfile` keep only the recipe summary and let `plowd-record-dmg-layout --help` be the source of truth? The just recipe now repeats the Finder workflow and caveats that are already documented in the script’s header and usage text, so every future layout-flow tweak has two prose surfaces to keep synchronized. The remedy is just deletion of duplicated comments, not new guards or abstractions.
Files: app/justfile:235, app/plowd/scripts/plowd-record-dmg-layout:60

---

## Critic counter-arguments

### [simplification] Finding 1 — REMEDY-BLOAT
Could these duplicated shell snippets drift in a production-observable way, or would `_lib.sh` just couple a release script and a manual Finder authoring helper? The release/verifier parser parity is already intentional at `plowd-beta-package-signed:272-276` and `plowd-verify-dmg:83-89`; a branch-negative alternative is to update the recorder’s sed parser in place only if it matters.

### [simplification] Finding 2 — AGREE
Does `app/justfile:235-246` need to carry workflow caveats already present in `plowd-record-dmg-layout:60-92`? If not, deleting the repeated prose is LOC-negative and keeps the script help as the source of truth.
**Estimated remedy LOC:** ~0 LOC across 1 file.


