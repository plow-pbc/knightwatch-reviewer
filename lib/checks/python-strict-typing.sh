#!/bin/bash
# Detects whether the working dir's Python project enforces strict typing.
#
# Outputs the gap description on stdout if NOT enforced; empty stdout if
# strict mode is set. Caller (lib/review-one-pr.sh) treats non-empty
# stdout as a deterministic-finding signal that bypasses LLM judgment
# entirely — so the rules below are the rules; if a project sets strict
# mode in a way this checker doesn't recognize, add it here, don't
# soften the threshold.
#
# Recognized strict-mode signals (any one is enough):
#   - pyproject.toml `[tool.mypy] strict = true`
#   - pyproject.toml `[tool.pyright] strict = true`
#   - pyproject.toml `[tool.basedpyright] strict = true`
#   - pyrightconfig.json top-level `"strict": true`
#   - mypy.ini `strict = True` (any section)
#   - setup.cfg `[mypy]` `strict = True`
#
# Per-flag mypy strict-mode (e.g. setting `disallow_untyped_defs = true`
# without `strict = true`) is NOT recognized — operators who want that
# pattern should switch to `strict = true` and override individual flags
# below it.

set -u

if python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    import tomllib
except ImportError:
    sys.exit(1)

def has_strict():
    if os.path.exists("pyproject.toml"):
        with open("pyproject.toml", "rb") as f:
            d = tomllib.loads(f.read().decode("utf-8"))
        t = d.get("tool", {})
        for tool in ("mypy", "pyright", "basedpyright"):
            if t.get(tool, {}).get("strict") is True:
                return True
    if os.path.exists("pyrightconfig.json"):
        with open("pyrightconfig.json") as f:
            if json.loads(f.read()).get("strict") is True:
                return True
    for fname in ("mypy.ini", "setup.cfg"):
        if os.path.exists(fname):
            with open(fname) as f:
                # "strict = True" or "strict=true" anywhere is enough; the
                # mypy config parser is case-insensitive on the value.
                for line in f:
                    s = line.strip().lower().replace(" ", "")
                    if s.startswith("strict=true"):
                        return True
    return False

sys.exit(0 if has_strict() else 1)
PY
then
    exit 0
fi

echo "Python project: no strict-mode config (looked for [tool.mypy/pyright/basedpyright] strict=true in pyproject.toml; \"strict\":true in pyrightconfig.json; strict=true in mypy.ini or setup.cfg)"
