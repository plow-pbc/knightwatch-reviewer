## [security] findings

### Surveyed
- `app/plowd/scripts/plowd-verify-dmg:20-100` argument parsing and `hdiutil` use — clean: path inputs are quoted, no `eval`/shell re-entry, and no secrets or network calls.
- `app/plowd/scripts/plowd-beta-package-signed:301-319` final verification before upload — clean: latest PR path makes the DMG verifier mandatory before S3 upload; no skip env or alternate upload path remains.
- `app/plowd/scripts/plowd-beta-package-signed:215-220` DMG staging contents — clean: stages app, `.DS_Store`, background, and `/Applications` symlink only; no credential or user data files are pulled in.
- `app/plowd/dmg/.DS_Store` committed Finder metadata — clean: string scan found no usernames, home paths, API keys, tokens, or credentials.
- `.github/workflows/test.yml:23-32` added macOS plowd test lane — clean: runs in the existing pull-request test workflow without adding secrets or new privileged permissions.
- `app/plowd/scripts/plowd-record-dmg-layout:95-201` interactive layout capture helper — clean: local-only authoring flow, quoted paths, no auth/session/credential handling.