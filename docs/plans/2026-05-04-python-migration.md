# Python Migration: Per-Angle Critics, No Splitter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `lib/orchestrate.sh` + `lib/critic-splitter.sh` + `lib/run-specialist.sh` + `lib/prompt-build.sh` with a single ~200 LOC Python entrypoint (`lib/pipeline.py`, stdlib only), eliminating the centralized critic + splitter in favor of N parallel per-angle critics that append directly to their specialist's file.

**Architecture:** Per spec `docs/specs/2026-05-04-python-migration-design.md`. 8 per-angle pipelines run in parallel via `concurrent.futures.ThreadPoolExecutor`; each pipeline runs specialist→critic sequentially. The critic for each angle reads ONE specialist's output and emits Answer/Evidence per probe, appending `## Critic counter-arguments` directly to `specialists/<angle>.md`. No central critic, no splitter, no router, no JSON. Every stage fails loud.

**Tech Stack:** Python 3.x stdlib only (`subprocess`, `pathlib`, `concurrent.futures`, `unittest`, `os`, `sys`). No pip dependencies. Shell remnants (`review.sh`, `lib/review-one-pr.sh`, `lib/replay.sh`, timer scripts) call `python3 lib/pipeline.py` instead of sourcing shell helpers.

---

## File Structure

**New:**
- `lib/pipeline.py` — single file containing `run_codex`, `build_prompt`, `run_angle`, `run_pipeline`, plus `if __name__ == "__main__"` CLI entry. ~200 LOC.
- `lib/tests/test_pipeline.py` — stdlib `unittest` tests with mocked `subprocess.run`. ~150 LOC.

**Modified:**
- `lib/review-one-pr.sh` — drop `source` lines for `prompt-build.sh`/`orchestrate.sh`/`critic-splitter.sh`; replace `run_specialist_pipeline` call with `python3 "$_LIB_DIR/pipeline.py"` invocation; gate posting on the pipeline's exit code + `$RUN_DIR/agents/aggregator/output.md` content (instead of `$AGG_EXIT`/`$AGG_OUT` shell vars).
- `lib/replay.sh` — same pattern: drop sources, invoke Python entrypoint.
- `prompts/critic.md` — rewrite as per-angle prompt: reads ONE specialist's output, emits Answer/Evidence per probe, optionally generates new probes within that angle. Drops cross-angle resolution shape, `## Generated probes` section, carry-forward routing prose, the R36 `No probes.` sentinel.
- `prompts/aggregator.md` — small update: explicitly absorb cross-angle pattern-spotting (today's central-critic responsibility).
- `install.sh` — add `python3 --version` precondition check.
- `justfile` — add `python3 -m unittest discover -s lib/tests -p 'test_*.py' -v` line.
- `lib/tests/prompt-contracts-smoke.sh` — drop splitter-token assertions + dispatch_agent format checks; keep wiring/PATH/shebang fences.

**Deleted:**
- `lib/orchestrate.sh`
- `lib/critic-splitter.sh`
- `lib/run-specialist.sh`
- `lib/prompt-build.sh`
- `lib/tests/critic-splitter-smoke.sh`
- `lib/tests/dispatch-agent-smoke.sh`
- `lib/tests/run-specialist-smoke.sh`
- `lib/tests/build-specialist-prompt-smoke.sh`

**Unchanged:**
- `review.sh`, `learn-from-replies.sh`, `approve-from-replies.sh`, `plow-kid-refresh.sh`, `re-request-poller.sh` — orthogonal timer scripts.
- All other `lib/*.sh` helpers (state-io, run-dir, gh-comments, tracked-repos, auth, decline-history, loc-trend, scratch, path-scrub, locking, knightwatch-config, search-roots, sibling-symlinks, diff-build, go-deep-rank, checks/*).
- All systemd unit files.
- All other prompt files (8 specialist prompts, intent.md, momentum.md, dead-code-search.md, go-deep.md, common-header.md, voice.md, probe-schema.md).
- All other smokes (~16 files).

**Note on go-deep:** The current orchestrate.sh dispatches go-deep tech-leads only when the critic emits "Calibration questions for go-deep" markers. Under probe-as-unit (Phase 4), the critic stopped emitting those markers — go-deep is currently idle. The new `lib/pipeline.py` skips go-deep dispatch entirely; `prompts/go-deep.md` and `lib/go-deep-rank.sh` stay on disk for future Phase 6 re-introduction.

---

## Task 1: `run_codex` — codex subprocess wrapper

**Files:**
- Create: `lib/__init__.py` (empty — needed for `python3 -m unittest lib.tests.test_pipeline` to resolve)
- Create: `lib/tests/__init__.py` (empty — same reason)
- Create: `lib/pipeline.py`
- Test: `lib/tests/test_pipeline.py`

This task replaces `lib/run-specialist.sh`. Same contract (writes prompt.txt/output.md/log.txt; exits 0/non-zero/3 per success/codex-fail/empty-output) plus the probe-contract gate from run-specialist.sh:76-83.

- [ ] **Step 0: Create empty `__init__.py` files**

```bash
touch lib/__init__.py lib/tests/__init__.py
```

Empty files. Required for the `python3 -m unittest lib.tests.test_pipeline` invocation pattern.

- [ ] **Step 1: Write the failing tests for `run_codex`**

```python
# lib/tests/test_pipeline.py
"""Tests for lib/pipeline.py — mocked codex subprocess."""
import os
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch, MagicMock

# Add lib/ to path so we can import pipeline
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import pipeline  # noqa: E402


class FakeCompletedProcess:
    """Minimal stand-in for subprocess.CompletedProcess."""
    def __init__(self, returncode):
        self.returncode = returncode


class TestRunCodex(unittest.TestCase):
    """run_codex wraps `codex exec`; matches lib/run-specialist.sh contract."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.repo_dir = Path(self.tmp.name) / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)
        self.agent_dir = Path(self.tmp.name) / "agents" / "intent"

    def tearDown(self):
        self.tmp.cleanup()

    def _stub_codex(self, exit_code, output_text):
        """Return a side_effect that simulates codex writing to its -o target."""
        def side_effect(argv, **kwargs):
            # Extract the -o argument (codex output target)
            out_idx = argv.index("-o")
            out_path = Path(argv[out_idx + 1])
            out_path.write_text(output_text)
            return FakeCompletedProcess(exit_code)
        return side_effect

    @patch("pipeline.subprocess.run")
    def test_success_path_writes_artifacts(self, mock_run):
        mock_run.side_effect = self._stub_codex(0, "### Probe 1\nstub\n")
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)
        self.assertEqual((self.agent_dir / "prompt.txt").read_text(), "PROMPT")
        self.assertTrue((self.agent_dir / "output.md").stat().st_size > 0)
        self.assertIn("agent=intent starting", (self.agent_dir / "log.txt").read_text())
        self.assertIn("agent=intent exit=0", (self.agent_dir / "log.txt").read_text())

    @patch("pipeline.subprocess.run")
    def test_codex_argv_pins_model(self, mock_run):
        """The model=gpt-5.5 pin must reach codex (regression fence)."""
        mock_run.side_effect = self._stub_codex(0, "### Probe 1\nstub\n")
        pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        argv = mock_run.call_args[0][0]
        self.assertIn("model=gpt-5.5", argv)
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", argv)

    @patch("pipeline.subprocess.run")
    def test_codex_nonzero_exit_propagates(self, mock_run):
        mock_run.side_effect = self._stub_codex(7, "")
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 7)

    @patch("pipeline.subprocess.run")
    def test_codex_zero_exit_empty_output_returns_3(self, mock_run):
        """Codex says success but wrote nothing — fail loud as exit 3."""
        mock_run.side_effect = self._stub_codex(0, "")
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 3)
        self.assertIn("produced empty output", (self.agent_dir / "log.txt").read_text())

    @patch("pipeline.subprocess.run")
    def test_specialist_must_emit_probe_or_no_probes_sentinel(self, mock_run):
        """Probe-emitting roles must include `### Probe ` or `No probes.` — exit 4 otherwise."""
        mock_run.side_effect = self._stub_codex(0, "garbage that doesn't look like a probe\n")
        rc = pipeline.run_codex("security", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 4)

    @patch("pipeline.subprocess.run")
    def test_specialist_no_probes_sentinel_passes(self, mock_run):
        mock_run.side_effect = self._stub_codex(0, "No probes.\n")
        rc = pipeline.run_codex("security", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.run")
    def test_intent_exempt_from_probe_gate(self, mock_run):
        """Non-probe-emitting roles (intent, critic, aggregator, etc.) skip the gate."""
        mock_run.side_effect = self._stub_codex(0, "Inferred intent: doing X.\n")
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.run")
    def test_critic_per_angle_exempt_from_probe_gate(self, mock_run):
        """Per-angle critics (critic-security, critic-shape, ...) emit Answer/Evidence prose."""
        mock_run.side_effect = self._stub_codex(0, "- **Answer:** yes\n- **Evidence:** cited\n")
        rc = pipeline.run_codex("critic-security", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
python3 -m unittest lib.tests.test_pipeline -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'pipeline'` (or similar — pipeline.py doesn't exist yet).

- [ ] **Step 3: Create `lib/pipeline.py` with `run_codex`**

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
python3 -m unittest lib.tests.test_pipeline -v
```

Expected: 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/__init__.py lib/tests/__init__.py lib/pipeline.py lib/tests/test_pipeline.py
git commit -m "feat(pipeline): run_codex — Python wrapper around codex exec

Replaces lib/run-specialist.sh's contract: writes prompt.txt, output.md,
log.txt; exits 0/non-zero/3/4 per success/codex-fail/empty/probe-contract-
violation. Stdlib only (subprocess + pathlib).

Tests cover success path, codex non-zero propagation, empty-output exit 3,
the model=gpt-5.5 pin (regression fence), probe-contract gate for the 8
angle specialists, exemption for non-probe roles (intent, critic-*).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `build_prompt` — placeholder substitution + common-header concat + voice.md stitch

**Files:**
- Modify: `lib/pipeline.py`
- Modify: `lib/tests/test_pipeline.py`

This task replaces `lib/prompt-build.sh`'s three functions: `safe_sed`, `substitute_placeholders`, `build_specialist_prompt`, `build_aggregator_prompt`.

- [ ] **Step 1: Write the failing tests for `build_prompt`**

Add to `lib/tests/test_pipeline.py` (above the `if __name__` line):

```python
class TestBuildPrompt(unittest.TestCase):
    """build_prompt handles placeholder substitution + common-header + voice.md stitch."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.prompts = Path(self.tmp.name) / "prompts"
        self.prompts.mkdir()
        # Minimal common-header.md
        (self.prompts / "common-header.md").write_text(
            "PR: {{PR_ID}} ({{PR_TITLE}}) by {{PR_AUTHOR}}\n"
            "Specialist: {{SPECIALIST_NAME}}\n"
        )
        # Minimal voice.md
        (self.prompts / "voice.md").write_text("Voice: speak like {{OPERATOR_NAME}}.\n")
        # Minimal aggregator.md with the stitch marker
        (self.prompts / "aggregator.md").write_text(
            "# Aggregator\n"
            "<!-- INSERT_VOICE_HERE -->\n"
            "Render the review for {{PR_ID}}.\n"
        )

    def tearDown(self):
        self.tmp.cleanup()

    def test_specialist_substitutes_and_concatenates(self):
        (self.prompts / "security.md").write_text(
            "Security review for {{PR_ID}} as {{SPECIALIST_NAME}}.\n"
        )
        out = pipeline.build_prompt(
            kind="specialist",
            agent="security",
            prompts_dir=str(self.prompts),
            pr_id="owner/repo#42", pr_title="Add X",
            pr_url="https://example/pull/42", pr_author="alice",
        )
        # common-header substituted + concatenated with specialist body
        self.assertIn("PR: owner/repo#42 (Add X) by alice", out)
        self.assertIn("Specialist: security", out)
        self.assertIn("Security review for owner/repo#42 as security.", out)

    def test_standalone_substitutes_no_header(self):
        """intent / dead-code-search / momentum: no common-header, no SPECIALIST_NAME."""
        (self.prompts / "intent.md").write_text(
            "Infer intent for {{PR_ID}} ({{PR_TITLE}}).\n"
        )
        out = pipeline.build_prompt(
            kind="standalone",
            agent="intent",
            prompts_dir=str(self.prompts),
            pr_id="owner/repo#42", pr_title="Add X",
            pr_url="https://example/pull/42", pr_author="alice",
        )
        self.assertEqual(out, "Infer intent for owner/repo#42 (Add X).\n")
        self.assertNotIn("PR: ", out)  # no common-header

    def test_critic_returns_raw_file(self):
        """critic-<angle>: raw cat, no placeholder substitution.

        Per-angle critic prompt body has no PR placeholders — the specialist's
        output (which IS the critic's input context) is appended at runtime
        by run_angle, not via build_prompt.
        """
        (self.prompts / "critic.md").write_text("Critique probes for {{ANGLE}}.\n")
        out = pipeline.build_prompt(
            kind="critic", agent="critic-security",
            prompts_dir=str(self.prompts),
            pr_id="owner/repo#42", pr_title="X", pr_url="u", pr_author="a",
        )
        self.assertEqual(out, "Critique probes for {{ANGLE}}.\n")

    def test_aggregator_stitches_voice(self):
        out = pipeline.build_prompt(
            kind="aggregator",
            agent="aggregator",
            prompts_dir=str(self.prompts),
            pr_id="owner/repo#42", pr_title="X", pr_url="u", pr_author="a",
        )
        self.assertNotIn("INSERT_VOICE_HERE", out)
        self.assertIn("Voice: speak like Sam", out)  # default OPERATOR_NAME=Sam
        self.assertIn("Render the review for owner/repo#42", out)

    def test_aggregator_operator_name_env_override(self):
        with patch.dict(os.environ, {"OPERATOR_NAME": "Chris"}):
            out = pipeline.build_prompt(
                kind="aggregator", agent="aggregator",
                prompts_dir=str(self.prompts),
                pr_id="owner/repo#42", pr_title="X", pr_url="u", pr_author="a",
            )
        self.assertIn("Voice: speak like Chris", out)

    def test_aggregator_missing_voice_raises(self):
        (self.prompts / "voice.md").unlink()
        with self.assertRaises(FileNotFoundError):
            pipeline.build_prompt(
                kind="aggregator", agent="aggregator",
                prompts_dir=str(self.prompts),
                pr_id="x", pr_title="x", pr_url="x", pr_author="x",
            )

    def test_aggregator_missing_marker_raises(self):
        (self.prompts / "aggregator.md").write_text("# No marker here\n")
        with self.assertRaises(ValueError):
            pipeline.build_prompt(
                kind="aggregator", agent="aggregator",
                prompts_dir=str(self.prompts),
                pr_id="x", pr_title="x", pr_url="x", pr_author="x",
            )

    def test_voice_md_leading_html_comment_stripped(self):
        """voice.md may begin with operator docs in <!-- ... -->; strip before stitch."""
        (self.prompts / "voice.md").write_text(
            "<!-- operator notes — how to customize -->\n"
            "Voice: speak like {{OPERATOR_NAME}}.\n"
        )
        out = pipeline.build_prompt(
            kind="aggregator", agent="aggregator",
            prompts_dir=str(self.prompts),
            pr_id="x", pr_title="x", pr_url="x", pr_author="x",
        )
        self.assertNotIn("operator notes", out)
        self.assertIn("Voice: speak like Sam", out)

    def test_per_angle_critic_substitutes_angle(self):
        """critic-<angle>: ANGLE placeholder gets the bare angle name."""
        (self.prompts / "critic.md").write_text(
            "Read .codex-scratch/specialists/{{ANGLE}}.md and critique each probe.\n"
        )
        out = pipeline.build_prompt(
            kind="critic", agent="critic-shape",
            prompts_dir=str(self.prompts),
            pr_id="x", pr_title="x", pr_url="x", pr_author="x",
        )
        # ANGLE is substituted via build_prompt's critic branch
        self.assertIn(".codex-scratch/specialists/shape.md", out)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python3 -m unittest lib.tests.test_pipeline.TestBuildPrompt -v
```

Expected: FAIL with `AttributeError: module 'pipeline' has no attribute 'build_prompt'`.

- [ ] **Step 3: Add `build_prompt` to `lib/pipeline.py`**

Append to `lib/pipeline.py`:

```python
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

    `kind` is one of: 'standalone' (intent, dead-code-search, momentum, go-deep-*),
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m unittest lib.tests.test_pipeline -v
```

Expected: 16 tests PASS (Task 1's 7 + Task 2's 9).

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline.py lib/tests/test_pipeline.py
git commit -m "feat(pipeline): build_prompt — placeholder substitution + voice stitch

Replaces lib/prompt-build.sh's safe_sed/substitute_placeholders/
build_specialist_prompt/build_aggregator_prompt. Four kinds:
- specialist: common-header + angle body, substituted
- standalone: intent/dead-code-search/momentum/go-deep-* (no header)
- critic: per-angle critic with ANGLE substitution (new shape)
- aggregator: voice.md stitched at INSERT_VOICE_HERE, then substituted

OPERATOR_NAME defaults to 'Sam', overridable via env var. voice.md's
leading <!-- ... --> operator docs are stripped before stitching.
Missing voice.md → FileNotFoundError; missing INSERT_VOICE_HERE marker
→ ValueError. Both fail-loud at the boundary, matching the prior
shell behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `run_angle` — specialist → critic, layered file write

**Files:**
- Modify: `lib/pipeline.py`
- Modify: `lib/tests/test_pipeline.py`

`run_angle` is the per-angle pipeline: run specialist, then run critic on its output, compose layered file. Replaces orchestrate.sh's per-angle `dispatch_agent` + critic-splitter routing.

- [ ] **Step 1: Write the failing tests for `run_angle`**

Add to `lib/tests/test_pipeline.py`:

```python
class TestRunAngle(unittest.TestCase):
    """run_angle dispatches specialist→critic, composes layered file."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.repo_dir = Path(self.tmp.name) / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)
        (self.repo_dir / ".codex-scratch" / "specialists").mkdir(parents=True)
        self.run_dir = Path(self.tmp.name) / "run"
        (self.run_dir / "agents").mkdir(parents=True)

        # Minimal prompts dir so build_prompt can resolve files
        self.prompts = Path(self.tmp.name) / "prompts"
        self.prompts.mkdir()
        (self.prompts / "common-header.md").write_text("HEADER {{SPECIALIST_NAME}}\n")
        (self.prompts / "security.md").write_text("BODY for {{SPECIALIST_NAME}}\n")
        (self.prompts / "critic.md").write_text("Critique {{ANGLE}}.\n")

    def tearDown(self):
        self.tmp.cleanup()

    def _make_codex_stub(self, plan):
        """plan: dict mapping agent name → (exit_code, output_text)."""
        def side_effect(argv, **kwargs):
            # Recover agent name from -o argument's parent dir
            out_idx = argv.index("-o")
            out_path = Path(argv[out_idx + 1])
            agent_name = out_path.parent.name
            ec, out = plan.get(agent_name, (0, "### Probe 1\nstub\n"))
            out_path.write_text(out)
            return FakeCompletedProcess(ec)
        return side_effect

    @patch("pipeline.subprocess.run")
    def test_specialist_then_critic_writes_layered_file(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "security": (0, "### Probe 1\nspecialist body\n"),
            "critic-security": (0, "- **Answer:** yes\n- **Evidence:** cited\n"),
        })
        rc = pipeline.run_angle(
            angle="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        # Layered file in both run-dir + .codex-scratch
        layered = (self.run_dir / "agents" / "security" / "layered.md").read_text()
        scratch = (self.repo_dir / ".codex-scratch" / "specialists" / "security.md").read_text()
        self.assertEqual(layered, scratch)
        self.assertIn("specialist body", layered)
        self.assertIn("## Critic counter-arguments", layered)
        self.assertIn("- **Answer:** yes", layered)

    @patch("pipeline.subprocess.run")
    def test_specialist_failure_skips_critic(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "security": (7, ""),
        })
        rc = pipeline.run_angle(
            angle="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 7)
        # Critic agent dir should NOT exist (didn't run)
        self.assertFalse((self.run_dir / "agents" / "critic-security").exists())

    @patch("pipeline.subprocess.run")
    def test_specialist_success_critic_failure_returns_critic_rc(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "security": (0, "### Probe 1\nstub\n"),
            "critic-security": (5, ""),
        })
        rc = pipeline.run_angle(
            angle="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 5)
        # Layered file NOT written
        self.assertFalse(
            (self.repo_dir / ".codex-scratch" / "specialists" / "security.md").exists()
        )
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python3 -m unittest lib.tests.test_pipeline.TestRunAngle -v
```

Expected: FAIL with `AttributeError: module 'pipeline' has no attribute 'run_angle'`.

- [ ] **Step 3: Add `run_angle` to `lib/pipeline.py`**

Append to `lib/pipeline.py`:

```python
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

    # 2. Per-angle critic
    crit_prompt = build_prompt(
        kind="critic", agent=f"critic-{angle}", prompts_dir=prompts_dir,
        pr_id=pr_id, pr_title=pr_title, pr_url=pr_url, pr_author=pr_author,
    )
    # Critic prompt is augmented with the specialist's output as context.
    crit_full_prompt = (
        crit_prompt
        + "\n\n---\n\n## Specialist output to critique\n\n"
        + spec_out
    )
    crit_agent_dir = run / "agents" / f"critic-{angle}"
    crit_rc = run_codex(f"critic-{angle}", str(repo), crit_full_prompt, str(crit_agent_dir))
    if crit_rc != 0:
        log(f"{pr_id}: critic-{angle} exited non-zero (see {crit_agent_dir}/log.txt)")
        return crit_rc
    crit_out = (crit_agent_dir / "output.md").read_text()

    # 3. Compose layered file
    layered = spec_out + "\n\n---\n\n## Critic counter-arguments\n\n" + crit_out
    (spec_agent_dir / "layered.md").write_text(layered)
    scratch_path = repo / ".codex-scratch" / "specialists" / f"{angle}.md"
    scratch_path.parent.mkdir(parents=True, exist_ok=True)
    scratch_path.write_text(layered)

    return 0
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m unittest lib.tests.test_pipeline -v
```

Expected: 19 tests PASS (Task 1+2's 16 + Task 3's 3).

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline.py lib/tests/test_pipeline.py
git commit -m "feat(pipeline): run_angle — specialist → per-angle critic, layered file

One per-angle pipeline runs specialist via run_codex, reads its output,
then runs critic-<angle> with the specialist output appended as context.
On full success, composes the layered file (specialist + Critic
counter-arguments + critic) and writes it to both:
  - <run_dir>/agents/<angle>/layered.md (operator-inspection artifact)
  - <repo_dir>/.codex-scratch/specialists/<angle>.md (aggregator's input)

Replaces orchestrate.sh's per-angle dispatch + critic-splitter routing
in one function. No central critic, no splitter, no router. Specialist
failure → critic doesn't run; critic failure → no layered file written
(angle pipeline returns the failing rc).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `run_pipeline` — full orchestration with parallel angles

**Files:**
- Modify: `lib/pipeline.py`
- Modify: `lib/tests/test_pipeline.py`

`run_pipeline` is the main entrypoint. Sequence: intent → dead-code-search → 8 angles in parallel → momentum (re-reviews only) → aggregator. Every stage fails loud.

- [ ] **Step 1: Write the failing tests for `run_pipeline`**

Add to `lib/tests/test_pipeline.py`:

```python
class TestRunPipeline(unittest.TestCase):
    """run_pipeline orchestrates the full review."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.repo_dir = Path(self.tmp.name) / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)
        (self.repo_dir / ".codex-scratch" / "specialists").mkdir(parents=True)
        self.run_dir = Path(self.tmp.name) / "run"
        (self.run_dir / "agents").mkdir(parents=True)
        (self.run_dir / "inputs").mkdir(parents=True)

        # Minimal prompts dir
        self.prompts = Path(self.tmp.name) / "prompts"
        self.prompts.mkdir()
        (self.prompts / "common-header.md").write_text("H {{SPECIALIST_NAME}}\n")
        for angle in pipeline.ANGLES:
            (self.prompts / f"{angle}.md").write_text(f"BODY {angle}\n")
        (self.prompts / "intent.md").write_text("intent prompt\n")
        (self.prompts / "dead-code-search.md").write_text("dc prompt\n")
        (self.prompts / "momentum.md").write_text("momentum prompt\n")
        (self.prompts / "critic.md").write_text("critic prompt\n")
        (self.prompts / "voice.md").write_text("Voice: {{OPERATOR_NAME}}\n")
        (self.prompts / "aggregator.md").write_text("# Agg\n<!-- INSERT_VOICE_HERE -->\nAgg body\n")

    def tearDown(self):
        self.tmp.cleanup()

    def _make_codex_stub(self, plan, default=(0, "### Probe 1\nstub\n")):
        def side_effect(argv, **kwargs):
            out_idx = argv.index("-o")
            out_path = Path(argv[out_idx + 1])
            agent_name = out_path.parent.name
            ec, out = plan.get(agent_name, default)
            # Special-case intent so the validation matcher passes
            if agent_name == "intent" and ec == 0 and out == default[1]:
                out = "Inferred intent: stub.\n"
            out_path.write_text(out)
            return FakeCompletedProcess(ec)
        return side_effect

    @patch("pipeline.subprocess.run")
    def test_first_review_runs_intent_dc_angles_aggregator(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc evidence\n"),
            "aggregator": (0, "# Review\nVERDICT: APPROVE\n"),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        # All 8 angles ran
        for angle in pipeline.ANGLES:
            self.assertTrue((self.run_dir / "agents" / angle / "output.md").exists())
            self.assertTrue((self.run_dir / "agents" / f"critic-{angle}" / "output.md").exists())
        # Aggregator ran
        self.assertTrue((self.run_dir / "agents" / "aggregator" / "output.md").exists())
        # Momentum did NOT run (no previous-review.md)
        self.assertFalse((self.run_dir / "agents" / "momentum" / "output.md").exists())

    @patch("pipeline.subprocess.run")
    def test_re_review_runs_momentum(self, mock_run):
        (self.run_dir / "inputs" / "previous-review.md").write_text("prior review body\n")
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "momentum": (0, "momentum body\n"),
            "aggregator": (0, "# Review\nVERDICT: APPROVE\n"),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        self.assertTrue((self.run_dir / "agents" / "momentum" / "output.md").exists())

    @patch("pipeline.subprocess.run")
    def test_intent_failure_aborts(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "intent": (7, ""),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        # Repo dir should be cleaned up
        self.assertFalse(self.repo_dir.exists())

    @patch("pipeline.subprocess.run")
    def test_dead_code_failure_aborts_loud(self, mock_run):
        """dead-code-search becomes fail-loud (was fail-soft in shell pipeline)."""
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (7, ""),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.repo_dir.exists())

    @patch("pipeline.subprocess.run")
    def test_one_angle_failure_aborts_pipeline(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "shape": (5, ""),  # one angle fails
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.repo_dir.exists())

    @patch("pipeline.subprocess.run")
    def test_aggregator_failure_aborts(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "aggregator": (8, ""),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.repo_dir.exists())

    @patch("pipeline.subprocess.run")
    def test_intent_must_have_inferred_intent_prefix(self, mock_run):
        mock_run.side_effect = self._make_codex_stub({
            "intent": (0, "wrong prefix\n"),  # missing "Inferred intent: "
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.repo_dir.exists())
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python3 -m unittest lib.tests.test_pipeline.TestRunPipeline -v
```

Expected: FAIL with `AttributeError: module 'pipeline' has no attribute 'run_pipeline'`.

- [ ] **Step 3: Add `run_pipeline` and CLI entry to `lib/pipeline.py`**

Append to `lib/pipeline.py`:

```python
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
    with ThreadPoolExecutor(max_workers=len(ANGLES)) as ex:
        futures = {ex.submit(run_angle, angle=a, **angle_kwargs): a for a in ANGLES}
        for fut in as_completed(futures):
            angle = futures[fut]
            try:
                rc = fut.result()
            except Exception as exc:
                return _abort(
                    repo,
                    f"{pr_id}: angle {angle} raised {type(exc).__name__}: {exc} — aborting"
                )
            if rc != 0:
                return _abort(
                    repo,
                    f"{pr_id}: angle {angle} exited non-zero (rc={rc}, see "
                    f"{run}/agents/{angle}/log.txt or {run}/agents/critic-{angle}/log.txt) "
                    "— aborting"
                )
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m unittest lib.tests.test_pipeline -v
```

Expected: 26 tests PASS (Tasks 1+2+3's 19 + Task 4's 7).

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline.py lib/tests/test_pipeline.py
git commit -m "feat(pipeline): run_pipeline + CLI entry — full orchestration

Sequence: intent → dead-code-search → 8 angle pipelines (parallel) →
momentum (re-reviews only) → aggregator. Every stage fails loud; on
failure log + rm -rf REPO_DIR + exit 1 (matches prior shell semantics).

Drops the dead-code-search soft-degrade path that orchestrate.sh had —
fail-loud uniformly.

CLI invoked as 'python3 lib/pipeline.py REPO_DIR RUN_DIR' with PR_ID,
PR_TITLE, PR_URL, PR_AUTHOR, PROMPTS_DIR, LOG_FILE in env vars.
Aggregator output at <RUN_DIR>/agents/aggregator/output.md; caller
posts it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Wire `lib/review-one-pr.sh` to call Python pipeline

**Files:**
- Modify: `lib/review-one-pr.sh`

`review-one-pr.sh` currently sources `prompt-build.sh`/`orchestrate.sh`/`critic-splitter.sh` and calls `run_specialist_pipeline`. After this task: it invokes `python3 lib/pipeline.py` and gates posting on the exit code + aggregator output file.

- [ ] **Step 1: Read the current call site**

```bash
sed -n '105,155p;1140,1165p' /Users/so/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh
```

Expected: see the source lines (~110-150) and the `run_specialist_pipeline` call (~1150) with `AGG_EXIT`/`AGG_OUT` gate.

- [ ] **Step 2: Replace the source lines (~110-150)**

Edit `lib/review-one-pr.sh` to replace this block:

```bash
# --- prompt-build helpers (sourced from lib/prompt-build.sh) ---
. "$_LIB_DIR/prompt-build.sh"
```

(and the orchestrate.sh + critic-splitter.sh source lines, with their preceding comment blocks)

with:

```bash
# Pipeline (intent → dead-code → per-angle specialist+critic → momentum → aggregator)
# is implemented in lib/pipeline.py — invoked below as a subprocess after all
# scratch staging is done.
```

- [ ] **Step 3: Replace the `run_specialist_pipeline` call (~1150)**

Edit `lib/review-one-pr.sh` to replace this block:

```bash
run_specialist_pipeline
if [ "$AGG_EXIT" -ne 0 ] || [ ! -s "$AGG_OUT" ]; then
    log "$PR_ID: aggregator failed (exit=$AGG_EXIT, output empty=$([ ! -s "$AGG_OUT" ] && echo true || echo false)) — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW=$(cat "$AGG_OUT")
```

with:

```bash
PR_ID="$PR_ID" \
PR_TITLE="$PR_TITLE" \
PR_URL="$PR_URL" \
PR_AUTHOR="$PR_AUTHOR" \
PROMPTS_DIR="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}" \
LOG_FILE="$LOG_FILE" \
OPERATOR_NAME="${OPERATOR_NAME:-Sam}" \
    python3 "$_LIB_DIR/pipeline.py" "$REPO_DIR" "$RUN_DIR"
PIPELINE_EXIT=$?
AGG_OUT="$RUN_DIR/agents/aggregator/output.md"
if [ "$PIPELINE_EXIT" -ne 0 ] || [ ! -s "$AGG_OUT" ]; then
    log "$PR_ID: pipeline failed (exit=$PIPELINE_EXIT, agg empty=$([ ! -s "$AGG_OUT" ] && echo true || echo false)) — aborting"
    # pipeline.py already rm -rf'd $REPO_DIR on its own abort; this is the safety net.
    [ -d "$REPO_DIR" ] && rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW=$(cat "$AGG_OUT")
```

- [ ] **Step 4: Verify the worker still parses (syntax check)**

```bash
bash -n /Users/so/Hacking/knightwatch-reviewer2/lib/review-one-pr.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 5: Commit**

```bash
git add lib/review-one-pr.sh
git commit -m "feat: review-one-pr invokes lib/pipeline.py instead of shell pipeline

Drops 3 source lines (prompt-build, orchestrate, critic-splitter) and the
inline run_specialist_pipeline call + AGG_EXIT/AGG_OUT shell-var gate.
Replaces with one subprocess invocation: python3 lib/pipeline.py with
PR_ID/PR_TITLE/PR_URL/PR_AUTHOR/PROMPTS_DIR/LOG_FILE/OPERATOR_NAME in
env. Pipeline writes aggregator output to a deterministic path;
review-one-pr gates posting on the file's existence + non-empty.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Wire `lib/replay.sh` to call Python pipeline

**Files:**
- Modify: `lib/replay.sh`

`replay.sh` currently sources the same 3 shell helpers and calls `run_specialist_pipeline`. Change to invoke Python.

- [ ] **Step 1: Replace the source lines**

Edit `lib/replay.sh` to replace:

```bash
. "$LIB_DIR/state-io.sh"
. "$LIB_DIR/prompt-build.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/critic-splitter.sh"
. "$LIB_DIR/go-deep-rank.sh"
. "$LIB_DIR/orchestrate.sh"
. "$LIB_DIR/scratch.sh"
```

with:

```bash
. "$LIB_DIR/state-io.sh"
. "$LIB_DIR/run-dir.sh"
. "$LIB_DIR/scratch.sh"
# Pipeline is in lib/pipeline.py (Python). Replay invokes it as a subprocess
# after staging scratch inputs above.
```

- [ ] **Step 2: Replace the `run_specialist_pipeline` call**

Edit `lib/replay.sh` to replace:

```bash
set +e
run_specialist_pipeline
PIPELINE_RC=$?
set -e
```

with:

```bash
set +e
PR_ID="$PR_ID" \
PR_TITLE="$PR_TITLE" \
PR_URL="$PR_URL" \
PR_AUTHOR="$PR_AUTHOR" \
PROMPTS_DIR="${PROMPTS_DIR:-$LIB_DIR/../prompts}" \
LOG_FILE="$LOG_FILE" \
OPERATOR_NAME="${OPERATOR_NAME:-Sam}" \
    python3 "$LIB_DIR/pipeline.py" "$REPO_DIR" "$RUN_DIR"
PIPELINE_RC=$?
set -e
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n /Users/so/Hacking/knightwatch-reviewer2/lib/replay.sh && echo "syntax OK"
```

Expected: `syntax OK`.

- [ ] **Step 4: Commit**

```bash
git add lib/replay.sh
git commit -m "feat: replay.sh invokes lib/pipeline.py instead of shell pipeline

Drops orchestrate.sh + critic-splitter.sh + prompt-build.sh + go-deep-rank.sh
sourcing (the latter is no longer wired by the new pipeline either).
Invokes python3 lib/pipeline.py with the same env-var contract as
review-one-pr.sh.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Per-angle critic prompt rewrite

**Files:**
- Modify: `prompts/critic.md`

The current critic.md is a centralized critic that reads ALL specialist files and emits per-angle resolutions + generated probes + carry-forward routing. The new per-angle critic reads ONE specialist file (substituted via `{{ANGLE}}`) and just resolves probes within that angle.

- [ ] **Step 1: Read the current critic.md to understand what's preserved**

```bash
wc -l /Users/so/Hacking/knightwatch-reviewer2/prompts/critic.md
```

Expected: ~89 lines.

- [ ] **Step 2: Rewrite `prompts/critic.md`**

Replace the entire file content with:

```markdown
You are the per-angle critic for the **{{ANGLE}}** specialist on this PR ({{PR_ID}} — {{PR_TITLE}}). Your only job: resolve each probe the specialist emitted with cited evidence.

**Voice posture (apply to every probe you process):** Apply `standards.md` § Broken-Glass Test. Declarative voice ("Yes, this is broken at file:line") is allowed only when the specialist cited the failing path, the user-observable outcome, and the line where the contract breaks. For non-bug probes whose remedy adds complexity, apply the cost-naming clause: *"adds complexity and makes PMF iteration harder."*

FIRST, read `.codex-scratch/standards.md`, especially the "Comment Review Mistakes" section. If the specialist's probe is about to commit a documented mistake, set `Answer: no` with `Evidence:` citing the calibration entry.

Then read:
- `.codex-scratch/specialists/{{ANGLE}}.md` — the {{ANGLE}} specialist's probes (your input)
- `.codex-scratch/diff.patch` — the actual change
- `.codex-scratch/file-history.md` — recent commits on touched files
- `.codex-scratch/commits.md` — commit subjects on this branch, one per line
- `.codex-scratch/inferred-intent.md` — pre-fan-out inferred end-user-facing intent
- `.codex-scratch/author-intent.md` — the PR's own description + linked issues. **Privacy guard**: linked-issue bodies in this file may be private to consumers other than the public PR. Do NOT quote, paraphrase, or summarize that content in your output — use it to ground your resolutions, never reproduce it.
- `.codex-scratch/trigger-comment.md` — present whenever the review was triggered by a trusted-author `/srosro-review` or `/srosro-update-review`. When body is substantive prose, weight it; when it's only the bare slash command, ignore.
- `.codex-scratch/product-context.md` — product stage and roadmap
- `.codex-scratch/review-priority.md` — per-repo operating point + voice posture
- `.codex-scratch/loc-trend.md` — per-round LOC trajectory (consulted by the Pre-PMF lens below)
- `.codex-scratch/decline-history.md` — operator's prior decline replies on this PR (read prose for context; explicit `<!-- decline:class=X -->` markers are counted toward the K-decay rule below)
- `.codex-scratch/previous-review.md` — present on re-reviews; the prior posted review

**Your job — probe resolution.**

For each `### Probe N` block in `.codex-scratch/specialists/{{ANGLE}}.md`, set its final `Answer` field with cited evidence.

- **`yes`** — assumption is true. Cite a grep result, git-log line, file-history entry, decline-history mention, or the specialist's own cited `Files:`. The aggregator renders this probe as a declarative outcome with severity.
- **`no`** — assumption is false. Cite zero call-sites, history showing the case never occurred, decline-history showing the operator already declined this class ≥3 rounds, or your own diff-read showing the probe misread the code. The aggregator drops the probe with a one-line footnote.
- **`unknown`** — question is real, evidence is genuinely ambiguous, the author should answer. Use this when (a) plausible but neither grep nor history can confirm/deny, OR (b) `complexity-cost` probe whose answer depends on whether a future case appears. The aggregator renders it as an open question.

For each probe, also set `Evidence:` to a one-line citation. For `Answer: yes`, optionally set `Severity if yes:` to override the specialist's prior if your evidence changes the calculus.

**Pre-PMF lens (always-on).** For every probe, evaluate: would the failure mode the probe is asking about be observed at our operating point today? `complexity-cost` probes are deletion-oriented per `probe-schema.md` — at pre-PMF scale most defensive complexity isn't earning its place; default to `Answer: yes` (delete) unless cited evidence shows the complexity is justified. For other classes: failure-mode-not-observed → `Answer: no` with `Evidence: <firing rate observation>`. If the underlying concern is real (e.g. bug-class probe with cited path) → keep `Answer: yes` regardless of pre-PMF; the bug-class carve-out wins.

**Severe-bug carve-out.** Probes with `Class: bug` and a cited failing path describing a user-observable severe outcome (secret leak, auth bypass, command injection, path traversal, sandbox escape, data loss / corruption / silent-drop, money-affecting state inconsistency, PII exfiltration) are NEVER set to `Answer: no` via the Pre-PMF lens. Silence on a real severe-bug blocker is the bot being right and the author being wrong — keep `Answer: yes` regardless.

**K-decay (engagement-aware re-evaluation, re-reviews only).** For each probe present in `previous-review.md`, count rounds since the author engaged with it (engagement = (a) a commit on this branch that touched the cited files, OR (b) an author comment that quoted, addressed, or replied). The author has now seen the probe K times.

- K = 1–2: keep `Answer:` as the specialist set it.
- K ≥ 3 with no engagement and Class ≠ bug: set `Answer: unknown`. Either the probe is mis-scoped or the author has materially deferred it; silence at K ≥ 3 is signal.
- K ≥ 5 with no engagement and Class ≠ bug: set `Answer: no` with `Evidence: dropped — K=5 silence`.
- Class = bug: never K-decay; keep as set.

**Decline-history channel.** Two channels in `.codex-scratch/decline-history.md`:
- *Explicit class markers* (`<!-- decline:class=X -->` count ≥ 3): set `Answer: no`, `Evidence: declined N rounds, class=X`.
- *Free-form prose*: read for context; if the operator's prose pushes back on a class similar to a probe's Class, cite the prior decline reason in `Evidence:` and set `Answer: unknown` (operator's reasoning is the evidence; this PR's diff may or may not change the calculus).

**Self-referential spec guard.** If a probe cites the PR's own newly-added spec/plan/doc (any doc whose first commit on this branch is in `commits.md`) as the contract being violated, set `Answer: no` with `Evidence: self-referential — spec is mutable in this PR`.

**Output format — exactly this:**

Append a single H2 section to your output:

```
## Critic counter-arguments

### Probe N
- **Answer:** <yes|no|unknown>
- **Evidence:** <one-line citation>
- **Severity if yes:** <blocking|medium|low|nit — only if overriding the specialist's prior>

(Repeat per probe in the specialist file. Header `### Probe N` matches the specialist's probe numbering. Severity-if-yes is omitted unless you're overriding.)
```

**Empty case.** If the specialist file ended with `No probes.` (the specialist had nothing to surface), write `No probes.` on its own line as the entire critic output (no `## Critic counter-arguments` header). The pipeline recognizes this as valid empty-critic output.

**No cross-angle work.** This critic only resolves probes from the {{ANGLE}} specialist. Cross-angle pattern spotting, generated probes that no specialist found, and carry-forward of probes from prior reviews — all handled by the aggregator (`prompts/aggregator.md`), which sees all 8 specialists' layered files together.
```

- [ ] **Step 3: Verify the file is valid markdown (sanity)**

```bash
wc -l /Users/so/Hacking/knightwatch-reviewer2/prompts/critic.md
grep -c '^##' /Users/so/Hacking/knightwatch-reviewer2/prompts/critic.md
```

Expected: ~75 lines, ~3 H2 sections.

- [ ] **Step 4: Commit**

```bash
git add prompts/critic.md
git commit -m "feat(prompts): per-angle critic — drop cross-angle resolution shape

Critic prompt is now {{ANGLE}}-templated. Reads ONE specialist's
output (.codex-scratch/specialists/{{ANGLE}}.md), resolves each probe
in-place, emits one '## Critic counter-arguments' H2 section that the
pipeline appends to the specialist's file directly.

Drops:
- Cross-angle '## Resolved probes' per-angle resolution shape
- '## Generated probes' section for cross-angle critic-originated probes
- Carry-forward routing prose
- The R36 'No probes.' sentinel becomes the natural empty-output case
  (specialist returned nothing → critic returns 'No probes.')

Pre-PMF lens, severe-bug carve-out, K-decay, decline-history channel,
self-referential spec guard — all preserved per-angle. Cross-angle
work moves to the aggregator, which is already cross-angle by design.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Aggregator prompt update — absorb cross-angle work

**Files:**
- Modify: `prompts/aggregator.md`

The aggregator's current prompt assumes the central critic emitted a `## Generated probes` section + per-angle resolution deltas. Both go away. The aggregator now reads the layered specialist files directly and absorbs cross-angle pattern-spotting.

- [ ] **Step 1: Find the sections that mention the central critic + generated probes**

```bash
grep -n "Generated probes\|specialists/critic\.md\|critic-generated probes\|carried-forward" /Users/so/Hacking/knightwatch-reviewer2/prompts/aggregator.md | head -20
```

Expected: ~5-10 hits across the file.

- [ ] **Step 2: Update the input list (early in aggregator.md)**

Replace this section (around the **Inputs:** list near the top):

```
- `.codex-scratch/critic.md` — **critic per-probe resolutions + critic-generated probes. READ FIRST.**
```

with:

```
(no central critic file — each specialist's file already includes its `## Critic counter-arguments` section appended by the per-angle critic; read those layered files directly)
```

(Find the exact line via the grep above; the wording may vary.)

- [ ] **Step 3: Replace the "Read critic.md first" instruction with "Read layered specialist files"**

Search for and replace any instruction saying "read `.codex-scratch/critic.md`" or "the critic emits..." with the per-angle equivalent: "read each `.codex-scratch/specialists/<angle>.md` for that angle's specialist probes followed by the per-angle critic's `## Critic counter-arguments` resolutions."

- [ ] **Step 4: Replace the "Generated probes" rendering rule**

Find the rule (around step 6 of the aggregator's render rules) that says "render generated probes from `specialists/critic.md`" and replace with:

```
**Cross-angle probes — this aggregator's responsibility.** Per-angle critics resolve only their own specialist's probes. Cross-angle observations (e.g. "data-integrity flagged X, simplification flagged Y, both are the same race condition") and probes that no single specialist found but you notice across the layered files — emit those here as additional probes in the **Probes** block, attributed `[from: aggregator]`. Apply the same Pre-PMF lens and severe-bug carve-out from the per-angle critics.
```

- [ ] **Step 5: Replace the "Carried-forward findings via specialists/critic.md sink" instruction**

Find any text instructing "read `specialists/critic.md` for carry-forward" and replace with:

```
**Carry-forward (re-reviews only).** When `previous-review.md` is non-empty, each per-angle critic addresses prior pushback within its angle. Cross-angle carry-forward (probes that touched multiple angles) flow up here — read `previous-review.md` directly and decide whether each prior probe is still active given this round's diff and the per-angle critics' resolutions.
```

- [ ] **Step 6: Verify all references to the central critic are gone**

```bash
grep -n "central critic\|specialists/critic\.md\|critic-generated\|critic.md.*sink" /Users/so/Hacking/knightwatch-reviewer2/prompts/aggregator.md || echo "all references gone"
```

Expected: `all references gone`. (Some references to "the critic" generically may remain — those are fine, since the aggregator still references the per-angle critic counter-arguments in each layered file.)

- [ ] **Step 7: Commit**

```bash
git add prompts/aggregator.md
git commit -m "feat(prompts): aggregator absorbs cross-angle work

Per-angle critics resolve only their own specialist's probes. The
aggregator picks up:
- Cross-angle pattern spotting (probes attributed [from: aggregator])
- Cross-angle carry-forward from previous-review.md (re-reviews only)
- Per-angle layered file reads (specialist + ## Critic counter-arguments)

Drops references to the now-removed central critic + specialists/critic.md
sink + ## Generated probes section.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Delete the obsolete shell files + smokes

**Files:**
- Delete: `lib/orchestrate.sh`
- Delete: `lib/critic-splitter.sh`
- Delete: `lib/run-specialist.sh`
- Delete: `lib/prompt-build.sh`
- Delete: `lib/tests/critic-splitter-smoke.sh`
- Delete: `lib/tests/dispatch-agent-smoke.sh`
- Delete: `lib/tests/run-specialist-smoke.sh`
- Delete: `lib/tests/build-specialist-prompt-smoke.sh`

- [ ] **Step 1: Verify no remaining references in tracked files**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
grep -rln "orchestrate\.sh\|critic-splitter\.sh\|run-specialist\.sh\|prompt-build\.sh\|run_specialist_pipeline\|split_critic_to_specialists\|dispatch_agent\|build_specialist_prompt\|build_aggregator_prompt" \
    --include='*.sh' --include='*.md' --include='*.py' --include='*.conf' --include='justfile' \
    -- . 2>/dev/null | grep -v '^docs/' | grep -v '^\./docs/' | head -20
```

Expected: only documentation references (in `docs/`) that describe the migration. Production paths should be empty. If anything else shows up, fix the reference before deleting.

- [ ] **Step 2: Delete the shell files**

```bash
git rm lib/orchestrate.sh lib/critic-splitter.sh lib/run-specialist.sh lib/prompt-build.sh
git rm lib/tests/critic-splitter-smoke.sh lib/tests/dispatch-agent-smoke.sh lib/tests/run-specialist-smoke.sh lib/tests/build-specialist-prompt-smoke.sh
```

- [ ] **Step 3: Verify they're gone**

```bash
ls lib/orchestrate.sh lib/critic-splitter.sh lib/run-specialist.sh lib/prompt-build.sh 2>&1
```

Expected: 4× `No such file or directory`.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: delete obsolete shell pipeline + smokes

The Python pipeline (lib/pipeline.py) replaces these. Total LOC removed:
~666 from lib/ + ~1100 from lib/tests/.

Removed:
- lib/orchestrate.sh (run_specialist_pipeline, dispatch_agent, persist_layered_specialists)
- lib/critic-splitter.sh (split_critic_to_specialists)
- lib/run-specialist.sh (codex exec wrapper)
- lib/prompt-build.sh (placeholder substitution + voice stitch)
- lib/tests/critic-splitter-smoke.sh
- lib/tests/dispatch-agent-smoke.sh
- lib/tests/run-specialist-smoke.sh
- lib/tests/build-specialist-prompt-smoke.sh

The whole BCR-recurring class (whitespace-only generated probes, header-only
output, missing fields, etc.) goes with them — no parser → no parser
edge cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Update `prompt-contracts-smoke.sh` — drop splitter/dispatch tokens

**Files:**
- Modify: `lib/tests/prompt-contracts-smoke.sh`

The smoke has assertions for splitter tokens (REMEDY-BLOAT, generated-probe shape) and dispatch_agent format checks that no longer apply. Trim them.

- [ ] **Step 1: Find splitter/dispatch references**

```bash
grep -n "split_critic\|dispatch_agent\|critic-splitter\|orchestrate\.sh\|Generated probes\|specialists/critic\.md" /Users/so/Hacking/knightwatch-reviewer2/lib/tests/prompt-contracts-smoke.sh | head -20
```

Expected: ~5-10 hits across the smoke.

- [ ] **Step 2: Remove the offending assertions inline**

For each match from Step 1:
- Use `Edit` to remove that single `assert_grep "..." "..." prompts/...` line (and its preceding `echo ".."` line).
- Do NOT remove assertions for tokens that still apply (e.g. `Severe-bug carve-out`, the per-angle complexity-cost token, PATH-ordering fences, shebang fences).

- [ ] **Step 3: Run the smoke to verify it still passes**

```bash
PATH=/opt/homebrew/bin:$PATH /opt/homebrew/bin/bash /Users/so/Hacking/knightwatch-reviewer2/lib/tests/prompt-contracts-smoke.sh 2>&1 | tail -5
```

Expected: `PASS` on the last line.

- [ ] **Step 4: Commit**

```bash
git add lib/tests/prompt-contracts-smoke.sh
git commit -m "test: drop splitter + dispatch_agent assertions from prompt-contracts-smoke

These assertions check for tokens that no longer exist post-migration:
- splitter routing rules in prompts/critic.md
- specialists/critic.md sink in prompts/aggregator.md
- Generated probes section
- dispatch_agent format from orchestrate.sh

PATH/shebang/ReadWritePaths fences + per-specialist complexity-cost
token + per-angle critic content checks all stay.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: install.sh + justfile updates

**Files:**
- Modify: `install.sh`
- Modify: `justfile`

- [ ] **Step 1: Add Python precondition to install.sh**

Find the install.sh preflight checks (near top, before any `cp`/`ln` calls) and add:

```bash
# pipeline.py runs under python3; fail loud here if unavailable rather than
# at the first review tick.
if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 not on PATH — required by lib/pipeline.py (apt install python3 or pyenv setup)"
fi
PY_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
echo "  python3: $PY_VERSION"
```

- [ ] **Step 2: Add unittest discovery to justfile**

Find the `test:` target in `justfile` and insert (after the bash-major-version preflight, before the first `bash lib/tests/<name>-smoke.sh` line):

```just
    echo ""
    echo "=== python pipeline tests ==="
    python3 -m unittest discover -s lib/tests -p 'test_*.py' -v
```

- [ ] **Step 3: Run the full test suite to verify**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
PATH=/opt/homebrew/bin:$PATH /opt/homebrew/bin/bash -c 'just test' 2>&1 | tail -30
```

Expected: smokes all `ok:`, pytest-style line `Ran N tests in 0.00Ns OK`, final `all checks passed`. (Pre-existing macOS-only flake failures may remain — `repos-conf-smoke.sh` per prior baseline.)

- [ ] **Step 4: Commit**

```bash
git add install.sh justfile
git commit -m "build: install.sh checks python3, justfile runs unittest

install.sh fails loud if python3 isn't on PATH (required by pipeline.py).
justfile's `just test` target runs `python3 -m unittest discover` over
lib/tests/test_*.py before the shell smokes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: End-to-end sanity + push

**Files:** none (verification + push)

- [ ] **Step 1: Run all tests one more time**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
PATH=/opt/homebrew/bin:$PATH /opt/homebrew/bin/bash -c 'just test' 2>&1 | tail -10
```

Expected: green (modulo pre-existing macOS flakes).

- [ ] **Step 2: Verify the final diff against main**

```bash
git diff --shortstat main..HEAD -- lib/ prompts/ install.sh justfile
git log --oneline main..HEAD | wc -l
```

Expected: net negative LOC, ~12 commits added by this plan.

- [ ] **Step 3: Push**

```bash
git push
```

- [ ] **Step 4: Trigger a fresh bot review on the PR**

```bash
gh pr comment 47 --body "/srosro-review"
```

(Whole-PR review since the migration touches multiple subsystems and the prior bot reviews' mental model wouldn't apply.)
