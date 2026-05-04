"""Tests for lib/pipeline.py — mocked codex subprocess."""
import os
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

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
        self.assertEqual(out, "Critique probes for security.\n")  # ANGLE substituted

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


if __name__ == "__main__":
    unittest.main()
