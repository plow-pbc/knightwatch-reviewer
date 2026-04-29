# Orchestrator Worker Detach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `review.sh` (the orchestrator) exit in <1s after dispatching workers, so the next 2-min `pr-reviewer.timer` tick can pick up new `/srosro-update-review` triggers without waiting for the previous worker(s) to finish.

**Architecture:** Two changes that work together: (a) systemd unit `KillMode=process` so children of the oneshot orchestrator survive when the main process exits; (b) drop the post-fan-out `wait` loop in `review.sh` so the orchestrator returns immediately after launching workers. The bounded-concurrency `wait -n` inside the dispatch loop stays — it caps spikes when many PRs are eligible at once, which is rare. Workers continue running independently and write their own `runs/<id>/run.log`; orchestrator failures inside workers are surfaced via those logs and the per-worker journal entries, not via the orchestrator's exit code.

**Why this matters:** Today, `pr-reviewer.service` is `Type=oneshot` and `review.sh`'s tail does `wait` for every fork. Workers take 15–20 minutes each (multi-specialist codex flow). While the orchestrator is in that final `wait` loop, the next 2-min timer firing is dropped — systemd doesn't start a new oneshot while the previous is still active. A `/srosro-update-review` arriving 30 seconds after a worker started waits ~16 min for that worker to drain before the next orchestrator tick observes it. Confirmed on PR #534: trigger at `17:30:48Z`, picked up at `17:46:05Z`.

**Tech Stack:** bash, systemd (`Type=oneshot`, `KillMode=`), shell job control.

**Files touched:**
- `systemd/pr-reviewer.service` — add `KillMode=process`
- `review.sh` — drop the post-fan-out `wait` loop; adjust closing log line
- `lib/tests/orchestrator-skip-smoke.sh` — add a regression scenario asserting the orchestrator returns quickly even when a worker is still running

---

### Task 1: Regression test — orchestrator returns quickly with running workers

**Files:**
- Modify: `lib/tests/orchestrator-skip-smoke.sh` — add new scenario at end

**Why this first:** Without this, a future regression that re-introduces the `wait` loop (or removes `KillMode=process` and the cgroup kills children) would land green. The test must fail on the OLD code to be a real regression test.

- [ ] **Step 1: Read the current end of orchestrator-skip-smoke.sh**

```bash
tail -20 lib/tests/orchestrator-skip-smoke.sh
```

Expected: ends with the existing scenario 8's PASS line and no trailing scenarios.

- [ ] **Step 2: Add scenario 9 — slow worker, orchestrator returns within 5s**

Replace the file's final PASS line with the new scenario plus an updated PASS line.

Find this exact block (currently the file's tail):
```bash
echo "  PASS (8 scenarios: no-comments, bare-mention, /srosro-review, marker-self-filter, single-account, untrusted-trigger-comment, /srosro-update-review-same-sha, /srosro-approve-not-a-review)"
```

Replace with:
```bash
# Scenario 9: orchestrator returns quickly even when a worker is still
# running. Pre-detach behavior had the orchestrator `wait` for every
# forked worker before exiting, so a slow worker (15–20 min in
# production) blocked the next 2-min timer firing and made
# /srosro-update-review pickup unboundedly slow. With the post-fan-out
# `wait` loop removed, the orchestrator must dispatch the worker and
# return promptly, regardless of worker runtime.
echo "  scenario 9: slow worker — orchestrator returns within 5s, worker keeps running..."
# Replace the worker stub with one that sleeps "indefinitely" (long
# enough that the orchestrator's `wait` would block the test if it
# regressed). Tee a marker file so we can confirm the worker actually
# started before asserting orchestrator timing.
WORKER_MARKER="$TMPDIR/worker-started.flag"
cat > "$REVIEWER_LIB_DIR/review-one-pr.sh" <<WORKER
#!/bin/bash
echo "WORKER_DISPATCHED repo=\$1 pr=\$2 sha=\$3 force_whole=\$6 trigger_file=\${TRIGGER_COMMENT_FILE:-}" >> "$LOG_FILE"
touch "$WORKER_MARKER"
sleep 60   # would block orchestrator's old `wait` loop
WORKER
chmod +x "$REVIEWER_LIB_DIR/review-one-pr.sh"

printf '[{"created_at":"%s","user":{"login":"someuser"},"body":"/srosro-review"}]\n' "$NOW_ISO" > "$MOCK_COMMENTS_FILE"

# Time the orchestrator. If it returns in <5s the wait was correctly
# dropped; if it sits at 60s the regression is back.
: > "$LOG_FILE"
START=$(date +%s)
bash "$PROJECT_ROOT/review.sh" >/dev/null 2>&1 &
ORCH_PID=$!
# Cap the test at 10s so a regression doesn't hang CI for a full minute.
TIMEOUT=10
ELAPSED=0
while kill -0 "$ORCH_PID" 2>/dev/null; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        kill "$ORCH_PID" 2>/dev/null
        echo "FAIL scenario 9 (wait-loop regression): orchestrator did not return within ${TIMEOUT}s — likely waiting on the slow worker"
        echo "--- log ---"; cat "$LOG_FILE"
        # Reap the still-running worker so the trap's rm -rf can run.
        pkill -P "$ORCH_PID" 2>/dev/null || true
        exit 1
    fi
done
END=$(date +%s)
ORCH_ELAPSED=$((END - START))

[ "$ORCH_ELAPSED" -lt 5 ] || { echo "FAIL scenario 9: orchestrator took ${ORCH_ELAPSED}s, expected <5s"; cat "$LOG_FILE"; exit 1; }

# Sanity: the worker actually got dispatched (not just orchestrator
# bailing before it even forked).
[ -f "$WORKER_MARKER" ] || { echo "FAIL scenario 9: worker never started — orchestrator may have errored before fan-out"; cat "$LOG_FILE"; exit 1; }

# Reap the sleeping worker so the test exits cleanly.
pkill -f "sleep 60" 2>/dev/null || true

echo "  PASS (9 scenarios: no-comments, bare-mention, /srosro-review, marker-self-filter, single-account, untrusted-trigger-comment, /srosro-update-review-same-sha, /srosro-approve-not-a-review, slow-worker-fast-exit)"
```

- [ ] **Step 3: Run the new test against the CURRENT (still-broken) code to confirm it fails**

Run: `bash lib/tests/orchestrator-skip-smoke.sh`

Expected: FAIL on scenario 9 with `orchestrator did not return within 10s` (because the unfixed `review.sh` is still waiting on the worker's `sleep 60`).

This is the red-bar moment. If scenario 9 passes against the unfixed code, the test isn't actually exercising the bug — fix the test before continuing.

- [ ] **Step 4: Commit just the failing test**

```bash
git add lib/tests/orchestrator-skip-smoke.sh
git commit -m "test(orchestrator-skip): scenario 9 — orchestrator must exit fast with a running worker

Currently red. Locks the regression that motivated the worker-detach
fix: pr-reviewer.service is Type=oneshot and review.sh's tail does
wait for every forked worker, so a slow worker (15–20 min in
production) blocks the next 2-min timer firing and makes
/srosro-update-review pickup unboundedly slow.

Goes green in the next commit."
```

---

### Task 2: systemd unit — `KillMode=process` so workers survive orchestrator exit

**Files:**
- Modify: `systemd/pr-reviewer.service` — add `KillMode=process` to the `[Service]` section

**Why:** With the default `KillMode=control-group`, when the orchestrator's `ExecStart` returns systemd kills all processes in the unit's cgroup — including the workers we just dropped the `wait` for. `KillMode=process` tells systemd to track only the main process; children are left alone and reparent to PID 1 when the orchestrator exits.

- [ ] **Step 1: Read the current `[Service]` section**

```bash
sed -n '/^\[Service\]/,/^\[/p' systemd/pr-reviewer.service
```

Expected: a block starting `[Service]`, containing `Type=oneshot`, `User=odio`, etc., NOT containing `KillMode=`.

- [ ] **Step 2: Add `KillMode=process` after `Type=oneshot`**

In `systemd/pr-reviewer.service`, find this exact line:
```
Type=oneshot
```

Replace with:
```
Type=oneshot
# KillMode=process so workers survive the orchestrator's exit. With the
# default `control-group` mode, systemd would kill every process in the
# unit's cgroup when ExecStart returns — including the detached workers
# review.sh just spawned. With `process`, only the main process (review.sh)
# is tracked for kill purposes; workers reparent to PID 1 and run to
# completion independently.
KillMode=process
```

- [ ] **Step 3: Verify the diff is exactly one logical change**

Run: `git diff systemd/pr-reviewer.service`

Expected: only one hunk added, three lines (the comment and the directive).

- [ ] **Step 4: Commit**

```bash
git add systemd/pr-reviewer.service
git commit -m "fix(orchestrator): KillMode=process so workers survive review.sh exit

Pairs with the next commit (drop the post-fan-out wait in review.sh).
Without KillMode=process, when the orchestrator's ExecStart returns,
systemd's default control-group kill mode SIGTERMs every process in
the unit cgroup — including the workers we just stopped waiting for.
KillMode=process tells systemd to track only the main process, so
detached workers reparent to PID 1 and run to completion."
```

---

### Task 3: review.sh — drop the post-fan-out `wait` loop

**Files:**
- Modify: `review.sh:216-228` — drop the second `wait` loop, simplify exit logic

**Why:** This is the actual fix that makes the orchestrator exit fast. The in-loop `wait -n` (lines 202-207) stays — it's the bounded-concurrency cap, which is fine; in practice rarely is `MAX_CONCURRENT=8` saturated. The post-loop `wait` (216-221) is what's blocking the 2-min timer. Drop it. Workers' exit codes can no longer be tracked by the orchestrator, so the closing-log line just reports the dispatch count.

- [ ] **Step 1: Read the current tail of review.sh**

Run: `sed -n '190,229p' review.sh`

Expected to see:
```bash
# ---------- fan out with bounded concurrency ----------
...
active=0
FAILED=0
for spec in "${ELIGIBLE[@]}"; do
    ...
    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        if ! wait -n; then
            FAILED=$((FAILED + 1))
        fi
        active=$((active - 1))
    done

    TRIGGER_COMMENT_FILE="$TRIGGER_FILE" \
    REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
        "$REVIEWER_LIB_DIR/review-one-pr.sh" \
        "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
    active=$((active + 1))
done

while [ "$active" -gt 0 ]; do
    if ! wait -n; then
        FAILED=$((FAILED + 1))
    fi
    active=$((active - 1))
done

if [ "$FAILED" -gt 0 ]; then
    log "Fan-out complete with $FAILED worker failure(s) out of ${#ELIGIBLE[@]}"
    exit 1
fi
log "Fan-out complete (${#ELIGIBLE[@]} review(s) ended)"
exit 0
```

- [ ] **Step 2: Replace the tail with a fast-exit version**

Find this exact block:
```bash
while [ "$active" -gt 0 ]; do
    if ! wait -n; then
        FAILED=$((FAILED + 1))
    fi
    active=$((active - 1))
done

if [ "$FAILED" -gt 0 ]; then
    log "Fan-out complete with $FAILED worker failure(s) out of ${#ELIGIBLE[@]}"
    exit 1
fi
log "Fan-out complete (${#ELIGIBLE[@]} review(s) ended)"
exit 0
```

Replace with:
```bash
# Detached fan-out: workers are running in the background and will
# continue past this script's exit (KillMode=process on the systemd
# unit; children reparent to PID 1). We do NOT wait for them — the
# orchestrator's job is to enumerate eligible PRs and dispatch; per-
# worker outcomes land in $STATE_DIR/runs/<id>/run.log and the systemd
# journal. Without this, the next 2-min timer tick is blocked until the
# slowest worker finishes (15–20 min in production), making
# /srosro-update-review pickup unboundedly slow.
log "Fan-out: dispatched ${#ELIGIBLE[@]} worker(s) (detached, running in background)"
exit 0
```

- [ ] **Step 3: Run the new scenario 9 — should now PASS**

Run: `bash lib/tests/orchestrator-skip-smoke.sh`

Expected: all 9 scenarios pass, including the new `slow-worker-fast-exit`. Orchestrator returns in <5s even though the worker stub is still sleeping in the background.

If scenario 9 still fails: check that the in-loop `wait -n` (the bounded-concurrency cap) didn't accidentally get hit by a small `MAX_CONCURRENT`. The default is 8; scenario 9 only dispatches 1 PR so the cap shouldn't be reached.

- [ ] **Step 4: Run the full suite**

Run: `just test`

Expected: every smoke green. The new scenario rides under `orchestrator skip smoke test`. The `Fan-out complete` log line changed, so any test that grepped for that exact string will fail — none should, but a quick `grep -r 'Fan-out complete' lib/tests/` confirms.

- [ ] **Step 5: Commit**

```bash
git add review.sh
git commit -m "fix(orchestrator): drop post-fan-out wait so workers detach cleanly

Pairs with KillMode=process on the unit. The orchestrator now logs
'Fan-out: dispatched N worker(s) (detached, ...)' and exits in <1s
instead of waiting 15–20 minutes for the slowest worker. Next 2-min
timer tick reliably picks up /srosro-update-review triggers regardless
of worker queue.

Per-worker outcomes still land in \$STATE_DIR/runs/<id>/run.log and
the systemd journal; the orchestrator's exit code no longer reflects
worker success/failure (it can't, since they're detached). The in-loop
bounded-concurrency wait stays as a spike cap.

Closes scenario 9 of orchestrator-skip-smoke.sh."
```

---

### Task 4: Open the PR

- [ ] **Step 1: Push the branch**

Run: `git push -u origin <branch-name>`

- [ ] **Step 2: `gh pr create` with this body**

```markdown
## Summary
Orchestrator (`review.sh`) now exits in <1s after dispatching workers, eliminating the multi-minute pickup delay for `/srosro-update-review` triggers arriving while a worker is running (e.g. PR #534's recent 15-min lag).

## What changed
- **`systemd/pr-reviewer.service`**: `KillMode=process` so workers survive the orchestrator's exit. Without this, the default `control-group` mode would SIGTERM every process in the unit cgroup, killing the workers we just stopped waiting for.
- **`review.sh`**: dropped the post-fan-out `wait` loop. The in-loop `wait -n` (bounded-concurrency cap) stays. New closing log line: `Fan-out: dispatched N worker(s) (detached, running in background)`.
- **`lib/tests/orchestrator-skip-smoke.sh`**: scenario 9 — slow worker, orchestrator must return within 5s. Locks the regression.

## Test plan
- [x] `just test` — all smokes green, including the new scenario 9.
- [ ] After merge + install, post a `/srosro-update-review` while another worker is running and confirm pickup within ~2 min instead of waiting for the previous worker.
- [ ] Tail `~/.pr-reviewer/orchestrator.log`: every tick should now log either `No PRs need review` or `Fan-out: dispatched N worker(s) (detached, ...)` and return immediately.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 3: Babysit the PR through to merge**

Use the standard PR-comment-triage loop (poll knightwatch, reply, fix valid findings, repeat until findings: none, then merge).
