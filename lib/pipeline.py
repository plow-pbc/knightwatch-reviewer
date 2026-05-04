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
# different output shapes and are exempt.
_PROBE_GATED_ROLES = {
    "security", "data-integrity", "architecture",
    "simplification", "tests", "shape", "performance", "consumers",
}
_PROBE_BLOCK_RE = re.compile(r"^### Probe |^No probes\.$", re.MULTILINE)

ANGLES = (
    "security", "data-integrity", "architecture", "simplification",
    "tests", "shape", "performance", "consumers",
)


def _ts() -> str:
    return time.strftime("%H:%M:%S")


def _log_file() -> Path | None:
    p = os.environ.get("LOG_FILE")
    return Path(p) if p else None


def log(msg: str) -> None:
    """Append a timestamped line to $LOG_FILE; matches the shell `log` helper."""
    logf = _log_file()
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n"
    if logf:
        with logf.open("a") as f:
            f.write(line)
    else:
        sys.stderr.write(line)


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

    # Probe-contract gate for the 8 angle specialists.
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
