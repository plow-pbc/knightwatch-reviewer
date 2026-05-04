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
