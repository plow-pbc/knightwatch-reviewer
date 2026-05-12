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
    "security", "data-integrity", "architecture", "simplification",
    "tests", "shape", "performance", "consumers",
)

# Per-codex-invocation hard cap. Successful specialists complete in 1–5 min
# in production (Wave B aggregate ≈ 5–10 min); 45 min means the codex
# subprocess is wedged, not slow. Without this, a single hung specialist
# blocked the `with ThreadPoolExecutor as ex:` context exit indefinitely,
# the bash worker stayed in `wait`, and the 90 min outer `timeout` fired
# SIGTERM at a point the EXIT trap didn't complete — leaving the 👀
# placeholder orphaned (PR cncorp/plow#594, 2026-05-12T20:04Z). run_codex
# enforces this via Popen + start_new_session + killpg on TimeoutExpired,
# so codex's tool descendants are reaped too (not orphaned to PID 1).
SPECIALIST_TIMEOUT_SEC = 45 * 60
_PROBE_BLOCK_RE = re.compile(r"^### Probe |^No probes\.$", re.MULTILINE)
_PROBE_HEADER_RE = re.compile(r"^### Probe (\d+)\b", re.MULTILINE)
_CRITIC_H2_RE = re.compile(r"^## Critic counter-arguments\s*$", re.MULTILINE)


def _ts() -> str:
    return time.strftime("%H:%M:%S")


def _log_file() -> Path | None:
    p = os.environ.get("LOG_FILE")
    return Path(p) if p else None


def log(msg: str) -> None:
    """Tee a timestamped line to stdout and $LOG_FILE."""
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n"
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


def run_codex(name: str, repo_dir: str, prompt: str, agent_dir: str) -> int:
    """Wrap one `codex exec` invocation. Writes prompt.txt/output.md/log.txt
    under agent_dir. Returns codex exit code, 3 for empty output, or 4 for
    probe-contract violation (specialist roles only)."""
    repo = Path(repo_dir)
    agent = Path(agent_dir)
    agent.mkdir(parents=True, exist_ok=True)
    prompt_file = agent / "prompt.txt"
    out_file = agent / "output.md"
    log_file = agent / "log.txt"

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
    # Popen + start_new_session=True puts codex (a node process that spawns
    # tool subprocesses) in its own process group. On timeout we SIGKILL the
    # whole group with os.killpg, reaping the descendants too. Bare
    # subprocess.run(timeout=) kills only the direct child — codex's tool
    # children then reparent to PID 1, where pr-reviewer.service's
    # KillMode=process leaves them running with reviewer credentials and
    # disabled sandboxing until they die on their own (potentially never).
    with log_file.open("a") as lf:
        proc = subprocess.Popen(argv, stdout=lf, stderr=lf, start_new_session=True)
    try:
        exit_code = proc.wait(timeout=SPECIALIST_TIMEOUT_SEC)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass  # leader already reaped; kernel cleaned up
        proc.wait()  # reap zombie
        exit_code = 124  # GNU `timeout` convention — Wave B distinguishes
                         # 124 (tolerable, up to 1) from other non-zero rcs.
        with log_file.open("a") as lf:
            lf.write(f"[{_ts()}] agent={name} timed out after {SPECIALIST_TIMEOUT_SEC}s — killpg'd whole group\n")

    with log_file.open("a") as lf:
        lf.write(f"[{_ts()}] agent={name} exit={exit_code}\n")

    if exit_code != 0:
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
        log(f"{pr_id}: specialist {specialist} exited non-zero (see {spec_agent_dir}/log.txt)")
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
        log(f"{pr_id}: critic-{specialist} exited non-zero (see {crit_agent_dir}/log.txt)")
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

    # Wave B: 8 specialists + (momentum if re-review) in parallel. Momentum
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
                hard_failures.append(
                    f"{name}: exited non-zero (rc={rc}, see {run}/agents/{name}/log.txt)"
                )

    # Hard failures (non-timeout) are bugs / contract violations, not flakes —
    # no tolerance threshold.
    if hard_failures:
        return _abort(
            repo, f"{pr_id}: Wave B hard failures: {'; '.join(hard_failures)} — aborting"
        )

    # Fail-loud threshold: 2+ specialists hung means a systemic codex problem,
    # not a single flake. Skip the aggregator and let the bash worker replace
    # the 👀 placeholder with an explicit error (read from this sentinel) so
    # the author isn't left with an orphan reviewing-marker for 90 min.
    if len(timed_out) >= 2:
        (run / "_wave_b_timeouts.txt").write_text("\n".join(timed_out) + "\n")
        return _abort(
            repo,
            f"{pr_id}: {len(timed_out)} specialists timed out "
            f"({', '.join(timed_out)}) — aborting (fail-loud threshold reached)",
        )

    # Exactly 1 timeout: tolerable degradation. Write a "No probes." stub at the
    # path the aggregator reads from so the aggregator can run cleanly, and
    # drop a banner sentinel for the bash worker to inject above the review
    # body. The author sees the partial coverage explicitly, not silently.
    if timed_out:
        [name] = timed_out
        if name == "momentum":
            # Momentum's aggregator-visible path is scratch/momentum.md
            # (linked from agents/momentum/output.md in the happy path); the
            # _relink below would error on the missing source, so we write
            # the stub here and skip the relink.
            (scratch / "momentum.md").write_text(
                f"<!-- momentum timed out after {SPECIALIST_TIMEOUT_SEC}s — no prior-review momentum available -->\n"
            )
            warning = (
                f"⚠️ Momentum input unavailable: timed out after "
                f"{SPECIALIST_TIMEOUT_SEC // 60} min — review reflects 8/8 "
                "specialist angles but did not benefit from prior-review momentum"
            )
        else:
            # Specialist: layered stub at agents/<name>/layered.md (for
            # forensics + bakeoff roster math) AND .codex-scratch/specialists/
            # (where the aggregator reads from). "No probes." is the documented
            # zero-probe sentinel the critic contract already accepts.
            stub = (
                f"<!-- specialist {name} timed out after {SPECIALIST_TIMEOUT_SEC}s — no analysis available -->\n"
                "No probes.\n\n---\n\nNo probes.\n"
            )
            (run / "agents" / name / "layered.md").write_text(stub)
            scratch_specialists = repo / ".codex-scratch" / "specialists"
            scratch_specialists.mkdir(parents=True, exist_ok=True)
            (scratch_specialists / f"{name}.md").write_text(stub)
            warning = (
                f"⚠️ Specialist `{name}` timed out after "
                f"{SPECIALIST_TIMEOUT_SEC // 60} min — review reflects "
                f"{len(SPECIALISTS) - 1}/{len(SPECIALISTS)} angles"
            )
        (run / "_wave_b_warning.txt").write_text(warning)

    if has_prev and "momentum" not in timed_out:
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


def main() -> int:
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
