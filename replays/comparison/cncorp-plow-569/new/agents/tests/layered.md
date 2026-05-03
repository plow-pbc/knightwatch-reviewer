## [tests] findings

### Surveyed
- PR check rollup from GitHub, because `.codex-scratch/test-results.md` was missing — clean: all visible checks succeeded
- macOS CI wiring for Darwin-only plowd DMG tests — clean
- Real-`hdiutil` verifier tests for clean, `.VolumeIcon.icns`, wrong volume name, and detach failure paths — clean
- Cross-platform fake-`hdiutil` verifier tests — clean
- Release packaging test coverage for mandatory verifier wiring — see Finding 1

### Finding 1 — blocking
The release-path regression test does not actually prove `plowd-beta-package-signed` invoked `plowd-verify-dmg`. It asserts the banner and `attach {output}` in the `hdiutil` log, but the script already attaches the DMG earlier for codesign verification, before the PLO-29 verifier call. A future edit that leaves the banner but removes `"${repo_root}/app/plowd/scripts/plowd-verify-dmg" "${output}"` would still pass, letting the exact “release verifier silently bypassed” bug recur. Remedy cost is one tighter assertion, no new abstraction: assert the verifier’s distinct `attach ${output} -nobrowse -readonly` line or two attach calls.
Files: app/plowd/tests/test_release_scripts.py:438, app/plowd/tests/test_release_scripts.py:439, app/plowd/scripts/plowd-beta-package-signed:270, app/plowd/scripts/plowd-beta-package-signed:305

---

## Critic counter-arguments

### [tests] Finding 1 — MISCALIBRATED
The cited test behavior does not exist: `rg` finds no assertion for the verifier banner or `attach {output}`; the current release test explicitly sets `PLOW_SKIP_DMG_VERIFY=1` at `app/plowd/tests/test_release_scripts.py:200-204`. Keep only the narrower concern: there is no non-skip wiring test proving packaging invokes `plowd-verify-dmg`, but that is a small assertion/fake adjustment, not a blocking finding as written.
**Estimated remedy LOC:** ~8 LOC across 1 file.


