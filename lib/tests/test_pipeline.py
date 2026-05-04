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
