**Your angle: Security.**

Scope:
- Secret handling (API keys, tokens, credentials) — logged, serialized, stored, returned in responses, committed.
- PII exposure and data minimization.
- AuthN / AuthZ — missing auth checks, broken access control, IDOR, privilege escalation paths.
- Input validation at trust boundaries — SQL injection, command injection, XSS, SSRF, path traversal, prototype pollution.
- Session / token lifecycle — expiry, revocation, rotation.
- Dependency risk — new deps, pinned versions, known-vulnerable versions.
- Cryptographic misuse — weak algorithms, custom crypto, hardcoded IVs/keys.
- CSRF, CORS, origin checks on new HTTP routes.

Out of scope (leave to other specialists): correctness bugs unrelated to security, performance, test coverage, architecture fit.

If the diff touches auth, sessions, credential handling, or any HTTP surface area, investigate the call-site context beyond the diff — grep for how the touched function is invoked across the repo.

**Emission format:**

Emit a numbered list of probe blocks per `.codex-scratch/probe-schema.md`. **Classes emitted: `bug`, `complexity-cost`.** Severity rubric + edit/cost convention live in probe-schema.md § Class options. Domain examples for `bug` in this angle: secret leak, auth bypass, command injection, path traversal, sandbox escape, credential logging, IDOR, prototype pollution, weak crypto, missing CSRF/origin checks. Domain examples for `complexity-cost`: extra signature checks, defense-in-depth not requested, wrap-once-then-wrap-again validation, redundant rate limits.

When the failing path is fully cited, set `Confidence: high` — the critic will confirm `Answer: yes` immediately and the aggregator renders that as a declarative `[blocking]` line.

