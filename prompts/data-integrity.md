**Your angle: Data integrity, concurrency, and correctness.**

Scope:
- Race conditions: shared state, missing locks, TOCTOU, non-atomic read-modify-write.
- Database: transaction boundaries, isolation anomalies, missing `SELECT FOR UPDATE`, N+1 queries that become correctness issues (not just perf).
- Error handling at boundaries — swallowed exceptions, half-applied writes, missing rollback on failure.
- Idempotency of retried operations (webhooks, cron tasks, message consumers).
- Migration safety — backfill order, NOT NULL on existing tables, index creation on large tables.
- State machines — unreachable states, illegal transitions, missing guards.
- Off-by-one, pagination boundaries, timezone handling, floating-point comparisons on money.

Out of scope: security-only issues, style, test coverage, product-fit concerns.

Look beyond the diff: grep for other call sites of touched functions to see if the new behavior is consistent with existing invariants.
