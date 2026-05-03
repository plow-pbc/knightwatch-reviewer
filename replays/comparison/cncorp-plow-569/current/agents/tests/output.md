## [tests] findings

### Surveyed
- PR test results input — `.codex-scratch/test-results.md` was missing; self-healed with `gh pr checks`, and all PR checks are passing — clean
- macOS CI coverage for Darwin-only `hdiutil` tests in `.github/workflows/test.yml:23-32` — clean
- Release packaging regression test for direct ULFO creation, mandatory verifier call, `.DS_Store`, and no `.VolumeIcon.icns` in `app/plowd/tests/test_release_scripts.py:382-452` — clean
- Real macOS artifact verifier tests for clean DMG, root `.VolumeIcon.icns`, wrong volume name, and detach failure in `app/plowd/tests/test_release_scripts.py:456-589` — clean
- Cross-platform fake-`hdiutil` verifier tests in `app/plowd/tests/test_release_scripts.py:592-689` — clean
- Release script verifier wiring after notarization and before checksum/upload in `app/plowd/scripts/plowd-beta-package-signed:301-305` — clean
- `just app dmg-verify` test shape — see Finding 1

### Finding 1 — nit
Under the Broken-Glass Test, could this test verify the public command behavior instead of parsing the Justfile body? `test_just_dmg_verify_recipe_is_thin_alias_to_verifier` asserts source text such as `"plowd-verify-dmg"` and absence of `"--dmg"`, which locks a recipe implementation detail while still missing failures in argument forwarding, quoting, or working directory. The existing fake-`hdiutil` seam could run `just -f app/justfile dmg-verify <fake.dmg>` and assert the verifier outcome, replacing source parsing without adding new abstractions or branches.
Files: app/plowd/tests/test_release_scripts.py:692, app/justfile:232