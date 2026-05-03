## [tests] findings

### Surveyed
- Prepared `just test` result — clean for PR attribution: it reports exit 1, but the supplied tail shows completed suites passing and truncates at the plowd command without a concrete failure to classify
- Stubbed signed-release test for DMG creation flags and staged files — see Finding 1
- Standalone `plowd-verify-dmg` artifact tests for clean, iconed, and misnamed DMGs — clean
- macOS CI wiring to run plowd tests where `hdiutil` exists — clean
- Detach-failure regression test for the verifier success path — clean
- Pre-mounted `/Volumes/Plow` handling in the Darwin tests — see Finding 2

### Finding 1 — medium
The release-path verifier wiring is not exercised. `test_signed_package_script_builds_ulfo_dmg_without_staging_ds_store` sets `PLOW_SKIP_DMG_VERIFY=1`, so the fake release still passes if `plowd-beta-package-signed` stops invoking `plowd-verify-dmg` after notarization; the Darwin test only proves the standalone verifier works. That leaves the PR’s “fails before upload” contract unpinned. Remedy cost is one small test seam: route the verifier through a script variable/env override, like existing fake release commands, then use a fake verifier that exits nonzero and assert checksum/S3 upload never happens.
Files: app/plowd/tests/test_release_scripts.py:200, app/plowd/scripts/plowd-beta-package-signed:299

### Finding 2 — low
The new Darwin tests skip when any `Plow` volume is mounted, which can turn the exact leaked-mount state this guard cares about into a soft pass during local reruns. Tests should fail loudly here; per `Fail-Fast` and `Concise Code`, the low-cost remedy is branch-negative: replace these skips with `pytest.fail(...)` or a shared precondition helper that fails with the same eject instruction, rather than adding recovery logic or more defensive branches.
Files: app/plowd/tests/test_release_scripts.py:271, app/plowd/tests/test_release_scripts.py:331