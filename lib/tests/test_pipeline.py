"""Tests for lib/pipeline.py — mocked codex subprocess."""
import os
import signal
import stat
import subprocess
import sys
import threading
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
    prompt file or marker only needs one update site. TestRunSpecialist uses
    a smaller tree (only common-header / one specialist / critic) because it
    doesn't exercise the full pipeline — kept inline there.
    """
    (prompts_dir / "specialists").mkdir(parents=True, exist_ok=True)
    (prompts_dir / "standalone").mkdir(parents=True, exist_ok=True)
    (prompts_dir / "common-header.md").write_text("H {{SPECIALIST_NAME}}\n")
    for specialist in pipeline.SPECIALISTS:
        (prompts_dir / "specialists" / f"{specialist}.md").write_text(f"BODY {specialist}\n")
    (prompts_dir / "standalone" / "intent.md").write_text("intent prompt\n")
    (prompts_dir / "standalone" / "dead-code-search.md").write_text("dc prompt\n")
    (prompts_dir / "standalone" / "momentum.md").write_text("momentum prompt\n")
    (prompts_dir / "critic.md").write_text("critic prompt\n")
    (prompts_dir / "voice.md").write_text("Voice: {{OPERATOR_NAME}}\n")
    (prompts_dir / "aggregator.md").write_text(
        "# Agg\n<!-- INSERT_VOICE_HERE -->\nAgg body\n"
    )


class FakePopen:
    """Stand-in for subprocess.Popen. Mirrors only the surface run_codex
    actually uses: `.pid` (for os.killpg) and `.wait(timeout=)`. Set
    `raise_timeout=True` to make the first wait() raise TimeoutExpired,
    exercising run_codex's killpg branch; subsequent waits (the reaper
    call after killpg) return `returncode` cleanly."""
    _pid_counter = 0

    def __init__(self, returncode, raise_timeout=False):
        FakePopen._pid_counter += 1
        self.pid = 100000 + FakePopen._pid_counter
        self._returncode = returncode
        self._raise_timeout = raise_timeout
        self._wait_calls = 0
        self.last_wait_timeout = None

    def wait(self, timeout=None):
        self._wait_calls += 1
        self.last_wait_timeout = timeout
        if self._raise_timeout and self._wait_calls == 1:
            raise subprocess.TimeoutExpired(cmd="codex", timeout=timeout or 1)
        return self._returncode


def _make_codex_stub(plan=None, default=(0, "### Probe 1\nstub\n"),
                     before_write=None):
    """Module-level fake-codex side_effect for `subprocess.Popen`. Owns the
    full agent contract surface so callers only specify what they care
    about. `plan` maps agent name → (exit_code, output_text); explicit
    entries are used verbatim. Agents NOT in plan fall through to
    `default` (with intent + per-angle critic auto-substituted to
    contract-valid output, so orchestrator-level tests don't need to
    spell out every agent). `before_write(name, out_path)` fires pre-write
    — used by ordering tests."""
    plan = plan or {}
    def side_effect(argv, **kwargs):
        out_path = Path(argv[argv.index("-o") + 1])
        agent_name = out_path.parent.name
        if before_write is not None:
            before_write(agent_name, out_path)
        if agent_name in plan:
            entry = plan[agent_name]
            # "TIMEOUT" sentinel: simulate run_codex's 45m hard cap firing.
            # Codex actually started (Popen returned) but never finished —
            # output.md was not written. wait(timeout=) will raise
            # TimeoutExpired, exercising run_codex's killpg branch.
            if entry == "TIMEOUT":
                return FakePopen(returncode=-signal.SIGKILL, raise_timeout=True)
            ec, out = entry
        else:
            ec, out = default
            if agent_name == "intent":
                out = "Inferred intent: stub.\n"
            elif agent_name.startswith("critic-"):
                out = (
                    "## Critic counter-arguments\n\n"
                    "### Probe 1\n- **Answer:** yes\n- **Evidence:** stub\n"
                )
        out_path.write_text(out)
        return FakePopen(returncode=ec)
    return side_effect


class TestRunCodex(unittest.TestCase):
    """run_codex wraps `codex exec`; matches lib/run-specialist.sh contract."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.repo_dir = Path(self.tmp.name) / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def _agent_dir(self, name):
        """Mirror production layout: agents/<name>/. Required so the
        module-level _make_codex_stub's plan lookup (keyed on dir name)
        resolves to this test's agent."""
        return Path(self.tmp.name) / "agents" / name

    @patch("pipeline.subprocess.Popen")
    def test_success_path_writes_artifacts(self, mock_popen):
        agent_dir = self._agent_dir("intent")
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (0, "### Probe 1\nstub\n")})
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(agent_dir))
        self.assertEqual(rc, 0)
        self.assertEqual((agent_dir / "prompt.txt").read_text(), "PROMPT")
        self.assertTrue((agent_dir / "output.md").stat().st_size > 0)
        self.assertIn("agent=intent starting", (agent_dir / "log.txt").read_text())
        self.assertIn("agent=intent exit=0", (agent_dir / "log.txt").read_text())

    @patch("pipeline.subprocess.Popen")
    def test_codex_argv_pins_model(self, mock_popen):
        """The model=gpt-5.5 pin must reach codex (regression fence)."""
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (0, "### Probe 1\nstub\n")})
        pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent")))
        argv = mock_popen.call_args[0][0]
        self.assertIn("model=gpt-5.5", argv)
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", argv)

    @patch("pipeline.subprocess.Popen")
    def test_codex_nonzero_exit_propagates(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (7, "")})
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent")))
        self.assertEqual(rc, 7)

    @patch("pipeline.subprocess.Popen")
    def test_codex_subprocess_timeout_returns_sentinel(self, mock_popen):
        """45m subprocess timeout → SPECIALIST_TIMEOUT_RC sentinel + log line.
        Sentinel sits above the Unix exit range so codex's own exit(N) can
        never silently masquerade as a timeout (round-2 probe 3)."""
        mock_popen.side_effect = _make_codex_stub(plan={"intent": "TIMEOUT"})
        rc = pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        self.assertEqual(rc, pipeline.SPECIALIST_TIMEOUT_RC)
        # > 255 is the contract — any value codex can return through normal
        # process.exit(N) truncation must NOT collide with our sentinel.
        self.assertGreater(pipeline.SPECIALIST_TIMEOUT_RC, 255)
        log_text = (self._agent_dir("intent") / "log.txt").read_text()
        self.assertIn("timed out", log_text)
        self.assertIn(f"agent=intent exit={pipeline.SPECIALIST_TIMEOUT_RC}", log_text)

    @patch("pipeline.subprocess.Popen")
    def test_codex_subprocess_new_session_and_wait_timeout(self, mock_popen):
        """Two fences in one: Popen must set start_new_session=True (so codex
        is its own pgrp leader and killpg reaches all descendants), and
        proc.wait must be called with timeout=SPECIALIST_TIMEOUT_SEC (the
        budget the killpg branch enforces)."""
        captured = []
        plan_stub = _make_codex_stub(plan={"intent": (0, "### Probe 1\nstub\n")})
        def factory(*args, **kwargs):
            fp = plan_stub(*args, **kwargs)
            captured.append((args, kwargs, fp))
            return fp
        mock_popen.side_effect = factory
        pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        _, popen_kwargs, fake_proc = captured[0]
        self.assertTrue(popen_kwargs.get("start_new_session"),
                        "codex must run in its own session/pgrp so killpg on "
                        "timeout reaps node + tool descendants")
        self.assertEqual(fake_proc.last_wait_timeout, pipeline.SPECIALIST_TIMEOUT_SEC)

    @patch("pipeline.os.killpg")
    @patch("pipeline.subprocess.Popen")
    def test_codex_timeout_kills_whole_process_group(self, mock_popen, mock_killpg):
        """Regression fence for the PID-1 orphan leak: on TimeoutExpired,
        run_codex must SIGKILL the codex pgrp (proc.pid == pgid because of
        start_new_session=True). Without killpg, codex's reparented node/tool
        children survive with reviewer credentials and disabled sandboxing."""
        captured = []
        plan_stub = _make_codex_stub(plan={"intent": "TIMEOUT"})
        def factory(*args, **kwargs):
            fp = plan_stub(*args, **kwargs)
            captured.append(fp)
            return fp
        mock_popen.side_effect = factory
        rc = pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        self.assertEqual(rc, pipeline.SPECIALIST_TIMEOUT_RC)
        pgid_arg, sig_arg = mock_killpg.call_args.args
        self.assertEqual(sig_arg, signal.SIGKILL)
        # pgid passed to killpg must be the Popen pid (start_new_session=True
        # makes them equal).
        self.assertEqual(pgid_arg, captured[0].pid)

    @patch("pipeline.os.killpg")
    @patch("pipeline.subprocess.Popen")
    def test_codex_timeout_swallows_processlookuperror(self, mock_popen, mock_killpg):
        """If the codex leader was already reaped between TimeoutExpired and
        the killpg call (kernel race), ProcessLookupError must not propagate
        — run_codex still returns the sentinel cleanly."""
        mock_popen.side_effect = _make_codex_stub(plan={"intent": "TIMEOUT"})
        mock_killpg.side_effect = ProcessLookupError()
        rc = pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        self.assertEqual(rc, pipeline.SPECIALIST_TIMEOUT_RC)

    @patch("pipeline.subprocess.Popen")
    def test_run_codex_untracks_pgrp_on_success(self, mock_popen):
        """run_codex must untrack the pgrp in finally — otherwise the signal-
        handler registry leaks entries across 8 specialists × N reviews and
        sends SIGKILL to recycled PIDs."""
        pipeline._active_codex_pgrps.clear()
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (0, "### Probe 1\nstub\n")})
        pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        self.assertEqual(pipeline._active_codex_pgrps, set())

    @patch("pipeline.os.killpg")
    @patch("pipeline.subprocess.Popen")
    def test_run_codex_untracks_pgrp_on_timeout(self, mock_popen, mock_killpg):
        """Same untrack-in-finally guarantee on the timeout branch."""
        pipeline._active_codex_pgrps.clear()
        mock_popen.side_effect = _make_codex_stub(plan={"intent": "TIMEOUT"})
        pipeline.run_codex(
            "intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent"))
        )
        self.assertEqual(pipeline._active_codex_pgrps, set())

    @patch("pipeline.subprocess.Popen")
    def test_codex_zero_exit_empty_output_returns_3(self, mock_popen):
        """Codex says success but wrote nothing — fail loud as exit 3."""
        agent_dir = self._agent_dir("intent")
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (0, "")})
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(agent_dir))
        self.assertEqual(rc, 3)
        self.assertIn("produced empty output", (agent_dir / "log.txt").read_text())

    @patch("pipeline.subprocess.Popen")
    def test_specialist_must_emit_probe_or_no_probes_sentinel(self, mock_popen):
        """Probe-emitting roles must include `### Probe ` or `No probes.` — exit 4 otherwise."""
        mock_popen.side_effect = _make_codex_stub(
            plan={"security": (0, "garbage that doesn't look like a probe\n")},
        )
        rc = pipeline.run_codex("security", str(self.repo_dir), "PROMPT", str(self._agent_dir("security")))
        self.assertEqual(rc, 4)

    @patch("pipeline.subprocess.Popen")
    def test_specialist_no_probes_sentinel_passes(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub(plan={"security": (0, "No probes.\n")})
        rc = pipeline.run_codex("security", str(self.repo_dir), "PROMPT", str(self._agent_dir("security")))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.Popen")
    def test_intent_exempt_from_probe_gate(self, mock_popen):
        """Non-probe-emitting roles (intent, critic, aggregator, etc.) skip the gate."""
        mock_popen.side_effect = _make_codex_stub(plan={"intent": (0, "Inferred intent: doing X.\n")})
        rc = pipeline.run_codex("intent", str(self.repo_dir), "PROMPT", str(self._agent_dir("intent")))
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.Popen")
    def test_critic_per_angle_exempt_from_run_codex_gate(self, mock_popen):
        """Per-angle critic correctness is validated at the run_specialist
        boundary (where both specialist + critic outputs are available), not
        here. run_codex passes any critic output through; the semantic checks
        in TestValidateCriticOutput cover the contract."""
        mock_popen.side_effect = _make_codex_stub(
            plan={"critic-security": (0, "anything goes through run_codex\n")},
        )
        rc = pipeline.run_codex("critic-security", str(self.repo_dir), "PROMPT", str(self._agent_dir("critic-security")))
        self.assertEqual(rc, 0)


class TestValidateCriticOutput(unittest.TestCase):
    """The semantic contract: critic must address every specialist probe by
    ID with Answer + Evidence, or emit bare 'No probes.' when the specialist
    had zero probes. Eliminates the bug class where the critic emits a
    valid-looking H2 but silently skips probes."""

    def test_zero_specialist_probes_accepts_no_probes_sentinel(self):
        spec = "Surveyed code paths.\n\nNo probes.\n\n## Surveyed\n- looked at X\n"
        crit = "No probes.\n"
        self.assertIsNone(pipeline._validate_critic_output(spec, crit))

    def test_zero_specialist_probes_rejects_h2_output(self):
        spec = "No probes.\n\n## Surveyed\n- nothing\n"
        crit = "## Critic counter-arguments\n\n### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n"
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("0 probes", err)

    def test_specialist_probes_with_full_resolutions_passes(self):
        spec = (
            "### Probe 1\n- **From:** security\n- **Q:** Is X broken?\n\n"
            "### Probe 2\n- **From:** security\n- **Q:** Is Y broken?\n"
        )
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** cited\n\n"
            "### Probe 2\n- **Answer:** no\n- **Evidence:** zero call-sites\n"
        )
        self.assertIsNone(pipeline._validate_critic_output(spec, crit))

    def test_specialist_probes_but_critic_missing_h2_returns_error(self):
        spec = "### Probe 1\n- **From:** security\n"
        crit = "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n"
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("Critic counter-arguments", err)

    def test_specialist_probes_but_critic_emits_no_probes_returns_error(self):
        spec = "### Probe 1\n- **From:** security\n"
        crit = "No probes.\n"
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("Critic counter-arguments", err)

    def test_critic_skips_a_probe_returns_error(self):
        spec = (
            "### Probe 1\n- **From:** security\n\n"
            "### Probe 2\n- **From:** security\n"
        )
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n"
            # Probe 2 missing
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("missing resolution", err)
        self.assertIn("'2'", err)

    def test_critic_missing_answer_field_returns_error(self):
        spec = "### Probe 1\n- **From:** security\n"
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Evidence:** cited but no answer\n"
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("Answer", err)

    def test_critic_missing_evidence_field_returns_error(self):
        spec = "### Probe 1\n- **From:** security\n"
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n"
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("Evidence", err)

    def test_critic_with_extra_probe_block_returns_error(self):
        """Critic must NOT emit probe ids the specialist didn't —
        cross-angle/generated probes are the aggregator's job. Bijection
        contract: spec_probe_ids must equal crit_probe_ids exactly."""
        spec = "### Probe 1\n- **From:** security\n"
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n\n"
            "### Probe 2\n- **Answer:** no\n- **Evidence:** y\n"
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("not in specialist", err)
        self.assertIn("'2'", err)

    def test_specialist_with_duplicate_probe_ids_returns_error(self):
        """Specialist emitting two `### Probe 1` blocks would let set(...)
        collapse them so a critic resolving only one passes the equality
        check while leaving an ambiguous unresolved duplicate. Reject
        duplicate IDs at the validator boundary instead."""
        spec = (
            "### Probe 1\n- **From:** security\n"
            "### Probe 1\n- **From:** security\n"  # duplicate ID
        )
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n"
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("specialist emitted duplicate", err)
        self.assertIn("'1'", err)

    def test_critic_with_duplicate_probe_ids_returns_error(self):
        """Symmetric check on the critic side — a critic emitting two
        `### Probe 1` blocks (e.g. from an LLM hallucinating a re-resolution)
        is also rejected."""
        spec = "### Probe 1\n- **From:** security\n"
        crit = (
            "## Critic counter-arguments\n\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n\n"
            "### Probe 1\n- **Answer:** no\n- **Evidence:** y\n"  # duplicate
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("critic emitted duplicate", err)
        self.assertIn("'1'", err)

    def test_critic_h2_must_be_anchored_to_start_of_line(self):
        """A mid-prose quote of '## Critic counter-arguments' must not pass —
        a paragraph mentioning the section name doesn't satisfy the layered
        contract."""
        spec = "### Probe 1\n- **From:** security\n"
        crit = (
            "Some prose where I mention '## Critic counter-arguments' inline.\n"
            "### Probe 1\n- **Answer:** yes\n- **Evidence:** x\n"
        )
        err = pipeline._validate_critic_output(spec, crit)
        self.assertIsNotNone(err)
        self.assertIn("anchored", err)


class TestBuildPrompt(unittest.TestCase):
    """build_prompt handles placeholder substitution + common-header + voice.md stitch."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.prompts = Path(self.tmp.name) / "prompts"
        (self.prompts / "specialists").mkdir(parents=True)
        (self.prompts / "standalone").mkdir(parents=True)
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
        (self.prompts / "specialists" / "security.md").write_text(
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
        (self.prompts / "standalone" / "intent.md").write_text(
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
        by run_specialist, not via build_prompt.
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

    def test_voice_md_with_backslash_sequences_preserved_verbatim(self):
        """Regression fence: voice.md is operator-editable markdown that may
        legitimately contain backslash sequences like `\\1`, `\\g<name>`, or
        bare `\\` (escaped chars in inline code, regex examples in operator
        docs). The stitch must preserve them verbatim. Earlier `re.sub` with
        a string replacement would have substituted `\\1` as a backref into
        an empty group → corruption or re.error mid-review."""
        (self.prompts / "voice.md").write_text(
            "Voice: literal backref \\1 and \\g<x> and a stray \\\\ here.\n"
        )
        out = pipeline.build_prompt(
            kind="aggregator", agent="aggregator",
            prompts_dir=str(self.prompts),
            pr_id="x", pr_title="x", pr_url="x", pr_author="x",
        )
        self.assertIn("literal backref \\1 and \\g<x> and a stray \\\\ here.", out)

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


class TestCodexPgrpRegistry(unittest.TestCase):
    """Codex pgrp tracking + the SIGTERM cleanup path. Bash wraps python3
    with `timeout 55m` (and the worker outer with `timeout 90m bash`); both
    SIGTERM python3's pgrp, but codex children use start_new_session=True
    and are in their own sessions — without this registry + handler, the
    upstream timeout leaves them alive as PID-1 orphans with reviewer
    credentials. Round-2 probe 1 fence."""

    def setUp(self):
        # Each test starts with an empty registry; otherwise leaks from a
        # prior class polute the assertion.
        pipeline._active_codex_pgrps.clear()

    def test_track_and_untrack_round_trip(self):
        pipeline._track_codex_pgrp(11111)
        pipeline._track_codex_pgrp(22222)
        self.assertEqual(pipeline._active_codex_pgrps, {11111, 22222})
        pipeline._untrack_codex_pgrp(11111)
        self.assertEqual(pipeline._active_codex_pgrps, {22222})

    def test_untrack_unknown_pgrp_is_noop(self):
        """discard() semantics — untracking an unregistered pid must not
        raise (race: timeout handler killpg's the registry, then the
        finally block of run_codex untracks an already-removed pid)."""
        pipeline._untrack_codex_pgrp(99999)  # should not raise

    @patch("pipeline.os.killpg")
    def test_killpg_all_codex_kills_every_tracked_pgrp(self, mock_killpg):
        pipeline._track_codex_pgrp(11111)
        pipeline._track_codex_pgrp(22222)
        killed = pipeline._killpg_all_codex()
        self.assertEqual(killed, 2)
        # Both pgrps received SIGKILL.
        pgrps_seen = {c.args[0] for c in mock_killpg.call_args_list}
        sigs_seen = {c.args[1] for c in mock_killpg.call_args_list}
        self.assertEqual(pgrps_seen, {11111, 22222})
        self.assertEqual(sigs_seen, {signal.SIGKILL})
        # Registry is cleared so a follow-up signal doesn't re-killpg
        # recycled PIDs.
        self.assertEqual(pipeline._active_codex_pgrps, set())

    @patch("pipeline.os.killpg", side_effect=ProcessLookupError)
    def test_killpg_all_codex_swallows_lookup_error(self, mock_killpg):
        """If a pgrp was already reaped (race), ProcessLookupError must
        not propagate out of the SIGTERM handler — otherwise Python crashes
        instead of exiting cleanly."""
        pipeline._track_codex_pgrp(11111)
        killed = pipeline._killpg_all_codex()
        self.assertEqual(killed, 0)
        self.assertEqual(pipeline._active_codex_pgrps, set())

    @patch("pipeline.signal.signal")
    def test_install_signal_handlers_registers_sigterm_and_sigint(self, mock_signal):
        pipeline._install_codex_cleanup_signal_handlers()
        signums = {c.args[0] for c in mock_signal.call_args_list}
        # SIGTERM (bash timeout / worker timeout) + SIGINT (operator Ctrl-C).
        self.assertIn(signal.SIGTERM, signums)
        self.assertIn(signal.SIGINT, signums)


class TestRunSpecialist(unittest.TestCase):
    """run_specialist dispatches specialist→critic, composes layered file."""

    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.repo_dir = Path(self.tmp.name) / "repo"
        (self.repo_dir / ".git").mkdir(parents=True)
        (self.repo_dir / ".codex-scratch" / "specialists").mkdir(parents=True)
        self.run_dir = Path(self.tmp.name) / "run"
        (self.run_dir / "agents").mkdir(parents=True)

        # Minimal prompts dir so build_prompt can resolve files
        self.prompts = Path(self.tmp.name) / "prompts"
        (self.prompts / "specialists").mkdir(parents=True)
        (self.prompts / "common-header.md").write_text("HEADER {{SPECIALIST_NAME}}\n")
        (self.prompts / "specialists" / "security.md").write_text("BODY for {{SPECIALIST_NAME}}\n")
        (self.prompts / "critic.md").write_text("Critique {{ANGLE}}.\n")

    def tearDown(self):
        self.tmp.cleanup()

    @patch("pipeline.subprocess.Popen")
    def test_specialist_then_critic_writes_layered_file(self, mock_popen):
        # Critic owns the '## Critic counter-arguments' H2 — pipeline.py only
        # adds the '---' separator, so the critic output must include the H2.
        mock_popen.side_effect = _make_codex_stub({
            "security": (0, "### Probe 1\nspecialist body\n"),
            "critic-security": (0,
                "## Critic counter-arguments\n\n### Probe 1\n"
                "- **Answer:** yes\n- **Evidence:** cited\n"),
        })
        rc = pipeline.run_specialist(
            specialist="security",
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

    @patch("pipeline.subprocess.Popen")
    def test_scratch_staged_before_critic_runs(self, mock_popen):
        """The per-angle critic prompt cites .codex-scratch/specialists/<angle>.md
        as input. Verify the file exists with raw spec output at the moment the
        critic is invoked (not just after the layered overwrite)."""
        scratch_path = self.repo_dir / ".codex-scratch" / "specialists" / "security.md"
        captured: dict[str, str] = {}
        def snapshot_at_critic(name, _out_path):
            if name == "critic-security":
                captured["scratch_at_critic"] = scratch_path.read_text()
        mock_popen.side_effect = _make_codex_stub(
            plan={
                "security": (0, "### Probe 1\nspecialist body\n"),
                "critic-security": (0,
                    "## Critic counter-arguments\n\n"
                    "### Probe 1\n- **Answer:** yes\n- **Evidence:** cited\n"),
            },
            before_write=snapshot_at_critic,
        )
        rc = pipeline.run_specialist(
            specialist="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        # At the moment the critic ran, scratch held the specialist output —
        # not yet layered (no critic counter-arguments H2 yet).
        self.assertIn("specialist body", captured["scratch_at_critic"])
        self.assertNotIn("## Critic counter-arguments", captured["scratch_at_critic"])

    @patch("pipeline.subprocess.Popen")
    def test_specialist_failure_skips_critic(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
            "security": (7, ""),
        })
        rc = pipeline.run_specialist(
            specialist="security",
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

    @patch("pipeline.subprocess.Popen")
    def test_critic_contract_violation_returns_4(self, mock_popen):
        """Critic returns 0 from codex but its output skips a specialist
        probe — the run_specialist validator catches it and returns 4 before the
        layered file is written, so malformed critic output never reaches
        aggregation."""
        mock_popen.side_effect = _make_codex_stub({
            "security": (0, "### Probe 1\nspec body\n\n### Probe 2\nmore\n"),
            # Critic addresses Probe 1 but skips Probe 2 — semantic violation.
            "critic-security": (0,
                "## Critic counter-arguments\n\n### Probe 1\n"
                "- **Answer:** yes\n- **Evidence:** cited\n"),
        })
        rc = pipeline.run_specialist(
            specialist="security",
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 4)
        # Layered file NOT written (validation failed before compose step).
        # Scratch holds raw spec output (staged pre-critic), not layered.
        scratch = (
            self.repo_dir / ".codex-scratch" / "specialists" / "security.md"
        ).read_text()
        self.assertNotIn("## Critic counter-arguments", scratch)

    @patch("pipeline.subprocess.Popen")
    def test_specialist_success_critic_failure_returns_critic_rc(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
            "security": (0, "### Probe 1\nstub\n"),
            "critic-security": (5, ""),
        })
        rc = pipeline.run_specialist(
            specialist="security",
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

    @patch("pipeline.subprocess.Popen")
    def test_first_review_runs_intent_dc_angles_aggregator(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
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
        # All 8 specialists ran
        for specialist in pipeline.SPECIALISTS:
            self.assertTrue((self.run_dir / "agents" / specialist / "output.md").exists())
            self.assertTrue((self.run_dir / "agents" / f"critic-{specialist}" / "output.md").exists())
        # Aggregator ran
        self.assertTrue((self.run_dir / "agents" / "aggregator" / "output.md").exists())
        # Momentum did NOT run (no previous-review.md)
        self.assertFalse((self.run_dir / "agents" / "momentum" / "output.md").exists())

    @patch("pipeline.subprocess.Popen")
    def test_re_review_runs_momentum(self, mock_popen):
        (self.run_dir / "inputs" / "previous-review.md").write_text("prior review body\n")
        mock_popen.side_effect = _make_codex_stub({
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

    @patch("pipeline.subprocess.Popen")
    def test_intent_failure_aborts(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
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

    @patch("pipeline.subprocess.Popen")
    def test_dead_code_failure_aborts_loud(self, mock_popen):
        """dead-code-search becomes fail-loud (was fail-soft in shell pipeline)."""
        mock_popen.side_effect = _make_codex_stub({
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

    @patch("pipeline.subprocess.Popen")
    def test_one_angle_failure_aborts_pipeline(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
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

    @patch("pipeline.subprocess.Popen")
    def test_aggregator_failure_aborts(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
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

    @patch("pipeline.subprocess.Popen")
    def test_intent_must_have_inferred_intent_prefix(self, mock_popen):
        mock_popen.side_effect = _make_codex_stub({
            "intent": (0, "wrong prefix\n"),  # missing "Inferred intent: "
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        self.assertFalse(self.repo_dir.exists())

    @patch("pipeline.subprocess.Popen")
    def test_wave_a_runs_intent_and_dead_code_in_parallel(self, mock_popen):
        """Wave A's intent + dead-code-search must run concurrently. Use
        threading.Barrier(2): both stubs wait at the barrier — if Wave A
        is serial, the first stub blocks alone and BrokenBarrierError
        fires, failing the pipeline. The latency win depends on this
        contract; pin it behaviorally."""
        barrier = threading.Barrier(2, timeout=5)
        def hit_barrier(name, _out_path):
            if name in ("intent", "dead-code-search"):
                barrier.wait()
        mock_popen.side_effect = _make_codex_stub(before_write=hit_barrier)
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.Popen")
    def test_wave_b_runs_specialists_concurrently(self, mock_popen):
        """Wave B's 8-specialist fan-out must run concurrently. Pick two
        deterministic specialists (security, performance) and gate them
        on a shared Barrier(2). Serial Wave B regression → first stub
        blocks alone → BrokenBarrierError → run fails."""
        barrier = threading.Barrier(2, timeout=5)
        def hit_barrier(name, _out_path):
            if name in ("security", "performance"):
                barrier.wait()
        mock_popen.side_effect = _make_codex_stub(before_write=hit_barrier)
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)

    @patch("pipeline.subprocess.Popen")
    def test_wave_b_starts_after_wave_a_artifacts_linked(self, mock_popen):
        """Wave A → Wave B is a hard barrier: every specialist (and momentum
        on re-review) must see `.codex-scratch/inferred-intent.md` and
        `.codex-scratch/dead-code.md` linked at the moment they start."""
        (self.run_dir / "inputs" / "previous-review.md").write_text("prior\n")
        scratch = self.repo_dir / ".codex-scratch"
        seen_links: list[tuple[str, set[str]]] = []
        lock = threading.Lock()
        def capture_scratch_links(name, _out_path):
            if name in pipeline.SPECIALISTS or name == "momentum":
                with lock:
                    seen_links.append((
                        name,
                        {p.name for p in scratch.iterdir() if p.is_symlink()},
                    ))
        mock_popen.side_effect = _make_codex_stub(before_write=capture_scratch_links)
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        self.assertEqual(len(seen_links), len(pipeline.SPECIALISTS) + 1)  # +momentum
        for name, links in seen_links:
            self.assertIn("inferred-intent.md", links,
                          f"{name} started before Wave A linked inferred-intent.md")
            self.assertIn("dead-code.md", links,
                          f"{name} started before Wave A linked dead-code.md")

    @patch("pipeline.subprocess.Popen")
    def test_one_specialist_timeout_tolerated_aggregator_runs(self, mock_popen):
        """≤1 timeout: aggregator runs on 7/8 specialists, a stub fills the
        missing slot so .codex-scratch/specialists/<name>.md exists, and a
        warning sentinel is written for the bash worker to surface above
        the posted review."""
        mock_popen.side_effect = _make_codex_stub(plan={
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "performance": "TIMEOUT",
            "aggregator": (0, "# Review\nVERDICT: APPROVE\n"),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        # Aggregator still ran on the surviving 7 specialists.
        self.assertTrue((self.run_dir / "agents" / "aggregator" / "output.md").exists())
        # Stub at the aggregator's read path so it didn't choke on a missing file.
        scratch_specialist = self.repo_dir / ".codex-scratch" / "specialists" / "performance.md"
        self.assertTrue(scratch_specialist.exists())
        self.assertIn("No probes.", scratch_specialist.read_text())
        # Forensic stub at the run-dir for bakeoff roster math.
        self.assertTrue((self.run_dir / "agents" / "performance" / "layered.md").exists())
        # Banner sentinel for review-one-pr.sh.
        warning = (self.run_dir / "_wave_b_warning.txt").read_text()
        self.assertIn("performance", warning)
        self.assertIn("timed out", warning)
        # The 2+ sentinel must NOT exist (1 timeout is tolerated).
        self.assertFalse((self.run_dir / "_wave_b_timeouts.txt").exists())

    @patch("pipeline.subprocess.Popen")
    def test_two_specialist_timeouts_fail_loud(self, mock_popen):
        """≥2 timeouts: pipeline aborts, no aggregator runs, sentinel lists
        the hung specialists so review-one-pr.sh can replace the 👀
        placeholder with an explicit error naming them."""
        mock_popen.side_effect = _make_codex_stub(plan={
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "performance": "TIMEOUT",
            "security": "TIMEOUT",
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        # _abort cleans up the workdir → assert sentinel was written to run_dir
        # (which is NOT REPO_DIR) so the bash worker can still read it.
        sentinel = self.run_dir / "_wave_b_timeouts.txt"
        self.assertTrue(sentinel.exists())
        names = set(sentinel.read_text().split())
        self.assertEqual(names, {"performance", "security"})
        # No aggregator — we don't post half-broken reviews.
        self.assertFalse((self.run_dir / "agents" / "aggregator" / "output.md").exists())

    @patch("pipeline.subprocess.Popen")
    def test_momentum_timeout_tolerated_writes_scratch_stub(self, mock_popen):
        """Momentum is opportunistic — its timeout is the same as a
        specialist's for tolerance accounting, but the stub goes at
        scratch/momentum.md (its aggregator-visible path), not
        .codex-scratch/specialists/. Without the stub, the success-path
        _relink would error on the missing source."""
        (self.run_dir / "inputs" / "previous-review.md").write_text("prior\n")
        mock_popen.side_effect = _make_codex_stub(plan={
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "momentum": "TIMEOUT",
            "aggregator": (0, "# Review\nVERDICT: APPROVE\n"),
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertEqual(rc, 0)
        momentum_scratch = self.repo_dir / ".codex-scratch" / "momentum.md"
        self.assertTrue(momentum_scratch.exists())
        self.assertIn("momentum timed out", momentum_scratch.read_text())
        # Warning for the bash worker mentions momentum specifically.
        warning = (self.run_dir / "_wave_b_warning.txt").read_text()
        self.assertIn("Momentum", warning)

    @patch("pipeline.subprocess.Popen")
    def test_hard_failure_not_tolerated_even_when_solo(self, mock_popen):
        """Non-timeout failures (contract violations, codex non-zero rc that
        isn't SPECIALIST_TIMEOUT_RC) are bugs, not flakes — no 1-tolerance
        window. A single rc=5 specialist still aborts (preserves pre-existing
        strictness for hard failures while only loosening the timeout case)."""
        mock_popen.side_effect = _make_codex_stub(plan={
            "intent": (0, "Inferred intent: stub.\n"),
            "dead-code-search": (0, "dc\n"),
            "shape": (5, ""),  # hard failure, NOT a timeout
        })
        rc = pipeline.run_pipeline(
            repo_dir=str(self.repo_dir), run_dir=str(self.run_dir),
            prompts_dir=str(self.prompts),
            pr_id="r#1", pr_title="t", pr_url="u", pr_author="a",
        )
        self.assertNotEqual(rc, 0)
        # No warning / timeouts sentinels — this was a hard failure path.
        self.assertFalse((self.run_dir / "_wave_b_warning.txt").exists())
        self.assertFalse((self.run_dir / "_wave_b_timeouts.txt").exists())


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
        for specialist in pipeline.SPECIALISTS:
            self.assertTrue(
                (self.run_dir / "agents" / specialist / "output.md").exists(),
                f"missing specialist output for {specialist}",
            )
            self.assertTrue(
                (self.run_dir / "agents" / f"critic-{specialist}" / "output.md").exists(),
                f"missing critic output for {specialist}",
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
        """common-header.md + each specialist's body file must compose without error."""
        for specialist in pipeline.SPECIALISTS:
            out = pipeline.build_prompt(
                kind="specialist", agent=specialist,
                prompts_dir=str(self.real_prompts),
                pr_id="owner/repo#42", pr_title="Add X",
                pr_url="https://example/pull/42", pr_author="alice",
            )
            self.assertNotIn("{{PR_ID}}", out, f"{specialist}: PR_ID placeholder leaked")
            self.assertNotIn("{{SPECIALIST_NAME}}", out, f"{specialist}: specialist name leaked")
            self.assertIn(specialist, out, f"{specialist}: specialist name missing")

    def test_standalone_compose_against_real_prompts(self):
        """Each standalone prompt body must compose without error against the
        real prompts/ tree — catches drift in prompts/standalone/{intent,
        dead-code-search,momentum}.md (e.g. a renamed placeholder)."""
        for name in ("intent", "dead-code-search", "momentum"):
            out = pipeline.build_prompt(
                kind="standalone", agent=name,
                prompts_dir=str(self.real_prompts),
                pr_id="owner/repo#42", pr_title="Add X",
                pr_url="https://example/pull/42", pr_author="alice",
            )
            self.assertNotIn("{{PR_ID}}", out, f"{name}: PR_ID placeholder leaked")
            self.assertNotIn("{{PR_TITLE}}", out, f"{name}: PR_TITLE placeholder leaked")


if __name__ == "__main__":
    unittest.main()
