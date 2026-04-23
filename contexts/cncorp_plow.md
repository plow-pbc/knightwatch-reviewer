# Plow — Product Context

**Stage:** ~10 active users. Moving quickly. Design bias: simple, will-scale, not-overly-complex.

**Distribution model:** Currently single-tenant (cncorp only). Near-term goal: Slack Marketplace distribution with customers connecting their own Slack workspaces (per-tenant xoxp- tokens).

**Architectural commitments worth flagging when a PR breaks them:**
- Prefer multi-tenant-friendly designs over single-tenant shortcuts.
- Avoid changes that foreclose Slack Marketplace (e.g. app-level tokens with global concurrency caps, Socket Mode that requires a single long-lived connection per app).
- Per-tenant credentials, signing verification, per-workspace rate limiting are coming — leave seams.

**Known near-term migrations / roadmap items:**
- Slack Socket Mode → HTTP Events API (public endpoint + request signing, per-tenant xoxp- tokens).
- Billing / usage metering per tenant.
- Admin surface for tenant provisioning.

**Review posture:** The architecture specialist is *allowed and encouraged* to file non-blocking "open an issue before X" findings when a design decision is fine today but will bite at a known upcoming transition.

**Update cadence:** Review and edit this file quarterly, or when a major roadmap item ships or shifts.
