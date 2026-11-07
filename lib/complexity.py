#!/usr/bin/env python3
"""Complexity budget: read the PR template's fields and check net LOC against them.

The PR body states an expected net LOC. The first review freezes that figure in
an invisible marker on the bot's comment, so a later edit to the body can't
move the budget. A PR is over budget, and needs the operator's OK, when

    actual > expected + 0.4 * |expected| + 50

`assess` prints one JSON object for the review worker: the header note, whether
the PR is over budget (null when the body lacks the fields), and the marker line
to append to the posted review.
"""

import argparse
import json
import re
import sys

SECTIONS = ("Goal", "Outside users today", "Minimal solution for that user count", "Complexity added")
MARKER_RE = re.compile(r"^<!-- knightwatch-reviewer:complexity expected=(-?\d+) sha=([0-9a-f]+) -->$")
NUMBER_RE = re.compile(r"^[~≈]?\s*([+\-−]?)\s*(\d[\d,]*)")


def _strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def _section(body, heading):
    """Text under `## heading` up to the next H2, or None when the heading is absent."""
    m = re.search(rf"^##[ \t]+{re.escape(heading)}[ \t]*$(.*?)(?=^##[ \t]|\Z)", body, re.M | re.S)
    return None if m is None else _strip_comments(m.group(1)).strip()


def _number_after(size, label):
    """The signed integer after `label` on a Size bullet, or None for a blank or `<N>` placeholder."""
    m = re.search(rf"^[ \t]*[-*][ \t]*{label}[ \t]*(.*)$", size or "", re.M | re.I)
    n = m and NUMBER_RE.match(m.group(1).strip())
    if not n:
        return None
    value = int(n.group(2).replace(",", ""))
    return -value if n.group(1) in ("-", "−") else value


def parse_body(body):
    body = (body or "").replace("\r\n", "\n")
    missing = [s for s in SECTIONS if not _section(body, s)]
    size = _section(body, "Size")
    expected = _number_after(size, "Expected:")
    if expected is None:
        missing.append("Size: Expected net LOC")
    return {"missing": missing, "expected": expected, "claimed_actual": _number_after(size, r"At convergence:[ \t]*actual")}


def budget(expected):
    """Largest net LOC within budget: floor(expected + 0.4*|expected| + 50), in integers so no rounding decides a PR."""
    return (5 * expected + 2 * abs(expected) + 250) // 5


def frozen_expected(comments, bot):
    """Expected figure from the bot's first complexity card, or None before the first card."""
    for c in comments:
        if (c.get("user") or {}).get("login") != bot:
            continue
        lines = (c.get("body") or "").replace("\r\n", "\n").rstrip().split("\n")
        m = MARKER_RE.match(lines[-1])
        if m:
            return int(m.group(1))
    return None


def assess(body, actual, comments, bot, sha):
    fields = parse_body(body)
    if fields["missing"]:
        return {"over": None, "marker": "",
                "note": "📐 Complexity budget unchecked — the PR body is missing "
                        + ", ".join(fields["missing"])
                        + "; fill in those PR-template fields so the next review can check the budget"}
    frozen = frozen_expected(comments, bot)
    expected = fields["expected"] if frozen is None else frozen
    over = actual > budget(expected)
    note = (f"📐 Complexity budget: expected {expected:+d} net LOC"
            f"{' (frozen at the first card)' if frozen is not None else ''}"
            f" · actual {actual:+d} · budget ≤ {budget(expected):+d} — "
            + ("**over budget**, labeled `needs-sam` until the operator OKs it" if over else "within budget"))
    if frozen is not None and fields["expected"] != frozen:
        note += f" · ⚠️ the body's Expected was edited to {fields['expected']:+d} after the first card"
    if fields["claimed_actual"] is not None and fields["claimed_actual"] != actual:
        note += f" · ⚠️ the body claims actual {fields['claimed_actual']:+d}, the diff measures {actual:+d}"
    return {"over": over, "note": note,
            "marker": f"<!-- knightwatch-reviewer:complexity expected={expected} sha={sha} -->"}


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--body", required=True, help="file holding the PR body")
    p.add_argument("--comments", required=True, help="file holding the PR's issue comments as a JSON array")
    p.add_argument("--actual", required=True, type=int, help="net LOC of the PR diff (additions - deletions)")
    p.add_argument("--bot", required=True, help="login whose comments carry the frozen expected figure")
    p.add_argument("--sha", required=True, help="head SHA under review")
    a = p.parse_args(argv)
    with open(a.body) as b, open(a.comments) as c:
        print(json.dumps(assess(b.read(), a.actual, json.load(c), a.bot, a.sha)))


if __name__ == "__main__":
    main(sys.argv[1:])
