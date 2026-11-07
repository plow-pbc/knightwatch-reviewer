# Complexity budget for every build: design (2026-11-07)

Asked by Sam in a direct message. Product stage: internal tool for Plow's own agents and repos (operator tooling, ~0 users). Plain review bar.

## 1. Intent
Sam no longer reads diffs. He still wants a sense of the architecture, approach and complexity of everything we build, and to make talking about complexity, and the tradeoffs that fit a company with ~0 users, a habit for every agent. Pre-PMF, unneeded complexity is what makes a codebase hard to pivot. The aim is managing growing codebase complexity without adding work for Sam.

What "complexity" means here (Sam, 11/6 infra review): moving parts and special cases a future pivot has to carry, not CPU cost or raw line count. Simplicity and developer time beat compute and latency. Prefer decisions that grow with us over whack-a-mole. Example: a Jev classifier (Plow's typed-decisions route) beats a pile of regexes, as simpler, more flexible and likely fewer lines.

## 2. Goals
- G1. Every PR, in every repo we own, states before review: the approach, the simpler or heavier alternative not taken, expected net LOC, and new moving parts (new services, stores, deps, concepts).
- G2. At convergence the PR states actual net LOC and new moving parts, and one verdict: complexity up, flat or down, with a one-line reason if up.
- G3. Gate: a PR is blocked for Sam's explicit OK when actual net LOC > expected + 0.4 × |expected| + 50 (Sam's rule; e.g. 1,000 expected, blocked above 1,450; for cleanups, deleting a bit less than promised passes).
- G4. Humans can track this at a glance without chat noise: one line per PR, at open and at convergence, in one dedicated Swarm room (#build-tracking, created by Sam).
- G5. Agents are nudged into the habit by the template and the reviewer, not by extra prompts in every agent.

## 3. Non-goals
- No dashboards, scoring formulas or cyclomatic metrics. LOC plus named moving parts is the signal.
- No change to how agents chat in core rooms: nothing about complexity goes in #general or DMs.
- Doesn't cover third-party repos.

## 4. Anti-goals (failure even if it works)
- Adds a new service or store to track complexity: that would be complexity about complexity.
- Floods any room. #build-tracking gets at most two lines per PR.
- Makes agents pad estimates to dodge the gate. The reviewer judges whether the expected figure was honest for the stated approach.

## 5. Decided (by Sam)
- Lives in knightwatch, which already reviews every PR. (Correction from the builder check: knightwatch doesn't read the declared size today; only babysit-pr Step 6.8 does, and knightwatch's size triggers count added lines against fixed limits. So Chunk 2 adds the body parsing.)
- One PR template shared by all PRs.
- The gate threshold: Sam's 1.4× + 50 rule, written canonically in G3.
- Swarm stays brief; tracking happens in a separate place.

## 5a. Decided by Sam (2026-11-07, after the builder check)
- Tracking lives in the Swarm room #build-tracking (created by Sam), not a page.
- Sam OKs a blocked PR by replying "ok" to its line in #build-tracking. Swarm authenticates the sender as Sam; a GitHub approval can't, because agents act on GitHub as Sam's account.

## 5a2. Template fields (Sam, 2026-11-07 13:38Z)
The PR template has:
1. Goal / business case, naming the user who requested it, if one did.
2. Current number of people outside the company actively using this software or infra (e.g. Swarm: about 1 design partner).
3. Original expected complexity: the minimal solution for that user count (e.g. fizzbuzz for 1 user is about 5 lines and n conditionals).
4. Key software or data-model architecture complexity being added.
Then expected and actual LOC and moving parts, and the verdict (§2). Example user counts in public templates use placeholders.
On every PR open, knightwatch posts a card summarizing what complexity is being added against the goal, and whether it judges that complexity legitimate.

## 5b. (Superseded by §5c.)

## 5c. Simplification after spec review (Cedar's call)
The review showed that putting Swarm posting and reply-reading inside knightwatch adds a process boundary, a credential and idempotency logic, the very complexity this design argues against. So the Swarm side moves to the agent that already runs `/babysit-pr` and already lives in Swarm:
- Knightwatch only reads the PR body, posts its complexity card as a GitHub PR comment (which persists the frozen expected figure and head SHA), and adds or clears `needs-sam`.
- The babysit-pr agent fills the template at open, posts one line to #build-tracking at open and one at convergence (actual figures and verdict), and, when `needs-sam` is set, waits for Sam's "ok" reply to that line. The reply is authenticated as Sam, and the line names the head SHA, so a new head after an ok needs a fresh ok.
- Canonical formula, matching Sam's example for positive estimates and the cleanup case: blocked when actual > expected + 0.4 × |expected| + 50. It replaces PR_LIFECYCLE's merge-authority tolerance everywhere that rule is restated.
- Field ownership: the agent writes expected LOC and moving parts at open, and actual LOC, actual moving parts and the verdict at convergence. Knightwatch checks actual LOC against the diff and judges legitimacy in its card.
- Expected is frozen at knightwatch's first card; later edits are flagged in the next card. A padded estimate gets a non-blocking note.
- Public repos: the "requested by" field names a role only, never a name or company (e.g. "a design-partner customer"). Real names go only in private repos.
- Accepted risk: if a babysit session restarts, a #build-tracking line may be posted twice. Harmless at our size, so no idempotency machinery.
- Scope: repos knightwatch already reviews that Sam's orgs own; other people's repos are skipped.

## Chunks

### Global Constraints
- Stage: internal operator tooling; plain review.
- No new service, store or credential. Knightwatch gains no Swarm code; Swarm work stays with the babysit-pr agent.
- One canonical size formula: blocked when actual > expected + 0.4 × |expected| + 50.
- #build-tracking: normally one line per PR at open and one at convergence (a restarted session may duplicate one; accepted).

### Chunk 1: PR template and inventory
Implements: §5a2, G1
Interfaces: produces the template fields every later chunk reads.
Done when: plow-pbc/.github has the org default template (PR for Sam's review); an inventory lists every owned repo knightwatch reviews and which have local templates; local templates (e.g. knightwatch-reviewer's) gain the same fields.

### Chunk 2: Knightwatch card and label
Implements: §5c, G2–G3
Interfaces: consumes Chunk 1's fields; produces a PR comment (card: complexity added vs goal, legitimacy verdict, frozen expected figure and head SHA) and the `needs-sam` label when over the formula.
Done when: on test PRs, an under-budget PR gets a card and no label; an over-budget one gets a card and the label; a PR missing fields gets one comment asking for them.

### Chunk 3: Merge-authority rules and the babysit-pr Swarm loop
Implements: §5a, §5c, G4
Interfaces: consumes Chunk 2's label and card; updates PR_LIFECYCLE.md line 25, the babysit-pr skill (both the Claude and the Codex copies) and AGENTS.md to the one formula, and adds the open and convergence lines plus the ok-wait to babysit-pr.
Done when: grep shows no other copy of the old tolerance; a real PR's two lines appear in #build-tracking; an over-budget test PR merges only after Sam's ok to the line naming its current head SHA.
