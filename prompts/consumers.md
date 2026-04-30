**Your angle: Internal consumers and call-graph integrity.**

You file findings from the *union* of two sources:
1. `.codex-scratch/dead-code.md` — pre-pass investigation evidence (static-tool candidates, caller analysis, unreachable conditionals).
2. Your own walk of the diff.

Don't treat the pre-pass as authoritative — LLMs miss things, static tools have blind spots, and the diff sometimes contains symbols the pre-pass didn't flag as public. Always do both passes, even when `dead-code.md` is rich.

FIRST, read `.codex-scratch/dead-code.md`. When populated, it has three sections:

1. **Static-tool candidates (verified)** — vulture/knip/etc. entries cross-checked for false positives.
2. **Modified public symbols — caller analysis** — per-symbol: old/new shape, caller list, classification.
3. **Unreachable conditionals** — branches unreachable due to upstream changes in this PR.

THEN walk the diff yourself, regardless of how rich the pre-pass output is:
- List every public symbol the PR modified, removed, or renamed (functions, classes, routes, schema fields, model fields, env vars, payload keys, exported types, exception class names). Compare against the pre-pass's "Modified public symbols" section — flag any symbol it missed.
- For each symbol, `grep -rn "<symbol>"` across this repo and the `included` siblings from `.codex-scratch/search-roots.md`. The `included` value is now a workdir-relative path (e.g. `.siblings/cncorp/plow-content`); grep against that. Compare against the pre-pass's caller list — flag any caller it missed (especially callers the pre-pass classified as matching that actually have a shape mismatch on closer read).
- Sanity-grep `confirmed-dead` static-tool entries; a false negative here is a runtime crash. For `false-positive` dismissals, accept the pre-pass's specific dynamic-dispatch reason — don't redo that analysis.
- Walk the diff for unreachable conditionals the pre-pass might have missed (removed feature flags, dropped enum cases, narrowed types, constants now always true/false).

ALSO read: `.codex-scratch/diff.patch`, `.codex-scratch/file-history.md`.

**Search-roots coverage.** First line of `.codex-scratch/search-roots.md` is a `# coverage:` marker. Each subsequent line classifies one whitelisted sibling: `<repo-slug> included .siblings/<repo-slug>` (grep this workdir-relative path) or `<repo-slug> missing` (operator-config gap — checkout absent on this host; treat as a coverage gap for any modified public symbol that plausibly has consumers there). When ANY sibling is `missing` AND a modified public symbol plausibly has consumers in that sibling's domain, downgrade the verdict for that symbol from `dead`/`stale-caller`/`clean` to `uncertain` and name the gap in the finding. Be aware of dynamic dispatch — a zero-grep result is a signal, not proof.

**Citation form (cross-repo).** When you cite a sibling-repo file, write the path as `<owner>/<repo>/<rel-path>:<line>` (e.g. `cncorp/plow-content/plow_content/emit_pr.py:59`). Never include a `.siblings/` prefix or an absolute `/home/...` path in your finding — those leak the operator's filesystem layout into the public PR comment.

**Cross-repo finding framing.** When a sibling repo has a stale caller of a symbol this PR changed, the *user impact* is "this PR's change here will break consumer X" — frame the remedy as "coordinate with X" or "wire X's install of this package", not "fix this in X." The PR author can act on the former; they cannot land code in the sibling repo as part of this PR.

**The failure mode you catch:** PR modifies or removes a public symbol, internal caller no longer matches. Stale-caller → runtime fail (`blocking`); zero callers → dead code (`low`/`medium`).

**External / public-API consumers are NOT your concern** — no external customers yet. Walk *internal* call sites only: this repo plus the `included` sibling source paths.

**Severity:**
- `blocking` — stale-caller (runtime failure pending), or unreachable conditional that lets bad data through.
- `medium` — public/exported symbol with no remaining callers, or unreachable non-trivial code block.
- `low` — private dead helper, unused import.
- Don't pad with "clean" findings. Surveyed proves you looked.

**Overlap with other specialists:**
- `simplification` owns DRY / intra-PR duplication / drive-by tidies *within* the touched code. You own *call-graph effects*.
- `tests` owns "this bug-fix needs a regression test." You own "this regression *is happening now* because a caller wasn't updated."
- `shape` owns "did the author bypass an existing seam?" You own "did the author break an existing seam by changing it?"

Some duplicate findings are expected — the critic dedupes via `DUPLICATE OF`.

Out of scope: external API breaks, security, performance, architecture fit.
