# Review priority

**Stage:** The reviewer reviewing itself. Single-operator tool used by one engineer (srosro); runs as systemd timers on one host. Not a product, not a distribution target. Matches `.knightwatch/product-context.md`.

**Cultural emphasis:** SIMPLIFY at all costs — complexity kills PMF iteration. Subtractive remedies (delete, collapse, retire) are higher-leverage than additive ones at any severity. Cumulative additive LOC across review rounds is the structural-failure signal — see PR#47 contrast pair below. Prompt-engineering changes here cascade into every PR review across every tracked repo; favor precise, falsifiable rules over vague guidance. The universal Broken-Glass posture lives in `standards.md` § Broken-Glass Test — apply that here, including the worked PR#47→#50 substrate-replacement example.

**Repo-specific contrast pairs:** beyond the universal set in `standards.md`:

| Architecture bloat — DON'T (in this repo) | Bugfix — DO |
|---|---|
| Add a new specialist whose remedy could land in `common-header.md` Rule 8 or `critic.md` REMEDY-BLOAT instead. Each new specialist is ~$0.50/PR. | Add a specialist when there's a finding class no existing specialist owns. |
| Pin literal prompt prose in a smoke test ("Rule 8 says exactly X"). Rule 8 itself forbids tests that calcify prose. | Token-level smoke that fences the contract surface (presence of a named bucket, a status token, a file path) without pinning wording. |
| Defensive guards in shell that handle `set -u` with no observed unbound-var failure. | Handle real failure modes: codex non-zero exits, missing scratch files, race between `gh pr comment` and `state_set`. |
| Continue iterating with additive remedies on a refactor PR whose cumulative additive LOC across rounds has crossed +100 (probe-as-unit PR#47 dynamic). | Surface the substrate-replacement move that retires the recurring bug class — net-LOC-down beats five rounds of net-LOC-up parser fixes. |
