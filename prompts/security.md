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
