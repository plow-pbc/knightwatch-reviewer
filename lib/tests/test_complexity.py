"""Tests for the complexity budget: template parsing, the gate, the frozen figure."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import complexity  # noqa: E402

SHA = "abc1234def"


def body(expected="~+100", actual="<N>"):
    return f"""<!-- Complexity budget. -->

## Goal
<!-- Business case. -->
Track complexity. Requested by: the operator.

## Outside users today
0 — internal tooling

## Minimal solution for that user count
One markdown file.

## Complexity added
None.

## Size
- Expected: {expected} net LOC · new moving parts: none
- At convergence: actual {actual} net LOC · moving parts: none
- Verdict: complexity <up | flat | down> — <why>
"""


def card(expected, login="srosro"):
    return {"user": {"login": login},
            "body": f"review text\n<!-- knightwatch-reviewer:complexity expected={expected} sha={SHA} -->\n"}


class TestAssess(unittest.TestCase):
    def test_budget_gate(self):
        # (expected, actual, over): Sam's rule, actual > expected + 0.4*|expected| + 50.
        for expected, actual, over in [
            ("~+1,000", 1450, False), ("~+1,000", 1451, True),
            ("+20", 78, False), ("+20", 79, True),
            ("−500", -250, False), ("-500", -249, True),  # cleanup: delete a bit less than promised
            ("0", 50, False), ("0", 51, True),
            ("+4", 55, False), ("+4", 56, True),  # 55.6: the displayed budget floors to the last passing LOC
        ]:
            with self.subTest(expected=expected, actual=actual):
                self.assertEqual(complexity.assess(body(expected), actual, [], "srosro", SHA)["over"], over)

    def test_missing_fields_ask_once_and_skip_the_gate(self):
        for text, missing in [
            ("", "Goal, Outside users today, Minimal solution for that user count, Complexity added, Size: Expected net LOC"),
            (body(expected="~<N>"), "Size: Expected net LOC"),
            (body().replace("None.", "<!-- or none -->"), "Complexity added"),
            (body().replace("## Size", "## Sizing"), "Size: Expected net LOC"),  # an Expected bullet outside Size doesn't count
        ]:
            with self.subTest(missing=missing):
                r = complexity.assess(text, 10, [], "srosro", SHA)
                self.assertIsNone(r["over"])
                self.assertEqual(r["marker"], "")
                self.assertIn("missing " + missing + ";", r["note"])

    def test_displayed_budget_is_the_last_passing_loc(self):
        self.assertIn("budget ≤ +55", complexity.assess(body("+4"), 10, [], "srosro", SHA)["note"])

    def test_first_card_freezes_expected(self):
        r = complexity.assess(body("+100"), 100, [], "srosro", SHA)
        self.assertEqual(r["marker"], f"<!-- knightwatch-reviewer:complexity expected=100 sha={SHA} -->")
        self.assertNotIn("edited", r["note"])

        # The author raises Expected to dodge the gate: the frozen +100 still decides, and the edit is flagged.
        later = complexity.assess(body("+1000"), 500, [card(100)], "srosro", SHA)
        self.assertTrue(later["over"])
        self.assertIn("expected +100 net LOC (frozen at the first card)", later["note"])
        self.assertIn("edited to +1000", later["note"])
        self.assertIn("expected=100 ", later["marker"])

    def test_only_the_bots_trailing_marker_freezes(self):
        quoted = {"user": {"login": "srosro"},
                  "body": f"<!-- knightwatch-reviewer:complexity expected=9999 sha={SHA} -->\nquoted, not trailing"}
        for comments in ([card(9999, login="someone-else")], [quoted]):
            with self.subTest(comments=comments):
                self.assertTrue(complexity.assess(body("+100"), 500, comments, "srosro", SHA)["over"])

    def test_claimed_actual_checked_against_the_diff(self):
        self.assertIn("the body claims actual +40, the diff measures +90",
                      complexity.assess(body(actual="+40"), 90, [], "srosro", SHA)["note"])
        self.assertNotIn("claims", complexity.assess(body(actual="+90"), 90, [], "srosro", SHA)["note"])


if __name__ == "__main__":
    unittest.main()
