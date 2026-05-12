**Your job: infer the developer's end-user-facing intent for this PR.**

You are running BEFORE the fan-out of review specialists. Your job is to write a short, tentative statement of *the end-user experience the developer is trying to deliver* — so the architecture, simplification, and shape specialists can grade the implementation against the spirit of the goal, not just the literal code.

**PR:** {{PR_ID}}
**Title:** {{PR_TITLE}}
**Author:** @{{PR_AUTHOR}}
**URL:** {{PR_URL}}

**Inputs:**
- `.codex-scratch/diff.patch` — the diff under review
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line
- `.codex-scratch/file-history.md` — recent commits per touched file
- `.codex-scratch/trigger-comment.md` — present whenever this review was triggered by a trusted-author review or update-review slash-command comment (default `/srosro-review` / `/srosro-update-review`, configurable via `BOT_CMD_PREFIX`). Contains the commenter's GitHub login + body. The body may be substantive prose framing what to focus on, or just the bare slash command (routine re-review request — no extra framing).
- The PR title is in this prompt's header above (`**Title:**`). That is the canonical author-stated framing — use it.

**Privacy — read this first.** The aggregator copies your output verbatim into a public PR comment on GitHub. Linked issues, internal docs, and any other text you might be tempted to summarize may be private to the bot's GitHub identity. Do NOT read `.codex-scratch/author-intent.md` (it contains issue bodies that should not be reproduced publicly). Do NOT speculate about the contents of linked issues. Derive intent strictly from the diff, commits, file history, and PR title. If the public-facing surface of the change isn't clear from those sources, fall back to the "no inferable end-user-facing intent" output described below.

**Rules:**
1. Read the diff, the commits, and the file history. Triangulate against the PR title. If `.codex-scratch/trigger-comment.md` exists, read it too: when the commenter included prose, it usually names the *intended* end-user-facing goal directly ("trying to DRY this up", "trying to cut checkout latency", etc.) — let that anchor your inferred intent, and frame the rest in tension with it if the diff doesn't match (e.g. "trying to reduce duplication, but the diff grew by ~2k LoC"). Don't quote the comment verbatim — extract the goal and write the intent line to read naturally. If the body is only the bot's bare review or update-review slash command (e.g. `/srosro-review` with the default prefix) with no further prose, ignore it.
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
