# Probe — schema (data shape only)

This file defines the **data shape**. Policy (when to emit, mandates, posture) lives in `prompts/common-header.md`. Rendering policy lives in `prompts/aggregator.md`. Keeping shape and policy split prevents drift between two prompt surfaces.

## Fields

Every probe is a Markdown block with this exact field set:

```
### Probe N
- **From:** <specialist name>          # e.g. shape, security, simplification, critic
- **Class:** <bug|bypass|shape|DRY|tests|dead-code|perf|complexity-cost>
- **Q:** <one sentence — the assumption being asserted as if settled, in question form>
- **Files:** <path:line>, <path:line>, …
- **If yes, edit:** <concrete code change this unlocks — name files + LOC delta>
- **If no, cost:** <one clause naming what calcifies if we keep current shape>
- **Confidence:** <high|medium|low>    # emitter's prior on Q being yes
- **Severity if yes:** <blocking|medium|low|nit>
- **Answer:** <yes|no|unknown>         # filled by critic with evidence; specialists default to "unknown"
- **Evidence:** <one line citing the grep/git-log/file-history finding that produced the answer; "—" if Answer=unknown>
```

## Resolved-probe deltas (critic-only)

The critic emits delta blocks under `## Resolved probes`, one per specialist probe it resolves. Header form: `### [from: <angle>] Probe N`. Required fields: `Answer`, `Evidence`. Optional: `Severity if yes` (when the critic overrides the specialist's prior).

## Generated probes (critic-only)

Critic-originated probes go under `## Generated probes` as full probe blocks per the schema above, with `From: critic`.
