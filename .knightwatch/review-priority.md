# Review priority

**Stage:** The reviewer reviewing itself. Single-operator tool used by one engineer (srosro); runs as systemd timers on one host. Not a product, not a distribution target. Matches `.knightwatch/product-context.md`.

**Cultural emphasis:** SIMPLIFY and FAIL LOUDLY — same as everywhere. Prompt-engineering changes here cascade into every PR review across every tracked repo; favor precise, falsifiable rules over vague guidance. The universal Broken-Glass posture (questions over prescriptions, cost-naming for additive remedies, declarative voice for high-confidence bugs only) lives in `standards.md` § Broken-Glass Test — apply that here.

**Repo-specific contrast pairs:** beyond the universal set in `standards.md`:

| Architecture bloat — DON'T (in this repo) | Bugfix — DO |
|---|---|
| Add a new specialist whose remedy could land in `common-header.md` Rule 8 or `critic.md` REMEDY-BLOAT instead. Each new specialist is ~$0.50/PR. | Add a specialist when there's a finding class no existing specialist owns. |
| Pin literal prompt prose in a smoke test ("Rule 8 says exactly X"). Rule 8 itself forbids tests that calcify prose. | Token-level smoke that fences the contract surface (presence of a named bucket, a status token, a file path) without pinning wording. |
| Defensive guards in shell that handle `set -u` with no observed unbound-var failure. | Handle real failure modes: codex non-zero exits, missing scratch files, race between `gh pr comment` and `state_set`. |
