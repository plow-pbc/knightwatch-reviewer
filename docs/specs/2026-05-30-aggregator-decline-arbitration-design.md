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
| **re-litigate** | The aggregator disagrees AND (it has not yet argued this probe, OR the operator's reply added no new info / missed a key point the code shows). | Render the probe, **quoting the operator and countering against the code**: *"You said X is okay because Z, but `file:line` shows Y, which means …"* The counter MUST cite a specific, unaddressed, substantive point. |
| **defer** | The aggregator already argued this probe once (its counter is in `prior-reviews.md`) AND the operator engaged substantively and held position. | Drop. Footnote: `Probe resolved: deferred to operator after counter-argument — they own the call.` |
| **edit** | The comment partially changes the calculus. | Render a *narrowed* probe — lower severity and/or tighter scope — folding in the operator's point and naming what changed. |
| **reinforce** | The comment confirms the finding or reveals a worse case. | Render at full or higher severity, citing the comment as corroboration. |
| **rank** | The comment doesn't resolve but signals engagement. | Order an engaged-but-unresolved finding above untouched leaf probes within its severity band. |

**The convergence rule, stated for the prompt:**

> Argue once, then defer. You may render a counter-opinion on a declined probe *once* (check `prior-reviews.md` — if a prior round's output already quotes the operator and counters this same finding, you have argued it). After that, if the operator engaged your counter and held position, **defer** — drop the probe; they own the code. Re-litigate *past* the first argument ONLY when the operator's reply added no new information or did not address a specific key point — and then your re-litigation MUST quote the unaddressed point and cite the code shape that contradicts it (*"You said … because Z, but `file:line` shows Y …"*). If you have no specific, unaddressed, substantive point to quote, you must defer. A re-raise that merely re-words the prior probe is forbidden — that is the oscillation this rule exists to kill.

This is grounded in the prior discussion by construction: every re-litigation quotes the operator's words and references what's already been said. The deleted `≥3 marker count` is replaced by this rule; the T2 blocker-stall banner remains the PR-level backstop if a probe somehow keeps re-opening.

**Matching is by substance, not surface.** The arbiter matches a re-emitted finding to a prior decline by what it *is* (the cited path / contract / rationale and the underlying mechanism), not by its wording or `Class`. The #784 finding that re-shaped its surface form every round (instanceExists → digest-planning → "bound the sweep") is, by substance, one finding — the arbiter must recognize it as such and apply argue-once across the re-shapings, not treat each rewording as fresh.

The existing persistence test (cited shape gone / present / ambiguously-addressed) runs *after* arbitration decides the probe survives the decline, exactly as today.

### Component 4 — `prompts/common-header.md`: trim the marker mention

Line 45's `pr-comments.md` input description: keep the "read it before re-emitting any probe you raised" guidance (specialists still use the thread as context), drop the "plus an operator-only `## Operator decline markers` count" clause and the "only the operator-marker channel drives mechanical suppression" clause. Replace with: arbitration of declined probes is the aggregator's job; specialists treat the thread as context only.

## Error handling / edge cases

- **First review (empty thread).** `pr-comments.md` is `(no PR comments)`; there are no prior declines; arbitration is a no-op. Unchanged behavior.
- **Operator declined, then the PR's diff actually addressed it.** The persistence test (cited shape gone) drops the probe regardless of the decline — that path is untouched.
- **Operator declined a finding the diff later re-introduced or worsened.** New diff evidence that defeats the decline's stated reason re-opens the probe (reinforce/re-litigate with the new evidence quoted) — this is the "new info resets the clock" path, and it's the legitimate reason to re-raise.
- **Participant (non-operator) pushes back.** Context only; never a decline. The arbiter may weigh it but cannot drop a probe on it.
- **Aggregator can't tell if it already argued.** If `prior-reviews.md` is ambiguous, treat as "not yet argued" and allow one counter — erring toward one extra surfaced opinion is cheaper than silent suppression, and the substance-match + quote-the-unaddressed-point requirement still bounds it.

## Testing

Behavior- and contract-focused, matching the existing smoke style:

- **`lib/tests/pr-comments-smoke.sh`** — delete fixtures 4 and 5 (operator-marker counting, participant-marker-injection). Add an assertion that the staged output contains **no** `## Operator decline markers` section and that a body containing `<!-- decline:class=X -->` is staged verbatim as ordinary thread prose (no special handling). Keep the Channel-1 trust/labeling/blockquote fixtures.
- **`lib/tests/prompt-contracts-smoke.sh`** — replace the marker-contract assertions with: (a) **no** prompt under `prompts/` references `decline:class` or `Operator decline markers`; (b) `aggregator.md` contains the argue-once / quote-the-operator / re-litigate-requires-unaddressed-point contract (assert on the stable phrases); (c) `critic.md` no longer contains a "Decline-history" section.
- **Real-world validation (optional, manual):** a replay against a #784-shaped fixture — a probe declined in prose across rounds with a re-shaped surface form — should converge (argue once, then defer) instead of re-rendering every round. This is the true end-to-end check; the smokes pin the contract, the replay pins the behavior.

No test asserts on LLM call order, mock counts, or internal structure — only on staged-output shape and prompt-contract presence (the user-observable contract).

## LOC accounting

Deletions: Channel 2 in `pr-comments.sh` (~35 lines incl. header doc), critic §Decline-history (~5 lines), the duplicated aggregator decline-drop paragraph, common-header marker clauses, and two smoke fixtures (~40 lines). Additions: the six-verdict arbitration block + convergence rule in `aggregator.md`, and the replacement contract assertions. Expected net: **neutral-to-negative**, with a concept removed (the marker channel) and a duplication removed (critic ⇄ aggregator decline logic collapsed to one site).
