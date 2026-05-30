# Aggregator Decline Arbitration — Design

## Problem

PR #113 ("surface the PR comment thread to every specialist") was supposed to stop the reviewer from re-deriving settled findings round after round. It didn't. A real case — `cncorp/plow#784`, the limactl-timeout-hardening PR — ran the #113-bearing image (commit `5950eae`) for all 8 review rounds and still oscillated: the same finding kept resurfacing across rounds, and one low-severity probe flip-flopped (R5 asked to *add* a `run(_:)` overload; R8 asked to *delete* it). The maintainer declined the same scope decision with detailed prose every round, and the reviewer kept re-raising it.

The post-mortem found two failure modes, both rooted in the same design gap:

1. **The reliable suppression channel was never exercised.** #113 has two decline channels. The only *deterministic* one is the `<!-- decline:class=X -->` marker: the operator hand-authors an HTML marker in their reply, and after the same class is marked ≥3 rounds the critic mechanically drops it. No human ever types those markers — the babysit-pr reply flow emits free-form prose, not markers. So the deterministic lever sat unused while the PR oscillated.

2. **The precise channel is too coarse and too fuzzy to converge.** The marker channel keys off `Class` — only five values — so marking would over-suppress *unrelated* findings of the same class. The free-form-prose channel (the other channel) is a fuzzy LLM substring-style match that defaults to dropping a re-emitted finding; across 8 rounds the finding kept *re-shaping its surface form* (instanceExists → digest-planning → "bound the sweep, propagate-not-collapse"), so the fuzzy match failed to recognize it as the thing already declined, and the probe survived to the posted review every round.

Worse, the decline-reasoning is **duplicated**: `prompts/critic.md` §Decline-history and `prompts/aggregator.md` step 38 both implement a "prior operator decline → default to Answer:no / drop" rule. Two copies of the same fuzzy logic, neither human-like, both defeated by a re-shaped finding.

## What this spec changes

Replace the two mechanical decline channels with **one smart, human-like arbiter in the aggregator.** The aggregator already reads the full discussion ledger — `prior-reviews.md` (its own concatenated past outputs) and `pr-comments.md` (the trusted thread). It can see *what it already argued* and *whether the operator engaged.* So instead of a coarse marker count or a fuzzy default-drop, the aggregator reasons about each prior-declined probe the way a senior reviewer would: it doesn't blindly accept a decline, doesn't ignore it, **quotes it back, and renders an opinion.**

The author-authored `<!-- decline:class=X -->` marker mechanism is deleted entirely. It was never used, it's coarse, and relying on authors to hand-author HTML to drive convergence is the wrong contract.

## The cultural lens this spec encodes

The reviewer is a senior colleague, not a linter. A senior colleague who flags something, hears "I'm not doing that because Z," and silently drops it looks disengaged; one who re-raises the identical point every week looks like they aren't listening. The right behavior is in between: **argue your point once, with the author's own words quoted back; if they engage and make the call, defer — they own the code; if they didn't actually address your point, say so once more, specifically.** That's what this spec encodes into the aggregator.

## Goals

1. **Delete the `<!-- decline:class=X -->` marker channel** — from the comment-staging library, both prompts that reference it, the common header, and the tests that pin it.
2. **Strip the critic's mechanical decline-arbitration** — the critic resolves probes on technical merit and reads the thread only as context (so it doesn't blindly re-raise). It no longer does the default-drop. Arbitration lives in exactly one place.
3. **Make the aggregator the single, human-like arbiter** of prior-declined probes, with a six-verdict model that maps the maintainer's framing (rank / exclude / edit / reinforce / re-litigate / defer).
4. **Guarantee convergence without a marker count** via the "argue once, then defer" rule, with re-litigation bounded to a *specific, unaddressed, substantive point quoted against the code.*
5. **Net-neutral-to-negative LOC** — we delete more plumbing (Channel 2, marker tests, the duplicated critic logic) than the arbitration prose we add.

## Non-goals

- **No change to the trust boundary.** Decline authority stays operator-only; participant (PR author / reviewer) prose remains untrusted context that never drives a drop. (In the #784 case operator == author, but the model must stay correct when they differ.)
- **No new state file / pipeline wiring.** The discussion ledger the aggregator needs (`prior-reviews.md` + `pr-comments.md`) is already staged as an aggregator input. We add no per-probe "decline ledger" artifact — that would add a concept for something the aggregator can already read.
- **No change to the specialists' probe-emission contract.** Specialists keep reading the thread as context (`common-header.md`); only the *marker-count* mention is removed.

## What's already in place

- `lib/pr-comments.sh` stages two channels: Channel 1 (`## PR thread`, every trusted non-bot comment, verbatim, labeled `operator`/`participant`) and Channel 2 (`## Operator decline markers`, operator-only `<!-- decline:class=X -->` counts). **Channel 1 stays; Channel 2 is deleted.**
- `prompts/critic.md` §Decline-history — two-bullet rule (marker-count → Answer:no; free-form prose → default Answer:no). **Removed.**
- `prompts/aggregator.md` step 38 (cross-angle carry-forward) — the persistence test plus an inline operator-decline-drop. **The decline-drop is replaced with the arbitration model; the persistence test stays.**
- `prompts/aggregator.md` step 0 / inputs doc — describes both channels. **Collapsed to one channel.**
- `prompts/common-header.md` line 45 — input doc mentioning the marker count. **Marker mention removed; "read before re-emitting" guidance stays.**
- The T2 blocker-stall re-eval banner (aggregator Path 2) — fires once when the `[blocking]` count hasn't shrunk across 3 rounds. **Unchanged — it is the PR-level convergence backstop that composes with the per-probe rule.**

## Design

### Component 1 — `lib/pr-comments.sh`: drop Channel 2

Remove the `explicit_classes` scan, the `## Operator decline markers` section emission, and the two-channel framing in the header doc. The function keeps Channel 1 unchanged: the verbatim trusted thread, blockquoted, labeled `operator`/`participant`. The early-return guard becomes "no thread → `(no PR comments)`" (drop the `&& [ -z "$explicit_classes" ]` half). The participant-can't-spoof-a-heading blockquote protection stays (it now only protects against a participant forging `## PR thread`-adjacent structure, which is still worth keeping).

**Interface unchanged:** `fetch_pr_comments REPO PR_NUM` → markdown on stdout; `_pr_comments_from_json RAW TRUSTED` remains the pure, testable transform.

### Component 2 — `prompts/critic.md`: remove §Decline-history

Delete the entire **Decline-history channel** section (both bullets). Update the `pr-comments.md` input-description line to: the thread is context the critic reads so it doesn't blindly re-raise a probe a reply already addressed; it never drives a mechanical `Answer:no`; **decline arbitration is the aggregator's job.** Update the `Answer: no` definition (line 28) to drop the "operator already declined this class ≥3 rounds" citation option.

The critic's other resolution paths (Pre-PMF lens, Severe-bug carve-out, Hypothetical-future-regression decline, Self-referential spec guard) are unchanged — those are technical-merit resolutions, not comment-thread arbitration.

### Component 3 — `prompts/aggregator.md`: the arbitration model

Rewrite the decline-handling inside step 38's carry-forward (and the step-0 inputs doc) as a reasoned, human-like arbitration. For each prior probe in the carry-forward source, the aggregator first reads the discussion: the operator's reply in `pr-comments.md` (matched by **specific finding** — cited path / contract / rationale, never the coarse `Class`) and its own prior counter-opinion (if any) in `prior-reviews.md`. It then renders one of six verdicts:

| Verdict (maintainer's verb) | Condition | Render |
|---|---|---|
| **exclude** | The decline is sound; the aggregator agrees. | Drop. Optional footnote quoting the decline: `Probe resolved: operator declined ("<one-line quote>") because <reason> — agreed.` |
| **re-litigate** | The aggregator disagrees AND (it has not yet argued this probe — *by cited-shape identity*, see below — OR the operator's reply added no new info / missed a key point the code shows). | Render the probe, **quoting the operator and countering against the code**: *"You said X is okay because Z, but `file:line` shows Y, which means …"* The counter MUST cite a specific, unaddressed, substantive point. |
| **defer** | The aggregator already argued this probe once (a prior `prior-reviews.md` round renders a probe at the *same cited `Files:` shape* with a counter) AND the operator held position. | Drop. Footnote: `Probe resolved: deferred to operator after counter-argument — they own the call.` |
| **edit** | The comment partially changes the calculus. | Render a *narrowed* probe — lower severity and/or tighter scope — folding in the operator's point and naming what changed. |
| **reinforce** | The comment confirms the finding or reveals a worse case. | Render at full or higher severity, citing the comment as corroboration. |
| **rank** | The comment doesn't resolve but signals engagement. | Order an engaged-but-unresolved finding above untouched leaf probes within its severity band. |

**The deterministic anchor — the load-bearing fix.** The #784 oscillation happened because the prior fuzzy decline-match keyed off *prose*, and the finding re-shaped its surface form every round (instanceExists → digest-planning → "bound the sweep"), so the prose-match failed to recognize it as already-declined. A convergence rule that *also* keys off prose would inherit the same failure. So it must not.

The aggregator already has a deterministic cross-round probe identity that does **not** depend on prose: the **cited `Files:` shape** (`path:line`). This is the exact identity the carry-forward persistence test uses ("a probe persists iff its cited shape is still present at HEAD") — the single source of truth for "is this the same probe as last round." Decline arbitration keys off that *same* identity rather than inventing a parallel prose-matcher: a re-emitted finding matches a prior decline (and a prior counter-argument) when its **cited `Files:` shape** matches — regardless of how the prose was reworded. Crucially, `Class` is **not** part of the identity: a conjunctive `shape + Class` key would be *narrower* than the persistence test's, so a finding that re-shapes its prose **and** flips its `Class` (e.g. #784's `run(_:)` overload R5-add → R8-delete, which can cross a `shape`/`simplification` boundary) would evade argue-once — the very oscillation this rule kills. Shape-alone is both the genuine reuse (no parallel matcher) and the polarity-flip-immune choice. The #784 finding cited the same limactl-`list` call sites in the same file across all its re-shapings; on cited shape it is recognizably one probe, and argue-once holds.

**The convergence rule, stated for the prompt:**

> Argue once, then defer — keyed off the probe's cited-shape identity (cited `Files:` shape), the same identity the persistence test tracks across rounds, NOT the prose wording and NOT the `Class`. You may render a counter-opinion on a declined probe *once*: check `prior-reviews.md` for a prior round whose rendered probe shares this probe's cited `Files:` shape and already quotes/counters the operator — if you find one, you have argued it. After that, **defer** by default — drop the probe; the operator owns the code. Re-litigate *past* the first argument ONLY when the operator's reply added no new information or did not address a specific key point — and then your re-litigation MUST quote the unaddressed point and cite the code shape that contradicts it (*"You said … because Z, but `file:line` shows Y …"*). If you have no specific, unaddressed, substantive point to quote, defer. A re-raise that merely re-words the prior probe at the same cited shape is forbidden — that is the oscillation this rule exists to kill.

Because the rule keys off cited shape, it is **severity-agnostic**: it catches a low-severity oscillation (like #784's `run(_:)` overload flip-flop, R5 add → R8 delete) that the T2 blocker-stall banner — which counts `[blocking]` probes only — would miss. The T2 banner stays as the PR-level backstop for blocker stalls; argue-once-on-cited-shape is the per-probe backstop that covers every severity. New diff evidence that changes the cited shape resets the clock (the persistence test re-evaluates it fresh), which is the only legitimate path back to re-raising.

The existing persistence test (cited shape gone / present / ambiguously-addressed) runs *after* arbitration decides the probe survives the decline, exactly as today.

### Component 4 — `prompts/common-header.md`: trim the marker mention

Line 45's `pr-comments.md` input description: keep the "read it before re-emitting any probe you raised" guidance (specialists still use the thread as context), drop the "plus an operator-only `## Operator decline markers` count" clause and the "only the operator-marker channel drives mechanical suppression" clause. Replace with: arbitration of declined probes is the aggregator's job; specialists treat the thread as context only.

## Error handling / edge cases

- **First review (empty thread).** `pr-comments.md` is `(no PR comments)`; there are no prior declines; arbitration is a no-op. Unchanged behavior.
- **Operator declined, then the PR's diff actually addressed it.** The persistence test (cited shape gone) drops the probe regardless of the decline — that path is untouched.
- **Operator declined a finding the diff later re-introduced or worsened.** New diff evidence that defeats the decline's stated reason re-opens the probe (reinforce/re-litigate with the new evidence quoted) — this is the "new info resets the clock" path, and it's the legitimate reason to re-raise.
- **Participant (non-operator) pushes back.** Context only; never a decline. The arbiter may weigh it but cannot drop a probe on it.
- **Aggregator can't tell if it already argued.** When the cited-shape match is genuinely ambiguous, **default to defer** (drop), not to re-arguing. This is the deliberate inversion of the prior fuzzy channel's bias: re-raising on uncertainty is exactly what made #784 oscillate, so uncertainty must fall toward silence. Silence-is-golden (the aggregator's existing anti-emission stance) already says a padded re-raise costs more author trust than a missed probe; a genuinely live concern will re-surface with a *changed cited shape* once the author touches the code, which re-opens it legitimately via the persistence test.

## Testing

Behavior- and contract-focused, matching the existing smoke style:

- **`lib/tests/pr-comments-smoke.sh`** — delete fixtures 4 and 5 (operator-marker counting, participant-marker-injection). Add an assertion that the staged output contains **no** `## Operator decline markers` section and that a body containing `<!-- decline:class=X -->` is staged verbatim as ordinary thread prose (no special handling). Keep the Channel-1 trust/labeling/blockquote fixtures.
- **`lib/tests/prompt-contracts-smoke.sh`** — replace the marker-contract assertions with: (a) **no** prompt under `prompts/` references `decline:class` or `Operator decline markers`; (b) `aggregator.md` contains the argue-once / quote-the-operator / re-litigate contract (assert on the stable phrases `Argue once, then defer` and `deferred to operator after counter-argument`); (c) `aggregator.md` anchors argue-once on the **cited-shape identity** (assert the `cited-shape identity` token) — this is the load-bearing fence that stops a future edit from reverting the match to prose, which is what re-opens the #784 oscillation; (d) `critic.md` no longer contains a "Decline-history" section.
- **Real-world validation (optional, manual):** a replay against a #784-shaped fixture — a probe declined in prose across rounds with a re-shaped surface form — should converge (argue once, then defer) instead of re-rendering every round. This is the true end-to-end check; the smokes pin the contract, the replay pins the behavior.

No test asserts on LLM call order, mock counts, or internal structure — only on staged-output shape and prompt-contract presence (the user-observable contract).

## LOC accounting

Deletions: Channel 2 in `pr-comments.sh` (~35 lines incl. header doc), critic §Decline-history (~5 lines), the duplicated aggregator decline-drop paragraph, common-header marker clauses, and two smoke fixtures (~40 lines). Additions: the six-verdict arbitration block + convergence rule in `aggregator.md`, and the replacement contract assertions. Expected net: **neutral-to-negative**, with a concept removed (the marker channel) and a duplication removed (critic ⇄ aggregator decline logic collapsed to one site).
