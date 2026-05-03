## Critic counterarguments

### [security] Finding 1 — FALSE POSITIVE
The cited recorder script is not present in this repo (`app/plowd/scripts/plowd-record-dmg-layout` is absent), and the diff does not add or copy `app/plowd/dmg/.DS_Store` into the staged DMG; `plowd-beta-package-signed` only copies `background.tiff` into `stage_dir` at `app/plowd/scripts/plowd-beta-package-signed:215-216`.

### [data-integrity] Finding 1 — FALSE POSITIVE
The parser is not `$NF`; current code uses `sed -n 's|.*\(/Volumes/.*\)$|\1|p'` at `app/plowd/scripts/plowd-verify-dmg:76`, which preserves `/Volumes/Plow Installer` including spaces, so cleanup still has a mount path.

### [architecture] Finding 1 — AGREE
This has a concrete bypass path: `PLOW_SKIP_DMG_VERIFY=1` skips the verifier at `app/plowd/scripts/plowd-beta-package-signed:299-302`, then the script uploads at `:315-316`. Removing the env bypass makes the release path simpler and mandatory.
**Estimated remedy LOC:** ~0 LOC across 1 file.

### [simplification] Finding 1 — REMEDY-BLOAT
Will this tiny `hdiutil info | grep -Eo '/Volumes/Plow( [0-9]+)?$'` shape drift often enough to justify sourcing shared shell across a just recipe and scripts? With no observed drift, extracting `_lib.sh` plumbing for three one-liners adds complexity and makes PMF iteration harder.

### [simplification] Finding 2 — REMEDY-BLOAT
Will these two Darwin-only tests expand into enough cases that helper indirection pays for itself? Right now the duplication is local test setup at `app/plowd/tests/test_release_scripts.py:268-338`; adding helpers for two tests is cleanup theater and adds complexity and makes PMF iteration harder.

### [simplification] Finding 3 — AGREE
Is cleanup in scope because this PR already touches the fake release command table? Yes: the duplicate `generate_appcast` key at `app/plowd/tests/test_release_scripts.py:865` and `:880` makes `_fake_generate_appcast_script()` at `:933` dead code; deletion is branch-negative.
**Estimated remedy LOC:** ~0 LOC across 1 file.

### [tests] Finding 1 — MISCALIBRATED
The cited test behavior does not exist: `rg` finds no assertion for the verifier banner or `attach {output}`; the current release test explicitly sets `PLOW_SKIP_DMG_VERIFY=1` at `app/plowd/tests/test_release_scripts.py:200-204`. Keep only the narrower concern: there is no non-skip wiring test proving packaging invokes `plowd-verify-dmg`, but that is a small assertion/fake adjustment, not a blocking finding as written.
**Estimated remedy LOC:** ~8 LOC across 1 file.

### [shape] Finding 1 — FALSE POSITIVE
The factual premise is stale: `plowd-record-dmg-layout` is absent, and both live parsers in the package script and verifier use the same `sed` shape at `app/plowd/scripts/plowd-beta-package-signed:269` and `app/plowd/scripts/plowd-verify-dmg:76`, not parallel `awk`/`sed` constructs.

### [consumers] Finding 1 — AGREE
This is a direct user-visible break: root `just app` runs with `--working-directory app` at `justfile:394-395`, `app/justfile:230-231` passes `../.build/Plow.dmg`, and `plowd-verify-dmg:37-39` resolves it under repo root as `<repo>/../.build/Plow.dmg`.
**Estimated remedy LOC:** ~1 LOC across 1 file.

## Missed findings (if any)
None.