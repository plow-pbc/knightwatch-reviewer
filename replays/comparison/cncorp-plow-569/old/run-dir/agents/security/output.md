## [security] findings

### Surveyed
- `app/plowd/scripts/plowd-beta-package-signed` DMG creation and upload path — clean | removes the writable DMG attach/FinderInfo mutation and runs the new verifier before checksum/S3 upload.
- `app/plowd/scripts/plowd-verify-dmg` argument handling and `hdiutil attach` use — clean | shell variables are quoted, no `eval`, no command construction from untrusted input, and mounts are read-only/nobrowse.
- `app/justfile` `dmg-verify` target — clean | local developer-only artifact verification; no new network, credential, or auth surface.
- `.github/workflows/test.yml` macOS plowd test step — clean | adds test execution only; no new secrets, permissions, or external publishing step.
- `app/plowd/tests/test_release_scripts.py` new verifier tests and PATH-injected wrapper — clean | fake binaries are scoped to subprocess test envs and do not alter production command resolution.