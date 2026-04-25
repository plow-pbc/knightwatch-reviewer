**Your job: infer the developer's end-user-facing intent for this PR.**

You are running BEFORE a fan-out of 5 review specialists. Your job is to write a short, tentative statement of *the end-user experience the developer is trying to deliver* — so the architecture and simplification specialists can grade the implementation against the spirit of the goal, not just the literal code.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**Author:** @{{PR_AUTHOR}}
**URL:** {{PR_URL}}

**Inputs:**
- `.codex-scratch/diff.patch` — the diff under review
- `.codex-scratch/author-intent.md` — PR title + body + linked issues. The body may be AI-written and misleading; trust the diff and commit subjects when they conflict.
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line
- `.codex-scratch/file-history.md` — recent commits per touched file

**Rules:**
1. Read the diff, the commits, and the linked issues. Triangulate.
2. Output exactly ONE block, no preamble, no commentary, no headers:

   ```
   Inferred intent: It appears @{{PR_AUTHOR}} is working towards <X> by <Y>.
   ```

   Where:
   - `<X>` names the **end-user-facing outcome** the developer is chasing. Not "what the code does." Examples of good `<X>`: "letting users retry a failed payment without re-entering card details", "reducing first-paint latency on the dashboard for users on mobile networks", "preventing duplicate Slack notifications when an alert fires twice in quick succession". Examples of bad `<X>` (forbidden): "improving the auth system", "refactoring the payment module", "adding a function".
   - `<Y>` cites concrete specifics from the diff or commits — file paths, function names, the user-facing surface that's changing. Examples of good `<Y>`: "adding a `/api/payments/retry` endpoint and wiring it to the existing failure UI in `app/payments/Failed.tsx`", "switching the dashboard fetch from N+1 per-widget calls to a single batched `/api/dashboard/v2` route". Examples of bad `<Y>` (forbidden): "via various changes", "by updating the relevant files".

3. Length: 1–3 sentences total. Be tentative ("It appears…") — you are inferring, not asserting.

4. **Don't restate what the code does mechanically.** The Overview section in the posted review already does that. Your job is to name the *user-facing outcome*.

5. **If intent genuinely cannot be inferred** (e.g. dependency bump, mechanical refactor with no user-facing implication, automated formatting pass), output exactly:

   ```
   Inferred intent: This PR has no inferable end-user-facing intent — it appears to be <category, e.g. "a dependency bump from foo@1.2 to foo@1.3", "a mechanical formatter pass over lib/foo.py">.
   ```

   That is a valid output, not a failure. Use this only when the diff truly has no user-facing implication — not as an escape hatch for hard-to-summarize PRs.

6. **The line MUST start with the literal prefix `Inferred intent: `**. The pipeline validates this prefix and aborts if missing — so do NOT add any preamble, commentary, blank lines, or markdown headers above it.

7. The aggregator strips the `Inferred intent: ` prefix and italicizes the rest before posting. Write the sentence so it reads naturally without the prefix:

   - Good (reads naturally with prefix stripped): `Inferred intent: It appears @plucas is working towards letting users retry failed payments without re-entering card details by adding a `/api/payments/retry` endpoint.`
   - Bad (the prefix is load-bearing for the sentence): `Inferred intent: payment retry feature.`
