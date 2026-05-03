## Critic counterarguments

### [data-integrity] Finding 1 — AGREE
The path mismatch is real: `dmg-verify` defaults `../.build/Plow.dmg` while `plowd-verify-dmg` rewrites relative args as repo-root-relative (`app/justfile:230`, `app/plowd/scripts/plowd-verify-dmg:37`). Medium is calibrated because it breaks the advertised local guard, not the post-staple release call.

### [simplification] Finding 1 — AGREE
This survives as low: the PR adds a third copy of the same `hdiutil info | grep ... | sort` mounted-volume probe (`app/justfile:206`, `plowd-beta-package-signed:124`, `plowd-verify-dmg:46`). `_lib.sh` already exists for shared plowd shell helpers, so the remedy is not speculative.

### [tests] Finding 1 — REMEDY-BLOAT
The wiring gap is real, but the suggested new verifier-path env override adds another production test seam. Prefer a branch-negative finding on the existing `PLOW_SKIP_DMG_VERIFY` bypass (see missed finding) or drop/downgrade under Comment Review Mistakes 1/11; standalone Darwin behavior tests plus author smoke already cover the artifact contract.

### [tests] Finding 2 — AGREE
The skip turns the leaked-mount precondition into a soft pass (`test_release_scripts.py:271`, `:331`). Replacing `pytest.skip` with `pytest.fail` fits the Tests fail-loud standard and does not add recovery logic.

### [consumers] Finding 1 — DUPLICATE OF [data-integrity] Finding 1
Same root issue as data-integrity Finding 1 (`app/justfile:230` vs `plowd-verify-dmg:37`). The blocking label is overcalled because the release path’s verifier call is separate; keep the medium/local-guard framing.

## Missed findings (if any)
- [medium] `PLOW_SKIP_DMG_VERIFY` is a production release-script bypass for the new artifact guard (`plowd-beta-package-signed:299`). This conflicts with Concise Code / Fail-Fast and author intent that the guard fail the release before upload; remove the bypass and make the fake `hdiutil attach` emit `/Volumes/Plow` so the existing release test exercises the verifier without a test-only branch.