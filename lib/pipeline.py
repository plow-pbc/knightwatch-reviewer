#!/usr/bin/env python3
"""Pipeline orchestration for knightwatch-reviewer."""
from __future__ import annotations

import os
import re
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

SPECIALISTS = (
    "security", "data-integrity", "architecture", "architecture-refined",
    "contract-drift", "simplification", "tests", "shape", "consumers",
)

# Per-codex hard cap. Successful specialists complete in 1–5 min; 45 min
# means the codex subprocess is wedged, not slow. Originating incident:
# cncorp/plow#594, 2026-05-12T20:04Z.
SPECIALIST_TIMEOUT_SEC = 45 * 60

# Liveness watchdog for the codex 0.128–0.130+ parallel-tool-call deadlock
# (openai/codex#21937, #14220): kill at 5 min staleness, retry once on
# stale kills only. Hard-cap and budget-exhausted stale kills don't retry.
# See _wait_with_watchdog for the budget-gating rationale.
STALENESS_THRESHOLD_SEC = 5 * 60
WATCHDOG_POLL_SEC = 60
WORKER_RETRY_CLEANUP_MARGIN_SEC = 5 * 60

# Operator-facing kill-reason prefixes. Tests assert against these so a
# rename doesn't silently drift the log; retry eligibility flows through
# the explicit `retryable` field, not string matching.
WATCHDOG_KILL_STALE_PREFIX = "stale for"
WATCHDOG_KILL_HARDCAP_PREFIX = "hit hard cap"
_PROBE_BLOCK_RE = re.compile(r"^### Probe |^No probes\.$", re.MULTILINE)
_PROBE_HEADER_RE = re.compile(r"^### Probe (\d+)\b", re.MULTILINE)
_CRITIC_H2_RE = re.compile(r"^## Critic counter-arguments\s*$", re.MULTILINE)
# Codex prints this when the user's ChatGPT/Codex usage limit is hit. The
# capture group is pinned to Codex's two observed reset formats — short
# rolling-window ("6:26 PM") or weekly cap ("May 26th, 2026 11:33 AM") —
# rather than `[^.\n]+`, so PR-controlled text that leaks into an agent's
# log.txt via prompt injection can't reflect into the public placeholder.
# If Codex changes the format, the regex misses and we fall back to the
# generic abort body — safe degradation.
_CODEX_QUOTA_RE = re.compile(
    r"hit your usage limit\..*?try again at "
    r"((?:\w+ \d{1,2}(?:st|nd|rd|th), \d{4} )?\d{1,2}:\d{2} (?:AM|PM))\.",
    re.IGNORECASE | re.DOTALL,
)


def _ts() -> str:
    return time.strftime("%H:%M:%S")


def _log_file() -> Path | None:
    p = os.environ.get("LOG_FILE")
    return Path(p) if p else None


def _log_prefix() -> str:
    """Timestamp + (in container mode) a [w<WORKER_ID>] account tag. Mirrors the
    shell log() format in lib/state-io.sh so a single `docker compose logs`
    grep covers both the shell and Python halves of a reviewer's output."""
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    wid = os.environ.get("WORKER_ID")
    return f"[{ts}] [w{wid}]" if wid else f"[{ts}]"


def log(msg: str) -> None:
    """Tee a timestamped, worker-tagged line to stdout and $LOG_FILE."""
    line = f"{_log_prefix()} {msg}\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    logf = _log_file()
    if logf:
        with logf.open("a") as f:
            f.write(line)


def _relink(link: Path, target: Path) -> None:
    """Replace `link` with a symlink to `target`. mkdir parents as needed."""
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(target)


def _wait_with_watchdog(
    proc: subprocess.Popen, log_file: Path, err_file: Path
) -> tuple[int, str | None, bool]:
    """Wait on `proc`, polling the newest mtime across codex's two output
    streams (stdout `log.txt` + stderr `err.txt`) for liveness. Returns
    `(exit_code, kill_reason, retryable)`. `kill_reason` is None on natural
    exit and a human-readable string on watchdog kill (exit_code is then
    124). `retryable` is True only for stale kills that fit under both the
    per-Codex and outer-worker budgets; hard-cap kills are never retryable.

    Both streams matter: codex (reasoning-summaries off) writes stdout only
    at the final answer, while all live tool/reasoning activity streams to
    stderr. Watching stdout alone false-kills any investigation agent whose
    work runs past the staleness threshold (cncorp/plow#700/#638/#692/#695
    abort wave); a genuine deadlock goes silent on BOTH streams and is still
    caught. run_codex opens both files before this call, so a missing-file
    stat here is a real invariant violation — let it raise, don't mask it.

    Kills the whole process group via `os.killpg` when codex hangs —
    bare wait+kill leaves codex's tool-subprocess descendants orphaned
    to PID 1 with reviewer credentials (sandbox disabled by
    pr-reviewer.service)."""
    start = time.monotonic()
    last_progress = start
    last_mtime = max(log_file.stat().st_mtime, err_file.stat().st_mtime)
    while True:
        try:
            return proc.wait(timeout=WATCHDOG_POLL_SEC), None, False
        except subprocess.TimeoutExpired:
            pass
        now = time.monotonic()
        mtime = max(log_file.stat().st_mtime, err_file.stat().st_mtime)
        if mtime > last_mtime:
            last_mtime = mtime
            last_progress = now
        stale_for = now - last_progress
        elapsed = now - start
        # Hard-cap precedence: if both staleness AND hard-cap cross on the
        # same poll tick (a process active until ~minute 40 that goes quiet
        # would hit both at minute 45), hard-cap wins. Retrying a process
        # that consumed its full per-Codex budget could push past the
        # outer worker `timeout` with no recovery.
        if elapsed >= SPECIALIST_TIMEOUT_SEC:
            reason = f"{WATCHDOG_KILL_HARDCAP_PREFIX} {SPECIALIST_TIMEOUT_SEC}s — killpg'd whole group"
            retryable = False
        elif stale_for >= STALENESS_THRESHOLD_SEC:
            reason = f"{WATCHDOG_KILL_STALE_PREFIX} {stale_for:.0f}s (no output activity) — killpg'd whole group"
            # Two gates: per-Codex (elapsed under this attempt's own cap,
            # one staleness threshold of headroom) AND outer worker
            # (review.sh's `timeout $WORKER_TIMEOUT` wrap covers just test
            # + Wave A + all earlier specialists, so wall-clock remaining
            # can be tighter than per-Codex elapsed would suggest). Both
            # must pass; otherwise the worker would be killed mid-retry
            # before Wave B's abort can write _wave_b_timeouts.txt.
            # WORKER_DEADLINE_EPOCH unset (tests outside the harness)
            # skips the worker gate.
            deadline_raw = os.environ.get("WORKER_DEADLINE_EPOCH")
            worker_ok = (
                not deadline_raw
                or float(deadline_raw) - time.time()
                   >= SPECIALIST_TIMEOUT_SEC + WORKER_RETRY_CLEANUP_MARGIN_SEC
            )
            retryable = (
                elapsed <= SPECIALIST_TIMEOUT_SEC - STALENESS_THRESHOLD_SEC
                and worker_ok
            )
        else:
            continue
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        return 124, reason, retryable


def run_codex(name: str, repo_dir: str, prompt: str, agent_dir: str) -> int:
    """Wrap one `codex exec` invocation. Writes prompt.txt/output.md/log.txt
    under agent_dir. Returns codex exit code, 3 for empty output, or 4 for
    probe-contract violation (specialist roles only).

    On a retryable watchdog kill (rc=124, `retryable=True` from
    _wait_with_watchdog), retries codex exactly once: log.txt is archived
    to log.attempt1.txt and any half-written output.md is unlinked first.
    Non-retryable kills (hard-cap, late-stale, worker-budget-exhausted)
    and two-in-a-row hangs return 124 so Wave B's abort path fires."""
    repo = Path(repo_dir)
    agent = Path(agent_dir)
    agent.mkdir(parents=True, exist_ok=True)
    prompt_file = agent / "prompt.txt"
    out_file = agent / "output.md"
    # log.txt = codex stdout (mostly model reasoning summary, ie PR-influenced
    # content). err.txt = codex stderr (the CLI's own error messages,
    # including the usage-limit notice we parse for the quota sentinel).
    # Splitting the streams keeps PR-controlled model output out of the
    # quota scan — otherwise a non-quota rc=1 with attacker-shaped stdout
    # could spoof a public quota placeholder.
    log_file = agent / "log.txt"
    err_file = agent / "err.txt"

    prompt_file.write_text(prompt)
    with log_file.open("a") as lf:
        lf.write(f"[{_ts()}] agent={name} starting\n")

    argv = [
        "codex", "exec",
        "-C", str(repo),
        "--dangerously-bypass-approvals-and-sandbox",
        "-c", "model=gpt-5.5",
        "-c", "model_reasoning_effort=high",
        "-o", str(out_file),
        prompt,
    ]
    # Popen + start_new_session puts codex (a node process that spawns tool
    # subprocesses) in its own process group, so on timeout `os.killpg`
    # reaps the descendants too — bare `subprocess.run(timeout=)` kills
    # only the direct child and leaves tool processes orphaned to PID 1
    # with reviewer credentials (sandbox disabled by `pr-reviewer.service`).
    for attempt in (1, 2):
        if attempt == 2:
            # Archive attempt-1 artifacts + drop any half-written output.md so the
            # post-loop validation only sees attempt 2's artifact (codex's -o
            # write should be atomic, but the contract is "this attempt's
            # output.md belongs to this attempt" — don't lean on codex behaviour).
            log_file.rename(agent / "log.attempt1.txt")
            if err_file.exists():
                err_file.rename(agent / "err.attempt1.txt")
            out_file.unlink(missing_ok=True)
            with log_file.open("a") as lf:
                lf.write(f"[{_ts()}] agent={name} attempt 2 (first hung; see log.attempt1.txt)\n")
        with log_file.open("a") as lf, err_file.open("a") as ef:
            proc = subprocess.Popen(argv, stdout=lf, stderr=ef, start_new_session=True)
        exit_code, kill_reason, retryable = _wait_with_watchdog(proc, log_file, err_file)
        # We retry at most once (attempt 1 → attempt 2); a retryable kill on
        # the final attempt still ends the loop, so gate both the surfaced
        # "(retrying)" suffix and the break on will_retry, not raw retryable —
        # otherwise the final review-costing kill is mislabeled "(retrying)"
        # and the `grep -c` rate this surfacing exists for double-counts it.
        will_retry = retryable and attempt == 1
        if kill_reason is not None:
            with log_file.open("a") as lf:
                lf.write(f"[{_ts()}] agent={name} killed: {kill_reason}\n")
            # Also surface on stdout/$LOG_FILE. The per-agent log.txt lives
            # inside the run dir — invisible to `docker compose logs`, the
            # stream /babysit-pr tails, and the only place the codex
            # parallel-tool-call deadlock rate (openai/codex#21937) is
            # countable in aggregate. Without this the rate is silent: a
            # `grep -c "codex watchdog kill"` over the reviewer logs is the
            # whole point. "(retrying)" separates rescued hangs from the ones
            # that actually cost a review angle.
            log(f"{name}: codex watchdog kill — {kill_reason}"
                + (" (retrying)" if will_retry else ""))
        if not will_retry:
            break

    with log_file.open("a") as lf:
        lf.write(f"[{_ts()}] agent={name} exit={exit_code}\n")

    if exit_code != 0:
        # Codex itself exited non-zero — most commonly the ChatGPT/Codex
        # usage limit. Scan err.txt (codex CLI stderr only) for the reset
        # time and stash it for review-one-pr.sh to PATCH into the
        # placeholder. Stdout (model reasoning) is excluded so PR-
        # controlled output can't spoof a public quota placeholder.
        m = _CODEX_QUOTA_RE.search(err_file.read_text(errors="replace"))
        if m:
            sentinel = agent.parent.parent / "_codex_quota.txt"
            sentinel.write_text(m.group(1).strip() + "\n")
        return exit_code

    if not out_file.exists() or out_file.stat().st_size == 0:
        with log_file.open("a") as lf:
            lf.write(f"[{_ts()}] agent={name} produced empty output\n")
        return 3

    if name in SPECIALISTS:
        if not _PROBE_BLOCK_RE.search(out_file.read_text()):
            with log_file.open("a") as lf:
                lf.write(
                    f"[{_ts()}] agent={name} produced output that doesn't follow "
                    "probe contract (no '### Probe' block, no 'No probes.' sentinel)\n"
                )
            return 4

    return 0


def _substitute_placeholders(template: str, **subs: str) -> str:
    for key, val in subs.items():
        template = template.replace("{{" + key.upper() + "}}", val)
    return template


def _strip_leading_html_comment(text: str) -> str:
    if not text.lstrip().startswith("<!--"):
        return text
    start = text.index("<!--")
    end = text.find("-->", start)
    if end < 0:
        return text
    return text[end + 3:].lstrip("\n")


def build_prompt(
    kind: str,
    agent: str,
    prompts_dir: str,
    pr_id: str,
    pr_title: str,
    pr_url: str,
    pr_author: str,
) -> str:
    """Build a prompt string. `kind` is 'specialist', 'standalone', 'critic',
    or 'aggregator'."""
    pdir = Path(prompts_dir)
    operator_name = os.environ.get("OPERATOR_NAME", "Sam")
    base_subs = dict(
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url,
        pr_author=pr_author, operator_name=operator_name,
    )

    if kind == "specialist":
        common = (pdir / "common-header.md").read_text()
        body = (pdir / "specialists" / f"{agent}.md").read_text()
        subs = dict(base_subs, specialist_name=agent)
        return (
            _substitute_placeholders(common, **subs)
            + "\n"
            + _substitute_placeholders(body, **subs)
        )

    if kind == "standalone":
        body = (pdir / "standalone" / f"{agent}.md").read_text()
        return _substitute_placeholders(body, **base_subs, specialist_name="")

    if kind == "critic":
        body = (pdir / "critic.md").read_text()
        angle = agent[len("critic-"):]
        return _substitute_placeholders(body, **base_subs, angle=angle, specialist_name=angle)

    if kind == "aggregator":
        agg = (pdir / "aggregator.md").read_text()
        voice_path = pdir / "voice.md"
        if not voice_path.exists():
            raise FileNotFoundError(f"build_prompt: voice.md missing at {voice_path}")
        marker = "<!-- INSERT_VOICE_HERE -->"
        if marker not in agg:
            raise ValueError(f"build_prompt: aggregator.md missing {marker} marker")
        voice_body = _strip_leading_html_comment(voice_path.read_text()).rstrip("\n")
        stitched = agg.replace(marker, voice_body, 1)
        return _substitute_placeholders(stitched, **base_subs)

    raise ValueError(f"build_prompt: unknown kind '{kind}'")


def _duplicate_ids(ids: list[str]) -> list[str]:
    seen: set[str] = set()
    dupes: list[str] = []
    for pid in ids:
        if pid in seen and pid not in dupes:
            dupes.append(pid)
        seen.add(pid)
    return dupes


def _validate_critic_output(spec_text: str, crit_text: str) -> str | None:
    """Validate critic output against the specialist's probes. Bijection
    contract: critic addresses every specialist probe by ID with Answer +
    Evidence, never emits a probe id the specialist didn't, OR emits the
    bare 'No probes.' sentinel when the specialist had zero probes.
    Returns None on success, an error message on failure."""
    spec_probe_id_list = _PROBE_HEADER_RE.findall(spec_text)
    spec_dupes = _duplicate_ids(spec_probe_id_list)
    if spec_dupes:
        return (
            f"specialist emitted duplicate probe ID(s): {spec_dupes} — each "
            "probe must have a unique '### Probe N' header"
        )
    spec_probe_ids = set(spec_probe_id_list)

    if not spec_probe_ids:
        if crit_text.strip() != "No probes.":
            return (
                "specialist emitted 0 probes; critic must respond with bare "
                f"'No probes.' sentinel (got first 80 chars: {crit_text[:80]!r})"
            )
        return None

    if not _CRITIC_H2_RE.search(crit_text):
        return (
            f"specialist emitted {len(spec_probe_ids)} probe(s); critic missing "
            "anchored '## Critic counter-arguments' H2 header"
        )

    crit_probe_id_list = _PROBE_HEADER_RE.findall(crit_text)
    crit_dupes = _duplicate_ids(crit_probe_id_list)
    if crit_dupes:
        return (
            f"critic emitted duplicate probe ID(s): {crit_dupes} — each "
            "resolution must have a unique '### Probe N' header"
        )
    crit_probe_ids = set(crit_probe_id_list)

    missing = spec_probe_ids - crit_probe_ids
    if missing:
        return f"critic missing resolution for probe(s): {sorted(missing, key=int)}"
    extra = crit_probe_ids - spec_probe_ids
    if extra:
        return f"critic emitted probe(s) not in specialist: {sorted(extra, key=int)}"

    for probe_id in sorted(spec_probe_ids, key=int):
        section_match = re.search(
            rf"^### Probe {probe_id}\b(.*?)(?=^### Probe |\Z)",
            crit_text, re.MULTILINE | re.DOTALL,
        )
        if not section_match:
            return f"critic missing block for probe {probe_id}"
        section = section_match.group(1)
        if "**Answer:**" not in section:
            return f"critic probe {probe_id} missing **Answer:** field"
        if "**Evidence:**" not in section:
            return f"critic probe {probe_id} missing **Evidence:** field"

    return None


def run_specialist(
    specialist: str,
    repo_dir: str,
    run_dir: str,
    prompts_dir: str,
    pr_id: str,
    pr_title: str,
    pr_url: str,
    pr_author: str,
) -> int:
    """Run one specialist → critic chain. Writes the layered file (specialist
    + critic) on full success. Returns 0 or the failing stage's exit code."""
    run = Path(run_dir)
    repo = Path(repo_dir)

    spec_prompt = build_prompt(
        kind="specialist", agent=specialist, prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    spec_agent_dir = run / "agents" / specialist
    spec_rc = run_codex(specialist, str(repo), spec_prompt, str(spec_agent_dir))
    if spec_rc != 0:
        log(f"{pr_id}: specialist {specialist} exited non-zero (see {spec_agent_dir}/{{log,err}}.txt)")
        return spec_rc
    spec_out = (spec_agent_dir / "output.md").read_text()

    # Stage specialist output to .codex-scratch so the critic can read it
    # via the path documented in prompts/critic.md. Overwritten with layered
    # content after a successful critic.
    scratch_path = repo / ".codex-scratch" / "specialists" / f"{specialist}.md"
    scratch_path.parent.mkdir(parents=True, exist_ok=True)
    scratch_path.write_text(spec_out)

    crit_prompt = build_prompt(
        kind="critic", agent=f"critic-{specialist}", prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    crit_agent_dir = run / "agents" / f"critic-{specialist}"
    crit_rc = run_codex(f"critic-{specialist}", str(repo), crit_prompt, str(crit_agent_dir))
    if crit_rc != 0:
        log(f"{pr_id}: critic-{specialist} exited non-zero (see {crit_agent_dir}/{{log,err}}.txt)")
        return crit_rc
    crit_out = (crit_agent_dir / "output.md").read_text()

    err = _validate_critic_output(spec_out, crit_out)
    if err:
        log(
            f"{pr_id}: critic-{specialist} contract violation: {err} "
            f"(see {crit_agent_dir}/output.md)"
        )
        return 4

    layered = spec_out + "\n\n---\n\n" + crit_out
    (spec_agent_dir / "layered.md").write_text(layered)
    scratch_path.write_text(layered)
    return 0


def _abort(repo_dir: Path, msg: str) -> int:
    log(msg)
    if repo_dir.exists():
        shutil.rmtree(repo_dir, ignore_errors=True)
    return 1


def _validate_intent(intent_out: Path) -> str:
    """Return the parsed intent line. Raise ValueError on contract violation."""
    if not intent_out.exists() or intent_out.stat().st_size == 0:
        raise ValueError("intent inference produced empty output")
    text = intent_out.read_text()
    nonblank = [ln for ln in text.splitlines() if ln.strip()]
    if len(nonblank) != 1:
        raise ValueError(
            f"intent output has {len(nonblank)} non-blank lines, expected exactly 1"
        )
    if not nonblank[0].startswith("Inferred intent: "):
        raise ValueError("intent output missing 'Inferred intent: ' prefix")
    return nonblank[0]


def _run_standalone(
    name: str, repo_dir: str, run_dir: str, prompts_dir: str,
    pr_id: str, pr_title: str, pr_url: str, pr_author: str,
) -> int:
    """Build + run one standalone codex stage at agents/<name>/. Returns rc."""
    prompt = build_prompt(
        kind="standalone", agent=name, prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    agent_dir = Path(run_dir) / "agents" / name
    return run_codex(name, repo_dir, prompt, str(agent_dir))


def run_pipeline(
    repo_dir: str,
    run_dir: str,
    prompts_dir: str,
    pr_id: str,
    pr_title: str,
    pr_url: str,
    pr_author: str,
) -> int:
    """Run the full LLM review pipeline. Returns 0 on success, non-zero on
    any-stage failure. Aggregator output lands at
    <run_dir>/agents/aggregator/output.md."""
    repo = Path(repo_dir)
    run = Path(run_dir)
    scratch = repo / ".codex-scratch"
    scratch.mkdir(parents=True, exist_ok=True)

    common_kwargs = dict(
        repo_dir=repo_dir, run_dir=run_dir, prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )

    # Wave A: intent + dead-code-search in parallel. Both are inputs to the
    # specialists (intent → architecture/simplification/momentum read it;
    # dead-code → consumers reads it), so they must complete before Wave B.
    log(f"{pr_id}: Wave A — intent + dead-code-search")
    with ThreadPoolExecutor(max_workers=2) as ex:
        intent_fut = ex.submit(_run_standalone, "intent", **common_kwargs)
        dc_fut = ex.submit(_run_standalone, "dead-code-search", **common_kwargs)
        intent_rc = intent_fut.result()
        dc_rc = dc_fut.result()
    if intent_rc != 0:
        return _abort(repo, f"{pr_id}: intent inference failed (exit={intent_rc}) — aborting")
    if dc_rc != 0:
        return _abort(repo, f"{pr_id}: dead-code search failed (exit={dc_rc}) — aborting")

    intent_dir = run / "agents" / "intent"
    try:
        intent_text = _validate_intent(intent_dir / "output.md")
    except ValueError as e:
        return _abort(repo, f"{pr_id}: {e} — aborting")
    _relink(scratch / "inferred-intent.md", intent_dir / "output.md")
    _relink(scratch / "dead-code.md", run / "agents" / "dead-code-search" / "output.md")
    log(f"{pr_id}: Wave A complete: {intent_text}")

    # Wave B: all SPECIALISTS + (momentum if re-review) in parallel. Momentum
    # reads inferred-intent.md (Wave A) but no specialist output, so it can
    # run alongside the specialists.
    prev_review = run / "inputs" / "previous-review.md"
    has_prev = prev_review.exists() and prev_review.stat().st_size > 0
    label = f"{len(SPECIALISTS)} specialists" + (" + momentum" if has_prev else "")
    log(f"{pr_id}: Wave B — {label}")
    timed_out: list[str] = []
    hard_failures: list[str] = []
    # Collect ALL results — never `break` early. Early break left the with-
    # block's __exit__ to call ex.shutdown(wait=True) on a hung future and
    # the pipeline blocked indefinitely (see SPECIALIST_TIMEOUT_SEC docstring).
    # With run_codex's 45m subprocess timeout, every future now resolves.
    with ThreadPoolExecutor(max_workers=len(SPECIALISTS) + 1) as ex:
        futures = {
            ex.submit(run_specialist, specialist=s, **common_kwargs): s
            for s in SPECIALISTS
        }
        if has_prev:
            futures[ex.submit(_run_standalone, "momentum", **common_kwargs)] = "momentum"
        for fut in as_completed(futures):
            name = futures[fut]
            try:
                rc = fut.result()
            except Exception as exc:
                hard_failures.append(f"{name}: raised {type(exc).__name__}: {exc}")
                continue
            if rc == 124:
                timed_out.append(name)
                log(f"{pr_id}: specialist {name} timed out after {SPECIALIST_TIMEOUT_SEC}s")
            elif rc != 0:
                # run_specialist's own log line names the failing stage's
                # log.txt; don't second-guess with the always-specialist path.
                hard_failures.append(f"{name}: exited non-zero (rc={rc})")

    # Any specialist timeout aborts loudly. The sentinel names the hung
    # specialists so the bash worker patches the placeholder with the names
    # rather than the generic abort body. Authors re-trigger via push or
    # /srosro-update-review for a fresh review — partial-coverage posting
    # was traded for simpler infra (no carve-outs, no stubs, no second
    # write site).
    if timed_out:
        (run / "_wave_b_timeouts.txt").write_text("\n".join(timed_out) + "\n")
        return _abort(
            repo,
            f"{pr_id}: {len(timed_out)} specialist(s) timed out "
            f"({', '.join(timed_out)}) — aborting",
        )

    if hard_failures:
        return _abort(
            repo, f"{pr_id}: Wave B hard failures: {'; '.join(hard_failures)} — aborting"
        )

    if has_prev:
        _relink(scratch / "momentum.md", run / "agents" / "momentum" / "output.md")
    log(f"{pr_id}: Wave B complete")

    # Aggregator (sequential — depends on Waves A + B)
    log(f"{pr_id}: aggregator...")
    agg_prompt = build_prompt(
        kind="aggregator", agent="aggregator", prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    agg_dir = run / "agents" / "aggregator"
    rc = run_codex("aggregator", str(repo), agg_prompt, str(agg_dir))
    if rc != 0:
        return _abort(repo, f"{pr_id}: aggregator failed (exit={rc}) — aborting")
    log(f"{pr_id}: aggregator complete")
    return 0


def _trace_sigterm_source(signum: int, _frame: object) -> None:
    """SIGTERM forensics. On 2026-05-22 a SIGTERM aborted pipeline.py
    mid-Wave-B and no log evidence pointed at the sender (OOM/oomd
    silent, no internal timeout matched). Capture parent pid+cmdline
    and TracerPid before exiting so the next mystery kill is
    debuggable. Re-exits 128+signum to preserve the previous bash-side
    exit code (143 for SIGTERM)."""
    try:
        ppid = os.getppid()
        try:
            with open(f"/proc/{ppid}/cmdline", "rb") as f:
                parent_cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            parent_cmd = "<unavailable>"
        tracer_pid = "0"
        try:
            with open("/proc/self/status") as f:
                for line in f:
                    if line.startswith("TracerPid:"):
                        tracer_pid = line.split(":", 1)[1].strip()
                        break
        except OSError:
            pass
        log(
            f"pipeline.py received signal={signum} ppid={ppid} "
            f"tracer_pid={tracer_pid} parent_cmd={parent_cmd[:200]!r}"
        )
    finally:
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)


def main() -> int:
    signal.signal(signal.SIGTERM, _trace_sigterm_source)
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} REPO_DIR RUN_DIR\n")
        return 2
    repo_dir, run_dir = sys.argv[1], sys.argv[2]
    prompts_dir = os.environ.get("PROMPTS_DIR", os.path.expanduser("~/.pr-reviewer/prompts"))
    return run_pipeline(
        repo_dir=repo_dir, run_dir=run_dir, prompts_dir=prompts_dir,
        pr_id=os.environ["PR_ID"],
        pr_title=os.environ["PR_TITLE"],
        pr_url=os.environ["PR_URL"],
        pr_author=os.environ["PR_AUTHOR"],
    )


if __name__ == "__main__":
    sys.exit(main())
