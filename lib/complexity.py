#!/usr/bin/env python3
"""Complexity budget: read the PR template's fields and check net LOC against them.

The PR body states an expected net LOC. The first review freezes that figure in
an invisible marker on the bot's comment, so a later edit to the body can't
move the budget. A PR is over budget, and needs its author's OK, when

    actual > expected + 0.4 * |expected| + 50

`assess` prints one JSON object for the review worker: the header note, whether
the PR is over budget (null when the body lacks the fields), and the marker line
to append to the posted review.
"""

import argparse
import base64
import json
import re
import sys

SECTIONS = ("Goal", "Outside users today", "Minimal solution for that user count", "Complexity added")
ANY_FIELD = "|".join(map(re.escape, SECTIONS + ("Requested by", "Size")))
MARKER_RE = re.compile(
    r"^<!-- knightwatch-reviewer:complexity expected=(-?\d+) sha=([0-9a-f]+)"
    r"(?: source=(author|model) model=(-?\d+) sketch64=([A-Za-z0-9_-]+))? -->$"
)
NUMBER_RE = re.compile(r"^[~≈]?\s*([+\-−]?)\s*(\d[\d,]*)")
MAX_SCOPE_TEXT = 500


def _strip_comments(text):
    return re.sub(r"<!--.*?-->", "", text, flags=re.S)


def _lead_in(field):
    """A `**field:**` (or `**field**:`) bold lead-in at the start of a line or bullet."""
    return rf"^[ \t]*(?:[-*][ \t]+)?\*\*(?:{field})(?::\*\*|\*\*:)"


def _section(body, field):
    """A field's text, after a `**field:**` lead-in up to the next field, heading or blank line, else
    under `## field` up to the next H2; None when neither has text. The lead-in is tried first because
    a template heading left in the body still carries its placeholder bullets."""
    for pattern in (rf"{_lead_in(re.escape(field))}(.*?)(?={_lead_in(ANY_FIELD)}|^#|^[ \t]*$|\Z)",
                    rf"^##[ \t]+{re.escape(field)}[ \t]*$(.*?)(?=^##[ \t]|\Z)"):
        m = re.search(pattern, body, re.M | re.S)
        text = m and _strip_comments(m.group(1)).replace("**", "").strip()
        if text:
            return text
    return None


def _number_after(size, label):
    """The signed integer after `label` in the Size field, or None for a blank or `<N>` placeholder."""
    m = re.search(rf"\b{label}[ \t]*(.*)$", size or "", re.M | re.I)
    n = m and NUMBER_RE.match(m.group(1).strip())
    if not n:
        return None
    value = int(n.group(2).replace(",", ""))
    return -value if n.group(1) in ("-", "−") else value


def parse_body(body):
    body = (body or "").replace("\r\n", "\n")
    missing = [s for s in SECTIONS if not _section(body, s)]
    size = _section(body, "Size")
    expected = _number_after(size, r"Expected(?:[ \t]+net[ \t]+LOC[ \t]*:?|[ \t]*:)")
    if expected is None:
        missing.append("Size: Expected net LOC")
    ask = _section(body, "Requested by") or _section(body, "Goal") or _section(body, "Summary")
    if ask:
        ask = ask.split("\n\n", 1)[0].replace("\n", " ")[:MAX_SCOPE_TEXT]
    return {"missing": missing, "expected": expected,
            "claimed_actual": _number_after(size, r"At convergence:[ \t]*(?:actual)?"),
            "ask": ask}


def budget(expected):
    """Largest net LOC within budget: floor(expected + 0.4*|expected| + 50), in integers so no rounding decides a PR."""
    return (5 * expected + 2 * abs(expected) + 250) // 5


def frozen_budget(comments, bot):
    """Frozen budget data from the bot's first complexity card, or None."""
    for c in comments:
        if (c.get("user") or {}).get("login") != bot:
            continue
        lines = (c.get("body") or "").replace("\r\n", "\n").rstrip().split("\n")
        m = MARKER_RE.match(lines[-1])
        if m:
            sketch = ""
            if m.group(5):
                sketch = base64.urlsafe_b64decode(m.group(5) + "=" * (-len(m.group(5)) % 4)).decode()
            return {"expected": int(m.group(1)), "source": m.group(3) or "author",
                    "model": int(m.group(4)) if m.group(4) else None, "sketch": sketch}
    return None


def assess(body, actual, comments, bot, sha, author, model_expected=None, sketch=""):
    fields = parse_body(body)
    if fields["missing"] and model_expected is None:
        return {"over": None, "marker": "",
                "note": "📐 Complexity budget unchecked — the PR body is missing "
                        + ", ".join(fields["missing"])
                        + "; fill in those PR-template fields so the next review can check the budget"}
    frozen = frozen_budget(comments, bot)
    if frozen is None:
        source = "model" if model_expected is not None and (
            fields["expected"] is None or model_expected <= fields["expected"]
        ) else "author"
        expected = model_expected if source == "model" else fields["expected"]
        frozen_model = model_expected
        frozen_sketch = sketch
    else:
        source = frozen["source"]
        expected = frozen["expected"]
        frozen_model = frozen["model"]
        frozen_sketch = frozen["sketch"]
    over = actual > budget(expected)
    note = (f"📐 Complexity budget: expected {expected:+d} net LOC"
            f"{' (frozen at the first card)' if frozen is not None else ''}"
            f" · actual {actual:+d} · budget ≤ {budget(expected):+d} — "
            + (f"**over budget**, labeled `needs-owner-ok` until @{author} OKs it" if over else "within budget"))
    if frozen is not None and source == "author" and fields["expected"] != expected:
        if fields["expected"] is None:
            note += " · ⚠️ the body's Expected was removed after the first card"
        else:
            note += f" · ⚠️ the body's Expected was edited to {fields['expected']:+d} after the first card"
    if fields["claimed_actual"] is not None and fields["claimed_actual"] != actual:
        note += f" · ⚠️ the body claims actual {fields['claimed_actual']:+d}, the diff measures {actual:+d}"
    if over and source == "model":
        note += (f" · Quoted ask: {fields['ask'] or '(no request quoted in the PR body)'}"
                 f" · Smaller fix ({frozen_model:+d} net LOC): {frozen_sketch.rstrip('.')}")
    marker = f"<!-- knightwatch-reviewer:complexity expected={expected} sha={sha}"
    if frozen_model is not None:
        encoded = base64.urlsafe_b64encode(frozen_sketch.encode()).decode().rstrip("=")
        marker += f" source={source} model={frozen_model} sketch64={encoded}"
    return {"over": over, "note": note, "source": source,
            "model_expected": frozen_model, "sketch": frozen_sketch, "marker": marker + " -->"}


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--body", required=True, help="file holding the PR body")
    p.add_argument("--comments", required=True, help="file holding the PR's issue comments as a JSON array")
    p.add_argument("--actual", required=True, type=int, help="net LOC of the PR diff (additions - deletions)")
    p.add_argument("--bot", required=True, help="login whose comments carry the frozen expected figure")
    p.add_argument("--sha", required=True, help="head SHA under review")
    p.add_argument("--author", required=True, help="PR author's login: the person whose OK an over-budget PR waits for")
    p.add_argument("--model-estimate", type=int, help="model's smallest-change net LOC estimate")
    p.add_argument("--sketch", default="", help="model's smaller-fix sketch")
    a = p.parse_args(argv)
    with open(a.body) as b, open(a.comments) as c:
        print(json.dumps(assess(b.read(), a.actual, json.load(c), a.bot, a.sha,
                                a.author, a.model_estimate, a.sketch)))


if __name__ == "__main__":
    main(sys.argv[1:])
