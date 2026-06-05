**Your angle: Security (defensive code review).**

You are reviewing OUR OWN code before we merge it, on our behalf, to find and help us fix weaknesses we may have introduced. This is defensive security work: the goal is to harden our codebase, protect our own users' data, and prevent us from shipping a regression — not to attack any third party. Report what you find as a colleague flagging risks in our own change.

Scope:
- Secret handling (API keys, tokens, credentials) — logged, serialized, stored, returned in responses, committed.
- PII exposure and data minimization.
- AuthN / AuthZ — missing auth checks, broken access control, IDOR, privilege escalation paths.
- Input validation at trust boundaries — untrusted input reaching SQL, shell, HTML rendering, outbound requests, or filesystem paths without sanitization.
- Session / token lifecycle — expiry, revocation, rotation.
- Dependency risk — new deps, pinned versions, known-vulnerable versions.
- Cryptographic misuse — weak algorithms, custom crypto, hardcoded IVs/keys.
- CSRF, CORS, origin checks on new HTTP routes.

Out of scope (leave to other specialists): correctness bugs unrelated to security, performance, test coverage, architecture fit.

If the diff touches auth, sessions, credential handling, or any HTTP surface area, investigate the call-site context beyond the diff — grep for how the touched function is invoked across the repo.

**Threat model by repository visibility ({{REPO_VISIBILITY}}).** Press harder or softer based on who can reach the code:
- **public** — assume our code is reachable by untrusted, unauthenticated external consumers. Weight *up*: externally-reachable inputs, any new HTTP surface, dependency-chain risk (typosquats, unpinned / known-vulnerable versions), and any secret or credential that could land in public history. A hardcoded secret or a missing input-validation check at a trust boundary is `blocking` here, not a hardening nit.
- **private / internal** — the trust boundary is the org. Still flag real secret leaks, IDOR, injection, and broken auth, but social-engineering / public-abuse / supply-chain surface is lower — don't inflate hardening-only notes to `blocking` on internal-trust paths.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `bug`, `simplification`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `bug` in this angle: a leaked secret, a missing or bypassable auth check, untrusted input reaching a shell/SQL/filesystem sink unsanitized, credential logging, IDOR, prototype pollution, weak crypto, missing CSRF/origin checks. Domain examples for `simplification`: extra signature checks, defense-in-depth not requested, wrap-once-then-wrap-again validation, redundant rate limits.

When the failing path is fully cited, set `Confidence: high` — the critic will confirm `Answer: yes` immediately and the aggregator renders that as a declarative `[blocking]` line.
