#!/usr/bin/env python3
"""Pipeline orchestration for knightwatch-reviewer.

Replaces lib/orchestrate.sh + lib/critic-splitter.sh + lib/run-specialist.sh
+ lib/prompt-build.sh. Per-angle critics replace the centralized critic +
splitter; each angle's critic appends to its specialist's file directly.

Stdlib only (no pip deps). Driven by env vars matching the prior shell
contract: PR_ID, PR_TITLE, PR_URL, PR_AUTHOR, PROMPTS_DIR, LOG_FILE.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Roles that must emit at least one `### Probe N` block or the literal
# `No probes.` sentinel — matches lib/run-specialist.sh:76-83 contract.
# Critics, intent, aggregator, momentum, dead-code-search, go-deep-* have
# different output shapes and are exempt; per-angle critics are validated
# semantically against the specialist's probe count by run_angle (not via
# a regex at run_codex), so a critic that emits the right H2 but skips
# probe resolutions is still caught.
ANGLES = (
    "security", "data-integrity", "architecture", "simplification",
    "tests", "shape", "performance", "consumers",
)
_PROBE_GATED_ROLES = frozenset(ANGLES)
_PROBE_BLOCK_RE = re.compile(r"^### Probe |^No probes\.$", re.MULTILINE)
_PROBE_HEADER_RE = re.compile(r"^### Probe (\d+)\b", re.MULTILINE)


def _ts() -> str:
    return time.strftime("%H:%M:%S")


def _log_file() -> Path | None:
    p = os.environ.get("LOG_FILE")
    return Path(p) if p else None


def log(msg: str) -> None:
    """Tee a timestamped line to stdout AND $LOG_FILE — matches state-io.sh's
    `echo ... | tee -a "$LOG_FILE"` so the systemd journal (stdout) and a
    `tail -f` of LOG_FILE both reflect every event."""
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n"
    sys.stdout.write(line)
    sys.stdout.flush()
    logf = _log_file()
    if logf:
        with logf.open("a") as f:
            f.write(line)


def run_codex(name: str, repo_dir: str, prompt: str, agent_dir: str) -> int:
    """Wrap one `codex exec` invocation.

    Mirrors lib/run-specialist.sh: writes prompt.txt/output.md/log.txt;
    returns codex exit code, or 3 for empty output, or 4 for probe-contract
    violation.
    """
    repo = Path(repo_dir)
    agent = Path(agent_dir)
    if not (repo / ".git").is_dir():
        sys.stderr.write(f"run_codex: {repo} is not a git repo\n")
        return 2

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
    with log_file.open("a") as lf:
        proc = subprocess.run(argv, stdout=lf, stderr=lf)
    exit_code = proc.returncode

    with log_file.open("a") as lf:
        lf.write(f"[{_ts()}] agent={name} exit={exit_code}\n")

    if exit_code != 0:
        return exit_code

    if not out_file.exists() or out_file.stat().st_size == 0:
        with log_file.open("a") as lf:
            lf.write(f"[{_ts()}] agent={name} produced empty output\n")
        return 3

    # Probe-contract gate for the 8 angle specialists. Per-angle critics are
    # validated semantically against the specialist's output by run_angle —
    # not here — so this gate covers specialists only.
    if name in _PROBE_GATED_ROLES:
        text = out_file.read_text()
        if not _PROBE_BLOCK_RE.search(text):
            with log_file.open("a") as lf:
                lf.write(
                    f"[{_ts()}] agent={name} produced output that doesn't follow "
                    "probe contract (no '### Probe' block, no 'No probes.' sentinel)\n"
                )
            return 4

    return 0


def _substitute_placeholders(template: str, **subs: str) -> str:
    """Replace {{KEY}} tokens. Caller passes pr_id, pr_title, pr_url, pr_author,
    specialist_name (optional), operator_name."""
    for key, val in subs.items():
        token = "{{" + key.upper() + "}}"
        template = template.replace(token, val)
    return template


def _strip_leading_html_comment(text: str) -> str:
    """Drop a leading <!-- ... --> block (operator docs in voice.md)."""
    if not text.lstrip().startswith("<!--"):
        return text
    # Find closing --> after the first <!--
    start = text.index("<!--")
    end = text.find("-->", start)
    if end < 0:
        return text  # malformed; pass through
    # Skip past --> and any trailing newline
    after = text[end + 3:]
    return after.lstrip("\n")


def build_prompt(
    kind: str,
    agent: str,
    prompts_dir: str,
    pr_id: str,
    pr_title: str,
    pr_url: str,
    pr_author: str,
) -> str:
    """Build the prompt string for one codex call.

    `kind` is one of: 'standalone' (intent, dead-code-search, momentum),
    'specialist' (the 8 angles), 'critic' (per-angle critic-<angle>), 'aggregator'.
    """
    pdir = Path(prompts_dir)
    operator_name = os.environ.get("OPERATOR_NAME", "Sam")
    base_subs = dict(
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url,
        pr_author=pr_author, operator_name=operator_name,
    )

    if kind == "specialist":
        common = (pdir / "common-header.md").read_text()
        body = (pdir / f"{agent}.md").read_text()
        subs = dict(base_subs, specialist_name=agent)
        return (
            _substitute_placeholders(common, **subs)
            + "\n"
            + _substitute_placeholders(body, **subs)
        )

    if kind == "standalone":
        # intent, dead-code-search, momentum. (go-deep dispatch was orchestrate.sh's
        # responsibility and is dropped here per the plan note above; if Phase 6
        # reintroduces go-deep, add the agent.startswith("go-deep-") branch back.)
        body = (pdir / f"{agent}.md").read_text()
        subs = dict(base_subs, specialist_name="")
        return _substitute_placeholders(body, **subs)

    if kind == "critic":
        # Per-angle critic: critic-<angle>. Body cites
        # .codex-scratch/specialists/{{ANGLE}}.md; ANGLE substitution happens here.
        body = (pdir / "critic.md").read_text()
        angle = agent[len("critic-"):] if agent.startswith("critic-") else ""
        subs = dict(base_subs, angle=angle, specialist_name=angle)
        return _substitute_placeholders(body, **subs)

    if kind == "aggregator":
        agg = (pdir / "aggregator.md").read_text()
        voice_path = pdir / "voice.md"
        if not voice_path.exists():
            raise FileNotFoundError(
                f"build_prompt: voice.md missing at {voice_path} — incomplete install"
            )
        if "INSERT_VOICE_HERE" not in agg:
            raise ValueError(
                "build_prompt: aggregator.md missing INSERT_VOICE_HERE marker — stitch contract violated"
            )
        voice_body = _strip_leading_html_comment(voice_path.read_text())
        # Replace the line containing INSERT_VOICE_HERE with the voice body.
        # Match the same shape as the prior awk: any line containing the marker.
        out_lines: list[str] = []
        for line in agg.splitlines(keepends=True):
            if "INSERT_VOICE_HERE" in line:
                out_lines.append(voice_body)
                if not voice_body.endswith("\n"):
                    out_lines.append("\n")
            else:
                out_lines.append(line)
        stitched = "".join(out_lines)
        return _substitute_placeholders(stitched, **base_subs)

    raise ValueError(f"build_prompt: unknown kind '{kind}'")


def _validate_critic_output(spec_text: str, crit_text: str) -> str | None:
    """Validate critic output against the specialist's probe count.

    The semantic contract a regex can't enforce: critic must address EVERY
    specialist probe by ID with Answer + Evidence fields, OR emit the bare
    'No probes.' sentinel — but only when the specialist had zero probes.
    Eliminates the bug class where the critic emits a valid-looking H2 but
    silently skips probes (or vice versa).

    Returns None on success, an error message on failure.
    """
    spec_probe_ids = set(_PROBE_HEADER_RE.findall(spec_text))

    if not spec_probe_ids:
        # Specialist had no probes — critic must emit exactly 'No probes.'
        if crit_text.strip() != "No probes.":
            return (
                "specialist emitted 0 probes; critic must respond with bare "
                f"'No probes.' sentinel (got first 80 chars: {crit_text[:80]!r})"
            )
        return None

    # Specialist had probes — critic must have the layered H2 header
    if "## Critic counter-arguments" not in crit_text:
        return (
            f"specialist emitted {len(spec_probe_ids)} probe(s); critic missing "
            "'## Critic counter-arguments' H2 header"
        )

    # Every specialist probe must have a critic resolution block
    crit_probe_ids = set(_PROBE_HEADER_RE.findall(crit_text))
    missing = spec_probe_ids - crit_probe_ids
    if missing:
        return (
            f"critic missing resolution for probe(s): "
            f"{sorted(missing, key=int)}"
        )

    # Each critic probe block must carry both Answer + Evidence fields
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


def run_angle(
    angle: str,
    repo_dir: str,
    run_dir: str,
    prompts_dir: str,
    pr_id: str,
    pr_title: str,
    pr_url: str,
    pr_author: str,
) -> int:
    """Run one per-angle pipeline: specialist → critic.

    Returns the codex exit code of whichever stage failed (or 0 on full
    success). Layered file (`specialist + ## Critic counter-arguments +
    critic`) is written to both `<run_dir>/agents/<angle>/layered.md` and
    `<repo_dir>/.codex-scratch/specialists/<angle>.md` only on full success.
    """
    run = Path(run_dir)
    repo = Path(repo_dir)

    # 1. Specialist
    spec_prompt = build_prompt(
        kind="specialist", agent=angle, prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    spec_agent_dir = run / "agents" / angle
    spec_rc = run_codex(angle, str(repo), spec_prompt, str(spec_agent_dir))
    if spec_rc != 0:
        log(f"{pr_id}: specialist {angle} exited non-zero (see {spec_agent_dir}/log.txt)")
        return spec_rc
    spec_out = (spec_agent_dir / "output.md").read_text()

    # Stage specialist output to .codex-scratch BEFORE the critic runs, so the
    # per-angle critic can read its canonical input via the path documented in
    # prompts/critic.md (no inline prompt augmentation needed). The file is
    # overwritten with the layered content after a successful critic.
    scratch_path = repo / ".codex-scratch" / "specialists" / f"{angle}.md"
    scratch_path.parent.mkdir(parents=True, exist_ok=True)
    scratch_path.write_text(spec_out)

    # 2. Per-angle critic — reads .codex-scratch/specialists/<angle>.md
    crit_prompt = build_prompt(
        kind="critic", agent=f"critic-{angle}", prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    crit_agent_dir = run / "agents" / f"critic-{angle}"
    crit_rc = run_codex(f"critic-{angle}", str(repo), crit_prompt, str(crit_agent_dir))
    if crit_rc != 0:
        log(f"{pr_id}: critic-{angle} exited non-zero (see {crit_agent_dir}/log.txt)")
        return crit_rc
    crit_out = (crit_agent_dir / "output.md").read_text()

    # Semantic contract validation: critic must address every specialist
    # probe by ID with Answer + Evidence, or emit the bare 'No probes.'
    # sentinel matching a zero-probe specialist. Catches malformed critic
    # output before it reaches aggregation. (run_codex's regex gate covers
    # specialist output only — critic correctness depends on cross-file
    # state and lives here.)
    err = _validate_critic_output(spec_out, crit_out)
    if err:
        log(
            f"{pr_id}: critic-{angle} contract violation: {err} "
            f"(see {crit_agent_dir}/output.md)"
        )
        return 4

    # 3. Compose layered file. The critic's own '## Critic counter-arguments'
    # H2 owns its section; pipeline only adds the '---' separator so the H2
    # isn't doubled.
    layered = spec_out + "\n\n---\n\n" + crit_out
    (spec_agent_dir / "layered.md").write_text(layered)
    scratch_path.write_text(layered)

    return 0


def _abort(repo_dir: Path, msg: str) -> int:
    """Log + clean up REPO_DIR + return non-zero exit. Caller exits."""
    log(msg)
    if repo_dir.exists():
        # Match orchestrate.sh's `rm -rf "$REPO_DIR"` cleanup.
        import shutil
        shutil.rmtree(repo_dir, ignore_errors=True)
    return 1


def _validate_intent(intent_out: Path, pr_id: str) -> str | None:
    """Return None on success, error message on validation failure."""
    if not intent_out.exists() or intent_out.stat().st_size == 0:
        return f"{pr_id}: intent inference failed (empty output)"
    text = intent_out.read_text()
    nonblank = [ln for ln in text.splitlines() if ln.strip()]
    if len(nonblank) != 1:
        return (
            f"{pr_id}: intent output has {len(nonblank)} non-blank lines, "
            "expected exactly 1 — aborting"
        )
    if not text.startswith("Inferred intent: ") and not any(
        ln.startswith("Inferred intent: ") for ln in nonblank
    ):
        return f"{pr_id}: intent output missing 'Inferred intent: ' prefix — aborting"
    return None


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
    <run_dir>/agents/aggregator/output.md; the caller posts it.

    Every stage fails loud. dead-code-search aborts on failure (no
    soft-degrade path).
    """
    repo = Path(repo_dir)
    run = Path(run_dir)

    common_kwargs = dict(
        prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )

    # 1. Intent (sequential, fail-loud)
    log(f"{pr_id}: inferring developer intent...")
    intent_prompt = build_prompt(kind="standalone", agent="intent", **common_kwargs)
    intent_dir = run / "agents" / "intent"
    rc = run_codex("intent", str(repo), intent_prompt, str(intent_dir))
    if rc != 0:
        return _abort(repo, f"{pr_id}: intent inference failed (exit={rc}) — aborting")
    err = _validate_intent(intent_dir / "output.md", pr_id)
    if err:
        return _abort(repo, err)
    # Symlink so prompt-cited paths resolve
    scratch = repo / ".codex-scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    intent_link = scratch / "inferred-intent.md"
    if intent_link.exists() or intent_link.is_symlink():
        intent_link.unlink()
    intent_link.symlink_to(intent_dir / "output.md")
    log(f"{pr_id}: intent inference complete: {(intent_dir / 'output.md').read_text().splitlines()[0]}")

    # 2. Dead-code-search (sequential, fail-loud — no soft-degrade)
    log(f"{pr_id}: dead-code search...")
    dc_prompt = build_prompt(kind="standalone", agent="dead-code-search", **common_kwargs)
    dc_dir = run / "agents" / "dead-code-search"
    rc = run_codex("dead-code-search", str(repo), dc_prompt, str(dc_dir))
    if rc != 0:
        return _abort(repo, f"{pr_id}: dead-code search failed (exit={rc}) — aborting")
    dc_link = scratch / "dead-code.md"
    if dc_link.exists() or dc_link.is_symlink():
        dc_link.unlink()
    dc_link.symlink_to(dc_dir / "output.md")
    log(f"{pr_id}: dead-code search complete")

    # 3. 8 angle pipelines in parallel (each = specialist → critic)
    log(f"{pr_id}: launching {len(ANGLES)} per-angle pipelines in parallel...")
    angle_kwargs = dict(
        repo_dir=repo_dir, run_dir=run_dir,
        **common_kwargs,
    )
    angle_failure: str | None = None
    with ThreadPoolExecutor(max_workers=len(ANGLES)) as ex:
        futures = {ex.submit(run_angle, angle=a, **angle_kwargs): a for a in ANGLES}
        for fut in as_completed(futures):
            angle = futures[fut]
            try:
                rc = fut.result()
            except Exception as exc:
                angle_failure = (
                    f"{pr_id}: angle {angle} raised {type(exc).__name__}: {exc} — aborting"
                )
                break
            if rc != 0:
                angle_failure = (
                    f"{pr_id}: angle {angle} exited non-zero (rc={rc}, see "
                    f"{run}/agents/{angle}/log.txt or {run}/agents/critic-{angle}/log.txt) "
                    "— aborting"
                )
                break
    # Outside the `with` block: executor.shutdown(wait=True) has finished, so
    # no in-flight angle thread can re-create repo_dir between rmtree and now.
    if angle_failure is not None:
        return _abort(repo, angle_failure)
    log(f"{pr_id}: all {len(ANGLES)} angle pipelines completed")

    # 4. Momentum (re-reviews only)
    prev_review = run / "inputs" / "previous-review.md"
    if prev_review.exists() and prev_review.stat().st_size > 0:
        log(f"{pr_id}: launching momentum specialist (re-review)...")
        m_prompt = build_prompt(kind="standalone", agent="momentum", **common_kwargs)
        m_dir = run / "agents" / "momentum"
        rc = run_codex("momentum", str(repo), m_prompt, str(m_dir))
        if rc != 0:
            return _abort(repo, f"{pr_id}: momentum specialist failed (exit={rc}) — aborting")
        m_link = scratch / "momentum.md"
        if m_link.exists() or m_link.is_symlink():
            m_link.unlink()
        m_link.symlink_to(m_dir / "output.md")
    else:
        log(f"{pr_id}: skipping momentum specialist (first review)")

    # 5. Aggregator
    log(f"{pr_id}: aggregator...")
    agg_prompt = build_prompt(kind="aggregator", agent="aggregator", **common_kwargs)
    agg_dir = run / "agents" / "aggregator"
    rc = run_codex("aggregator", str(repo), agg_prompt, str(agg_dir))
    if rc != 0:
        return _abort(repo, f"{pr_id}: aggregator failed (exit={rc}) — aborting")
    if not (agg_dir / "output.md").exists() or (agg_dir / "output.md").stat().st_size == 0:
        return _abort(repo, f"{pr_id}: aggregator produced empty output — aborting")
    log(f"{pr_id}: aggregator complete")
    return 0


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(f"usage: {sys.argv[0]} REPO_DIR RUN_DIR\n")
        return 2
    repo_dir, run_dir = sys.argv[1], sys.argv[2]
    prompts_dir = os.environ.get("PROMPTS_DIR", os.path.expanduser("~/.pr-reviewer/prompts"))
    pr_id = os.environ["PR_ID"]
    pr_title = os.environ["PR_TITLE"]
    pr_url = os.environ["PR_URL"]
    pr_author = os.environ["PR_AUTHOR"]
    return run_pipeline(
        repo_dir=repo_dir, run_dir=run_dir, prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )


if __name__ == "__main__":
    sys.exit(main())
