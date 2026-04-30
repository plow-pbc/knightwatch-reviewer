#!/bin/bash
# Detects whether the working dir's Python project enforces strict typing.
#
# Usage: python-strict-typing.sh [PROJECT_DIR]
#   PROJECT_DIR: optional subdir relative to cwd; defaults to ".". Set
#   per-repo in repos.conf::STRICT_TYPING_CMDS for nested project roots
#   (e.g. plow's strict config lives in api/pyproject.toml, not at root).
#
# Outputs the gap description on stdout if NOT enforced; empty stdout if
# strict mode is set. Caller (lib/review-one-pr.sh) treats non-empty
# stdout as a deterministic-finding signal that bypasses LLM judgment
# entirely — so the rules below are the rules; if a project sets strict
# mode in a way this checker doesn't recognize, add it here, don't
# soften the threshold.
#
# Recognized strict-mode signals (any one is enough):
#   - pyproject.toml [tool.mypy] strict = true
#   - pyproject.toml [tool.pyright] typeCheckingMode = "strict"
#   - pyproject.toml [tool.basedpyright] typeCheckingMode = "strict"
#   - pyrightconfig.json top-level "strict": true
#   - mypy.ini [mypy] strict = True
#   - setup.cfg [mypy] strict = True
#
# pyright/basedpyright's `strict` field is a list of file patterns (NOT a
# boolean), so the canonical project-wide signal is `typeCheckingMode`.
# Per-flag mypy strict-mode (e.g. `disallow_untyped_defs = true` without
# `strict = true`) is NOT recognized — switch to `strict = true` and
# override individual flags below it.
#
# INI keys are matched structurally via configparser scoped to the [mypy]
# section so an unrelated `strict = true` line in setup.cfg cannot
# spoof the deterministic check.
#
# Config files reached via symlink are refused: the worker runs this
# against fork-controlled checkouts (lib/auth.sh treats fork authors as
# untrusted), so a symlink at pyproject.toml could leak one bit per PR
# about an arbitrary readable host file. Refuse rather than read.

set -u

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

if python3 - <<'PY' 2>/dev/null
import configparser, json, os, sys
try:
    import tomllib
except ImportError:
    sys.exit(1)

def safe_read(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()

def has_strict():
    raw = safe_read("pyproject.toml")
    if raw is not None:
        d = tomllib.loads(raw.decode("utf-8"))
        t = d.get("tool", {})
        if t.get("mypy", {}).get("strict") is True:
            return True
        for tool in ("pyright", "basedpyright"):
            if t.get(tool, {}).get("typeCheckingMode") == "strict":
                return True

    raw = safe_read("pyrightconfig.json")
    if raw is not None:
        if json.loads(raw.decode("utf-8")).get("strict") is True:
            return True

    for fname in ("mypy.ini", "setup.cfg"):
        raw = safe_read(fname)
        if raw is None:
            continue
        cp = configparser.ConfigParser()
        try:
            cp.read_string(raw.decode("utf-8"))
        except configparser.Error:
            continue
        if cp.has_option("mypy", "strict") and cp.get("mypy", "strict").strip().lower() == "true":
            return True

    return False

sys.exit(0 if has_strict() else 1)
PY
then
    exit 0
fi

echo "Python project: no strict-mode config (looked for [tool.mypy] strict=true, [tool.pyright|basedpyright] typeCheckingMode=\"strict\" in pyproject.toml; \"strict\":true in pyrightconfig.json; [mypy] strict=True in mypy.ini or setup.cfg)"
