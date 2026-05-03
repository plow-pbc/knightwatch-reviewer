## Critic counterarguments

### [simplification] Finding 1 — REMEDY-BLOAT
Could these duplicated shell snippets drift in a production-observable way, or would `_lib.sh` just couple a release script and a manual Finder authoring helper? The release/verifier parser parity is already intentional at `plowd-beta-package-signed:272-276` and `plowd-verify-dmg:83-89`; a branch-negative alternative is to update the recorder’s sed parser in place only if it matters.

### [simplification] Finding 2 — AGREE
Does `app/justfile:235-246` need to carry workflow caveats already present in `plowd-record-dmg-layout:60-92`? If not, deleting the repeated prose is LOC-negative and keeps the script help as the source of truth.
**Estimated remedy LOC:** ~0 LOC across 1 file.

### [tests] Finding 1 — AGREE
This survives: `test_just_dmg_verify_recipe_is_thin_alias_to_verifier` at `test_release_scripts.py:692-715` parses recipe text, while the public contract is whether `just dmg-verify` forwards args correctly. A behavioral test would also catch the missed quoting bug in `app/justfile:232-233`.
**Estimated remedy LOC:** ~15 LOC across 1 file.

### [shape] Finding 1 — REFRAME-AS-QUESTION
The finding assumes the new Finder layout recorder is above the PR’s needed surface, but `plowd-record-dmg-layout:5-57` explains it exists because checked-in `.DS_Store` is now the release artifact source.
Reframe:
> Will Finder DMG layout need repeated adjustment before PMF? If yes, keep the recorder. If not, consider cutting `dmg-record-layout` plus `plowd-record-dmg-layout` back to a runbook — adds complexity and makes PMF iteration harder.
**Estimated remedy LOC:** ~0 LOC across 2 files.

## Missed findings
- [low] `app/justfile:232-233` declares public `dmg-verify *dmg` but expands `{{dmg}}` unquoted. With `just 1.50.0`, a path like `"/tmp/Foo Bar.dmg"` splits into two shell args, so `plowd-verify-dmg` rejects it instead of verifying the DMG; use `{{quote(dmg)}}` or an equivalent quoted pass-through.