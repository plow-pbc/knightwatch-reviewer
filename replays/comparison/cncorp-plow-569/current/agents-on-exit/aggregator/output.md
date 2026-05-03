_It appears @swagatpatel is working towards making the macOS Plow installer present a standard, predictable DMG mount in Finder, with the volume still named "Plow" but no custom volume icon, by deleting `app/plowd/dmg/volume.icns`, removing `.VolumeIcon.icns` and FinderInfo staging from `app/plowd/scripts/plowd-beta-package-signed`, and adding `app/plowd/scripts/plowd-verify-dmg` plus CI coverage to block shipping regressions — reviewing against that goal._

**Overview** — This PR removes the custom DMG volume icon path and adds an artifact-level verifier so the release DMG still mounts as `Plow` without shipping `.VolumeIcon.icns`. The core release path is simpler now: direct ULFO creation, mandatory final verification before checksum/upload, and macOS CI coverage for the `hdiutil` guard.

**Strengths** — The verifier is placed at the right boundary: it checks the final stapled artifact, not just staging inputs. The macOS CI addition also closes the “Darwin-only test silently skipped everywhere” gap.

**Findings**
1. [low] Will `just app dmg-verify` need to accept normal filesystem paths with spaces? If yes, `app/justfile:233` currently expands `{{dmg}}` unquoted, so `just --dry-run -f app/justfile dmg-verify "/tmp/Foo Bar.dmg"` produces `plowd/scripts/plowd-verify-dmg /tmp/Foo Bar.dmg`; the verifier then receives extra positional args and rejects the command instead of checking the DMG. The source-parsing test at `app/plowd/tests/test_release_scripts.py:692` misses this because it asserts recipe text rather than running the public command behavior. Quote the pass-through and make the test exercise the just recipe. Files: `app/justfile:233`, `app/plowd/tests/test_release_scripts.py:692`. (Standard: Tests, Broken-Glass Test)
2. [nit] Does `app/justfile` need to carry the Finder workflow caveats already present in the recorder help? If not, the prose at `app/justfile:235` duplicates `app/plowd/scripts/plowd-record-dmg-layout:60` and gives future layout-flow changes two documentation surfaces to keep synchronized. Consider trimming the justfile back to the recipe summary. Files: `app/justfile:235`, `app/plowd/scripts/plowd-record-dmg-layout:60`. (Standard: Concise Code)

**Open Questions**
- **Q: Finder layout recorder lifespan** — Will Finder DMG layout need repeated adjustment before PMF? If yes, keep the recorder. If not, consider cutting `dmg-record-layout` plus `plowd-record-dmg-layout` back to a runbook — adds complexity and makes PMF iteration harder.

**Security** — Clean; the reviewed paths add no secrets, network calls, shell re-entry, or privileged workflow changes.

**Test coverage** — Coverage is strong around the release artifact contract, including real macOS `hdiutil` execution and fake-`hdiutil` regression cases, but the justfile alias test should become behavioral. `.codex-scratch/test-results.md` was absent; the tests specialist reported recovering status from PR checks and that all PR checks are passing.

VERDICT: APPROVE — pending: quote dmg-verify pass-through, trim duplicated layout docs