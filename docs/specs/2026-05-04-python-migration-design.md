# Python Migration: per-angle critics, no splitter

**Date:** 2026-05-04
**Status:** approved (brainstorming complete; awaiting implementation plan)
**Scope:** pipeline orchestration only — `lib/orchestrate.sh`, `lib/critic-splitter.sh`, `lib/run-specialist.sh`, `lib/prompt-build.sh`. Systemd units, timer scripts, shell helpers untouched.

## Why

`lib/critic-splitter.sh` is a deterministic shell parser of LLM-shaped text. Each PR-review round produces another byte-level edge case (whitespace-only sections, missing fields, partial blocks); each fix adds a grep gate or a prompt sentinel. This is the opposite of the "Broken-Glass Test" — the system gets more brittle, the prompts get more verbose.

The structural fix is to **eliminate the splitter entirely** by giving each specialist its own per-angle critic. Per-angle critics already target one specialist's file, so there's nothing to route. No parser → no parser edge cases.

The shell-to-Python migration is incidental: once the splitter is gone, the remaining pipeline orchestration (parallel codex fanout, per-agent artifact management) is much cleaner in Python's `concurrent.futures` than in shell's `&` + per-PID `wait` pattern.

## Architecture

```
            ┌─ intent (codex)              ─→ inferred-intent.md
            │
            ├─ dead-code-search (codex)    ─→ dead-code.md
            │
            │  [parallel × 8 angles, each angle = specialist → critic sequential]
            ├─ specialist[security] → critic[security]   ─→ specialists/security.md
            ├─ specialist[shape]    → critic[shape]      ─→ specialists/shape.md
            ├─ ... (6 more) ...
            │
            ├─ momentum (codex, re-reviews only)         ─→ momentum.md
            │
            └─ aggregator (reads all of the above)       ─→ posted review
```

**Key design points:**

- **One Python entrypoint**: `lib/pipeline.py` (~200 LOC). Replaces `lib/orchestrate.sh`'s `run_specialist_pipeline`, `dispatch_agent`, `persist_layered_specialists`. Pure stdlib (`subprocess`, `pathlib`, `concurrent.futures`).
- **Per-angle pipelines run in parallel** via `ThreadPoolExecutor(max_workers=8)`. Each angle pipeline runs specialist→critic sequentially; the critic reads ONE specialist's output.
- **No central critic. No splitter. No router.** Each per-angle critic appends `## Critic counter-arguments` directly to its specialist's file.
- **No pydantic, no JSON.** All inter-stage data flow stays markdown. The aggregator (an LLM) is the sole consumer of the per-angle files; it parses markdown fine.
- **codex call topology**: 1 (intent) + 1 (dead-code) + 16 (8 specialist + 8 critic) + 1 (momentum, re-reviews only) + 1 (aggregator) = ~19 codex calls per review. Wall-clock unchanged (per-angle critic adds critic-time, but it's parallel-bounded by max angle pipeline).

**Trade-offs:**

| | Win | Cost |
|---|---|---|
| Kills `lib/critic-splitter.sh` (~134 LOC) + smoke (~270 LOC) | Yes | — |
| Kills the BCR-recurring class (no parser → no parser edge cases) | Yes | — |
| Critic prompt simplifies (no cross-angle resolution shape, no `## Generated probes`, no carry-forward routing) | Yes | — |
| Cross-angle pattern spotting | Lost | Aggregator absorbs (it's already cross-angle by design) |
| Token usage | Roughly equivalent (per-angle critics see ~1/8 the context each, 8× more calls — net ~same) | Slight API-call overhead increase |

## Components

**New (Python):**
- `lib/pipeline.py` — single file with: `run_codex()` (subprocess wrapper around `codex exec`), `build_prompt()` (placeholder substitution + common-header concat + voice.md stitch), `run_angle()` (specialist → critic), `run_pipeline()` (main entrypoint).

**Updated (shell — unchanged language):**
- `lib/review-one-pr.sh` — invokes `python3 lib/pipeline.py` where it currently calls `run_specialist_pipeline`.
- `lib/replay.sh` — calls Python entrypoint instead of sourcing `orchestrate.sh`.
- `prompts/critic.md` — substantial rewrite. Becomes a per-angle critic prompt: reads ONE specialist's output, emits Answer/Evidence per probe, optionally generates new probes within that angle. Drops cross-angle resolution shape, `## Generated probes` section, carry-forward routing prose, the `No probes.` sentinel from R36.
- `prompts/aggregator.md` — small update absorbing cross-angle pattern-spotting (the work today's central critic does).
- `install.sh` — add `python3 --version` precondition check. No pip dependencies (stdlib only).
- `justfile` — add `python3 -m unittest discover -s lib/tests -p 'test_*.py'` line.
- `lib/tests/prompt-contracts-smoke.sh` — drop splitter-token + dispatch-agent assertions; keep wiring fences.

**Deleted:**
- `lib/orchestrate.sh` (~250 LOC)
- `lib/critic-splitter.sh` (~134 LOC)
- `lib/run-specialist.sh` (~70 LOC)
- `lib/prompt-build.sh` (~80 LOC)
- `lib/tests/critic-splitter-smoke.sh` (~270 LOC)
- `lib/tests/dispatch-agent-smoke.sh` (~340 LOC)
- `lib/tests/run-specialist-smoke.sh` (~150 LOC)
- `lib/tests/build-specialist-prompt-smoke.sh` (sized similarly)

**Unchanged:**
- All other `lib/*.sh` helpers (`state-io.sh`, `run-dir.sh`, `gh-comments.sh`, `tracked-repos.sh`, `auth.sh`, `decline-history.sh`, `loc-trend.sh`, `scratch.sh`, `path-scrub.sh`, `locking.sh`, `knightwatch-config.sh`, `search-roots.sh`, `sibling-symlinks.sh`, `diff-build.sh`, `go-deep-rank.sh`, `checks/*`).
- `review.sh`, `learn-from-replies.sh`, `approve-from-replies.sh`, `plow-kid-refresh.sh`, `re-request-poller.sh`.
- All other smokes (~16 files, untouched).
- All systemd unit files.
- All other prompt files (8 specialist prompts, intent.md, momentum.md, dead-code-search.md, go-deep.md, common-header.md, voice.md, probe-schema.md).

**Net delta**: ~−800 LOC of shell + ~200 LOC of Python = **~−600 LOC net**, plus the entire BCR-recurring class of bugs.

## Data flow

**Per-codex-call artifacts** (unchanged from today):

```
RUN_DIR/agents/<name>/
    prompt.txt          ← the prompt fed to codex
    output.md           ← codex's response
    log.txt             ← start/exit markers + stderr
```

`<name>` is one of: `intent`, `dead-code-search`, `security`, `shape`, ..., `consumers`, `momentum`, `critic-security`, `critic-shape`, ..., `critic-consumers`, `aggregator`. Per-angle critics get their own `agents/critic-<angle>/` dir, parallel to today's `go-deep-<angle>` convention.

**Per-angle pipeline** (`run_angle`):

```python
def run_angle(angle: str, ...):
    # 1. run specialist
    spec_out = run_codex(angle, build_prompt("specialist", angle, ...))

    # 2. run critic — reads the specialist's output we just wrote
    crit_out = run_codex(f"critic-{angle}", build_prompt("critic", angle, specialist_output=spec_out))

    # 3. compose layered file (spec + critic)
    layered = spec_out + "\n\n---\n\n## Critic counter-arguments\n\n" + crit_out

    write(f"{run_dir}/agents/{angle}/layered.md", layered)
    write(f"{repo_dir}/.codex-scratch/specialists/{angle}.md", layered)
```

`.codex-scratch/specialists/<angle>.md` is what the aggregator's prompt cites today — that contract stays unchanged. The aggregator sees a per-angle file containing specialist probes + critic counter-arguments, exactly like today's post-splitter state.

**Whole-pipeline order:**

1. `intent` (sequential, fail-loud)
2. `dead-code-search` (sequential, fail-loud)
3. 8 angles in parallel via `ThreadPoolExecutor(max_workers=8)`; each angle is `specialist → critic` sequential
4. `momentum` (re-reviews only, sequential, fail-loud)
5. `aggregator` (reads all of the above, fail-loud)

**Symlinks under `.codex-scratch/`** (preserve current pattern):
- `inferred-intent.md → RUN_DIR/agents/intent/output.md`
- `dead-code.md → RUN_DIR/agents/dead-code-search/output.md`
- `momentum.md → RUN_DIR/agents/momentum/output.md`
- `specialists/<angle>.md` is **NOT a symlink** — it's a regular file written with the layered content (spec + critic). Avoids today's splitter "rewrite-symlink-to-regular-file" dance.

**Re-review carry-forward**: each per-angle critic's prompt receives `previous-review.md` if present. Carry-forward becomes per-angle (each critic addresses prior pushback in its own angle). The aggregator handles cross-angle re-review framing today's central critic does.

## Error handling

Every stage fails loud. No soft-degrade paths.

**Per-codex-call** (matches today's `lib/run-specialist.sh` contract, now in Python `run_codex`):
- exit 0 + non-empty output → success
- exit 0 + empty output → exit 3 (codex returned nothing useful)
- non-zero exit → propagate exit code

**Per-angle pipeline** (`run_angle`):
- specialist fails → critic doesn't run; angle pipeline returns failure
- specialist succeeds, critic fails → angle pipeline returns failure
- both succeed → angle pipeline writes layered file, returns success

**Whole-pipeline orchestration** (`run_pipeline`):
- intent fails → abort: log, `rm -rf REPO_DIR`, `sys.exit(1)`
- dead-code-search fails → abort (was fail-soft → degraded mode in shell pipeline; now fail-loud)
- ANY angle fails (specialist or critic) → abort the whole run. Use `concurrent.futures.as_completed()`, on first exception: log which angle + which stage failed + pointer to that agent's `log.txt`, cancel pending futures (best-effort — Python's `Future.cancel()` only cancels not-yet-started futures; running codex calls keep going to completion but their results are ignored), `rm -rf REPO_DIR`, `sys.exit(1)`.
- momentum fails → abort
- aggregator fails → abort

Recovery: "next timer tick re-runs the review" — already happens because aborted reviews leave no posted comment, so the orchestrator's KNOWN_SHA gate dispatches again. Transient codex flakes cost one review round, not a soft-output degradation.

This kills the consumers specialist's "degraded LLM-grep mode" branch (which fired when dead-code-search returned empty). The "missing sibling" degraded mode for siblings — which is orthogonal — stays unchanged.

**The R6 fail-loud invariant is preserved**: today's "critic fails silently → blockers stay Answer:unknown → demoted to open questions" was the bug. Under the new design, each per-angle critic writes its own file independently; if it fails, that angle's specialist file lacks `## Critic counter-arguments`, AND the pipeline aborts before aggregation. No silent demotion possible.

**Observability**: Python pipeline writes structured failure messages to the existing `$LOG_FILE` (inherited from `lib/review-one-pr.sh`'s environment). Format matches today's `[timestamp] PR_ID: <message>` shape so existing log scrapers and `orchestrator-skip-smoke` continue to work.

**No try/except for control flow.** Failures propagate via exception or non-zero exit; no swallowed errors. Matches the `Fail-Fast` rule.

## Testing

**New pytest tests** (`lib/tests/test_pipeline.py`, ~150 LOC):

Use stdlib `unittest` — no pytest dep, no `pip install` overhead. Tests mock `subprocess.run` (codex calls) to return canned exit codes + outputs, so the suite runs in milliseconds.

Coverage:
- `run_codex` — argv shape (the `model=gpt-5.5` pin asserts here, replacing today's `run-specialist-smoke` fence), `prompt.txt` / `output.md` / `log.txt` artifacts written, exit-code propagation, empty-output → exit 3.
- `build_prompt` — placeholder substitution (`PR_ID`, `PR_TITLE`, `PR_URL`, `PR_AUTHOR`, `SPECIALIST_NAME`), common-header concat, voice.md stitch for aggregator, branching by agent type.
- `run_angle` — specialist runs first, critic runs after with specialist output as context, layered.md composed correctly, either-failure → angle pipeline returns failure.
- `run_pipeline` — sequential stages (intent → dead-code → angles → momentum → aggregator), parallel angles via ThreadPoolExecutor, single failure aborts whole pipeline cleanly with `rm -rf REPO_DIR`.

**Shell smokes deleted** (~830 LOC):
- `critic-splitter-smoke.sh`
- `dispatch-agent-smoke.sh`
- `run-specialist-smoke.sh`
- `build-specialist-prompt-smoke.sh`

**Shell smokes preserved unchanged** (orthogonal to pipeline orchestration):
- `review-one-pr-sha-flow-smoke.sh`, `repos-conf-smoke.sh`, `install-smoke.sh` — high-level system tests
- `approve-from-replies-smoke.sh`, `learn-from-replies-smoke.sh`, `plow-kid-refresh-smoke.sh`, `re-request-poller-smoke.sh` — separate timer scripts
- `decline-history-smoke.sh`, `loc-trend-smoke.sh`, `gh-comments-smoke.sh`, `auth-smoke.sh`, `path-scrub-smoke.sh`, `diff-build-smoke.sh`, `divergent-clock-smoke.sh`, `finalize-meta-smoke.sh`, `knightwatch-config-smoke.sh`, `prior-reviews-smoke.sh`, `run-dir-smoke.sh`, `search-roots-smoke.sh`, `sibling-symlinks-smoke.sh`, `strict-typing-checks-smoke.sh`, `codex-scratch-redirect-smoke.sh`, `momentum-wire-smoke.sh` (or whatever survived prior consolidations)
- `replay-smoke.sh`, `replay-source-chain-smoke.sh` — replay updated to call Python entrypoint, smoke updates accordingly

**Shell smokes trimmed** (`prompt-contracts-smoke.sh`):
- Drops splitter-token assertions (no splitter)
- Drops dispatch-agent format checks (no `dispatch_agent` shell function)
- Keeps: shebang fence, PATH ordering, ReadWritePaths fence, prompt-token presence (probe-schema, complexity-cost, etc.), aggregator wiring tokens

**Test invocation** (`justfile`):

```just
test:
    # ... existing shell preamble (bash version check) ...
    python3 -m unittest discover -s lib/tests -p 'test_*.py' -v
    # ... existing shell smokes loop ...
```

One added line. `python3 -m unittest discover` is stdlib; works on any Python 3.x.

**Net test LOC delta**: −830 shell + ~150 Python = **−680 test LOC**.

## Open questions

None — design fully specified.

## Out of scope

- **Replay harness migration beyond the entrypoint switch.** `lib/replay.sh` keeps doing its scratch staging + git checkout + manifest writing in shell; it just calls `python3 lib/pipeline.py` instead of sourcing `orchestrate.sh`.
- **Systemd timer scripts** (`learn-from-replies.sh`, `approve-from-replies.sh`, `plow-kid-refresh.sh`, `re-request-poller.sh`) — orthogonal to pipeline orchestration, stay shell.
- **`review.sh`** (top-level systemd entrypoint, fans out per-PR workers) — stays shell. The Python entrypoint is invoked from `lib/review-one-pr.sh` (the per-PR worker), not from `review.sh`.
- **Pydantic / JSON / strict-output codex schemas** — discussed in brainstorming as alternative (sketch (a)), rejected in favor of per-angle critics (sketch (b)) which removes the parser entirely.
