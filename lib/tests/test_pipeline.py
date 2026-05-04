"""Tests for lib/pipeline.py — mocked codex subprocess."""
import os
import stat
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

# Add lib/ to path so we can import pipeline
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import pipeline  # noqa: E402


def _write_minimal_prompts(prompts_dir: Path) -> None:
    """Write the full minimal prompt tree run_pipeline + the CLI smoke need.

    Shared between TestRunPipeline and TestPipelineCLI so adding a required
    prompt file or marker only needs one update site. TestRunAngle uses a
    smaller tree (only common-header / one specialist / critic) because it
    doesn't exercise the full pipeline — kept inline there.
    """
    (prompts_dir / "common-header.md").write_text("H {{SPECIALIST_NAME}}\n")
    for angle in pipeline.ANGLES:
        (prompts_dir / f"{angle}.md").write_text(f"BODY {angle}\n")
    (prompts_dir / "intent.md").write_text("intent prompt\n")
    (prompts_dir / "dead-code-search.md").write_text("dc prompt\n")
    (prompts_dir / "momentum.md").write_text("momentum prompt\n")
    (prompts_dir / "critic.md").write_text("critic prompt\n")
    (prompts_dir / "voice.md").write_text("Voice: {{OPERATOR_NAME}}\n")
    (prompts_dir / "aggregator.md").write_text(
        "# Agg\n<!-- INSERT_VOICE_HERE -->\nAgg body\n"
    )


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
    def test_critic_per_angle_with_h2_passes(self, mock_run):
        """Per-angle critics must emit '## Critic counter-arguments' H2."""
        mock_run.side_effect = self._stub_codex(
            0,
            "## Critic counter-arguments\n\n### Probe 1\n"
            "- **Answer:** yes\n- **Evidence:** cited\n",
        )
        rc = pipeline.run_codex("critic-security", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.run")
    def test_critic_no_probes_sentinel_passes(self, mock_run):
        """Per-angle critic emits 'No probes.' when its specialist had none."""
        mock_run.side_effect = self._stub_codex(0, "No probes.\n")
        rc = pipeline.run_codex("critic-shape", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.run")
    def test_critic_malformed_output_returns_4(self, mock_run):
        """Answer-only output (no '## Critic counter-arguments' H2 and no
        'No probes.' sentinel) is malformed — return 4 so it doesn't reach
        aggregation as if it were a valid resolution."""
        mock_run.side_effect = self._stub_codex(
            0, "- **Answer:** yes\n- **Evidence:** cited\n"
        )
        rc = pipeline.run_codex("critic-security", str(self.repo_dir), "PROMPT", str(self.agent_dir))
        self.assertEqual(rc, 4)


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
        # Critic owns the '## Critic counter-arguments' H2 — pipeline.py only
        # adds the '---' separator, so the critic output must include the H2.
        mock_run.side_effect = self._make_codex_stub({
            "security": (0, "### Probe 1\nspecialist body\n"),
            "critic-security": (0,
                "## Critic counter-arguments\n\n### Probe 1\n"
                "- **Answer:** yes\n- **Evidence:** cited\n"),
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
        # Exactly one '## Critic counter-arguments' H2 — not doubled
        self.assertEqual(layered.count("## Critic counter-arguments"), 1)
        self.assertIn("- **Answer:** yes", layered)

    @patch("pipeline.subprocess.run")
    def test_scratch_staged_before_critic_runs(self, mock_run):
        """The per-angle critic prompt cites .codex-scratch/specialists/<angle>.md
        as input. Verify the file exists with raw spec output at the moment the
        critic is invoked (not just after the layered overwrite)."""
        scratch_path = self.repo_dir / ".codex-scratch" / "specialists" / "security.md"
        captured: dict[str, str] = {}

        def side_effect(argv, **kwargs):
            out_path = Path(argv[argv.index("-o") + 1])
            agent_name = out_path.parent.name
            if agent_name == "critic-security":
                # Snapshot scratch contents at the moment the critic runs.
                captured["scratch_at_critic"] = scratch_path.read_text()
                out_path.write_text(
                    "## Critic counter-arguments\n\n"
                    "### Probe 1\n- **Answer:** yes\n- **Evidence:** cited\n"
                )
                return FakeCompletedProcess(0)
            out_path.write_text("### Probe 1\nspecialist body\n")
            return FakeCompletedProcess(0)

        mock_run.side_effect = side_effect
        rc = pipeline.run_angle(
            angle="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        # At the moment the critic ran, scratch held the specialist output —
        # not yet layered (no critic counter-arguments H2 yet).
        self.assertIn("specialist body", captured["scratch_at_critic"])
        self.assertNotIn("## Critic counter-arguments", captured["scratch_at_critic"])

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
        # Scratch file should NOT exist (specialist failed, never staged)
        self.assertFalse(
            (self.repo_dir / ".codex-scratch" / "specialists" / "security.md").exists()
        )

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
        # Scratch file exists (staged before critic) but is un-layered
        # (no '## Critic counter-arguments'). run_pipeline aborts on this rc
        # and rm -rf's REPO_DIR before the aggregator could read the orphan.
        scratch_path = (
            self.repo_dir / ".codex-scratch" / "specialists" / "security.md"
        )
        self.assertTrue(scratch_path.exists())
        self.assertNotIn("## Critic counter-arguments", scratch_path.read_text())


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

        self.prompts = Path(self.tmp.name) / "prompts"
        self.prompts.mkdir()
        _write_minimal_prompts(self.prompts)

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
            # Per-angle critics must emit '## Critic counter-arguments' H2
            # (or 'No probes.' sentinel) per the contract enforced by
            # run_codex's _CRITIC_BLOCK_RE gate. Default tests that don't
            # override the critic output need a contract-valid stub.
            if (
                agent_name.startswith("critic-")
                and ec == 0
                and out == default[1]
            ):
                out = (
                    "## Critic counter-arguments\n\n"
                    "### Probe 1\n- **Answer:** yes\n- **Evidence:** stub\n"
                )
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


class TestPipelineCLI(unittest.TestCase):
    """End-to-end smoke against the real `python3 lib/pipeline.py REPO_DIR
    RUN_DIR` process boundary. The TestRunPipeline class above mocks
    subprocess.run inside the same process; this class exercises argv
    parsing, env-var loading, PATH resolution, and sys.exit() — none of
    which the in-process tests cover.
    """

    def setUp(self):
        self.tmp = TemporaryDirectory()
        root = Path(self.tmp.name)
        self.repo_dir = root / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)
        (self.repo_dir / ".codex-scratch" / "specialists").mkdir(parents=True)
        self.run_dir = root / "run"
        (self.run_dir / "agents").mkdir(parents=True)
        (self.run_dir / "inputs").mkdir(parents=True)

        self.prompts = root / "prompts"
        self.prompts.mkdir()
        _write_minimal_prompts(self.prompts)

        # Fake codex on PATH. Mirrors the real argv shape:
        #   codex exec -C <repo> --dangerously-bypass-approvals-and-sandbox \
        #     -c model=gpt-5.5 -c model_reasoning_effort=high -o <out> <prompt>
        # Picks output by agent dir name (the parent of the -o target).
        self.fake_bin = root / "fakebin"
        self.fake_bin.mkdir()
        fake_codex = self.fake_bin / "codex"
        fake_codex.write_text(
            "#!/usr/bin/env python3\n"
            "import sys\n"
            "from pathlib import Path\n"
            "argv = sys.argv\n"
            "out_idx = argv.index('-o')\n"
            "out_path = Path(argv[out_idx + 1])\n"
            "agent = out_path.parent.name\n"
            "if agent == 'intent':\n"
            "    out_path.write_text('Inferred intent: stub.\\n')\n"
            "elif agent == 'aggregator':\n"
            "    out_path.write_text('# Review\\nVERDICT: APPROVE\\n')\n"
            "elif agent.startswith('critic-'):\n"
            "    out_path.write_text('## Critic counter-arguments\\n\\n"
            "### Probe 1\\n- **Answer:** yes\\n- **Evidence:** stub\\n')\n"
            "elif agent in ('dead-code-search', 'momentum'):\n"
            "    out_path.write_text(agent + ' stub\\n')\n"
            "else:\n"
            "    out_path.write_text('### Probe 1\\nstub\\n')\n"
            "sys.exit(0)\n"
        )
        fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    def tearDown(self):
        self.tmp.cleanup()

    def test_real_subprocess_first_review(self):
        """Run pipeline.py as a subprocess with a fake codex on PATH.
        Asserts argv, env-var loading, and aggregator output landing
        at the deterministic path."""
        pipeline_path = Path(pipeline.__file__).resolve()
        env = {
            "PATH": f"{self.fake_bin}:{os.environ.get('PATH', '')}",
            "PR_ID": "owner/repo#42",
            "PR_TITLE": "Add X",
            "PR_URL": "https://example/pull/42",
            "PR_AUTHOR": "alice",
            "PROMPTS_DIR": str(self.prompts),
            "LOG_FILE": str(self.run_dir / "run.log"),
            "OPERATOR_NAME": "Sam",
        }
        proc = subprocess.run(
            [sys.executable, str(pipeline_path), str(self.repo_dir), str(self.run_dir)],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(
            proc.returncode, 0,
            f"pipeline exit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        agg_out = self.run_dir / "agents" / "aggregator" / "output.md"
        self.assertTrue(agg_out.exists(), "aggregator output.md missing")
        self.assertIn("VERDICT: APPROVE", agg_out.read_text())
        for angle in pipeline.ANGLES:
            self.assertTrue(
                (self.run_dir / "agents" / angle / "output.md").exists(),
                f"missing specialist output for {angle}",
            )
            self.assertTrue(
                (self.run_dir / "agents" / f"critic-{angle}" / "output.md").exists(),
                f"missing critic output for {angle}",
            )

    def test_missing_required_env_var_fails_loud(self):
        """PR_ID etc. are required — missing should exit non-zero, not run."""
        pipeline_path = Path(pipeline.__file__).resolve()
        env = {
            "PATH": f"{self.fake_bin}:{os.environ.get('PATH', '')}",
            # PR_ID intentionally omitted
            "PR_TITLE": "x",
            "PR_URL": "x",
            "PR_AUTHOR": "x",
            "PROMPTS_DIR": str(self.prompts),
        }
        proc = subprocess.run(
            [sys.executable, str(pipeline_path), str(self.repo_dir), str(self.run_dir)],
            env=env, capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(proc.returncode, 0)

    def test_usage_error_when_argv_missing(self):
        """No REPO_DIR / RUN_DIR args → exit 2 + usage to stderr."""
        pipeline_path = Path(pipeline.__file__).resolve()
        proc = subprocess.run(
            [sys.executable, str(pipeline_path)],
            env={"PATH": os.environ.get("PATH", "")},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("usage:", proc.stderr)


class TestRealPromptsCompose(unittest.TestCase):
    """Compose-time fence against the production prompts/ tree.

    The other tests use synthetic prompt fixtures, which means the
    INSERT_VOICE_HERE marker, common-header references, and per-angle
    body files in the real `prompts/` directory aren't exercised by
    unit tests. One real-prompts compose test catches drift like a
    renamed marker, a deleted prompt file, or a regression in
    voice.md's leading-comment shape.
    """

    def setUp(self):
        self.real_prompts = Path(pipeline.__file__).resolve().parent.parent / "prompts"

    def test_aggregator_stitch_against_real_prompts(self):
        out = pipeline.build_prompt(
            kind="aggregator", agent="aggregator",
            prompts_dir=str(self.real_prompts),
            pr_id="owner/repo#42", pr_title="Add X",
            pr_url="https://example/pull/42", pr_author="alice",
        )
        self.assertNotIn("INSERT_VOICE_HERE", out, "voice stitch failed")
        self.assertIn("owner/repo#42", out, "PR_ID substitution failed")

    def test_specialist_compose_against_real_prompts(self):
        """common-header.md + each angle's body file must compose without error."""
        for angle in pipeline.ANGLES:
            out = pipeline.build_prompt(
                kind="specialist", agent=angle,
                prompts_dir=str(self.real_prompts),
                pr_id="owner/repo#42", pr_title="Add X",
                pr_url="https://example/pull/42", pr_author="alice",
            )
            self.assertNotIn("{{PR_ID}}", out, f"{angle}: PR_ID placeholder leaked")
            self.assertNotIn("{{SPECIALIST_NAME}}", out, f"{angle}: specialist name leaked")
            self.assertIn(angle, out, f"{angle}: specialist name missing")


if __name__ == "__main__":
    unittest.main()
