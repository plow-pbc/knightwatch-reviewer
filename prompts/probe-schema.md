# Probe — the unit of reviewer pushback

Every specialist (and the critic) emits zero or more **probes**. A probe is a single observation about the diff with the following fields:

```
### Probe N
- **From:** <specialist name>          # e.g. shape, security, simplification
- **Class:** <bug|bypass|shape|DRY|tests|dead-code|perf|complexity-cost>
- **Q:** <one sentence — the assumption being asserted as if settled, in question form>
- **Files:** <path:line>, <path:line>, …
- **If yes, edit:** <concrete code change this unlocks — name files + LOC delta>
- **If no, cost:** <one clause naming what calcifies if we keep current shape>
- **Confidence:** <high|medium|low>    # specialist's prior on Q being yes
- **Severity if yes:** <blocking|medium|low|nit>
- **Answer:** <yes|no|unknown>         # filled by critic with evidence; specialists default to "unknown"
- **Evidence:** <one line citing the grep/git-log/file-history finding that produced the answer; "—" if Answer=unknown>
```

## Posture

A probe with `Confidence: high, Answer: yes` and a cited failing path IS today's `[blocking]` declarative finding — the question is just compressed out at the rendering layer. A probe with `Confidence: low, Answer: unknown` IS today's Open Question. There is no separate "Findings" vs "Open Questions" concept. The same data type covers the spectrum.

## Cost-naming requirement

Every probe's `If no, cost:` clause MUST name what calcifies (a branch, a seam, a defensive guard, a shape) — not just "adds complexity". Bare cost-naming ("adds complexity and makes PMF iteration harder") is the floor; specific cost-naming ("calcifies a 3-branch dispatch that future routes must extend") is the ceiling.

## Inverted-cost probes

Probes about **existing complexity in the diff** invert the polarity: `If yes, edit:` becomes "delete the branch / collapse the abstraction / drop the schema field"; `If no, cost:` names what already-in-PR shape we're keeping. The Class for these is `complexity-cost`. Specialists are required to emit at least one `complexity-cost` probe per non-trivial PR — if none, the specialist's surveyed list MUST explain why.

## Rendering

The aggregator renders probes by `Answer`:

- `Answer: yes` → declarative outcome line + edit. Severity badge from `Severity if yes`.
- `Answer: unknown` → question line + if-yes/if-no cost. No severity badge.
- `Answer: no` → dropped entirely with a one-line footnote (`Probe dropped: <evidence>`).

Every rendered line carries `[from: <specialist>]`.
