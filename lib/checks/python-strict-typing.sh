#!/usr/bin/env bash
# Detects whether the working dir's Python project enforces strict typing.
#
# Usage: python-strict-typing.sh [PROJECT_DIR]
#   PROJECT_DIR: optional subdir relative to cwd; defaults to ".". Set
#   per-repo in repos.conf::STRICT_TYPING_CMDS for nested project roots
#   (e.g. plow's strict config lives in api/pyproject.toml, not at root).
#
# Tri-state contract (worker treats each exit code distinctly):
#   exit 0 — strict mode is enforced.        stdout: empty.
#   exit 1 — strict mode is NOT enforced.    stdout: gap description (becomes a [nit]).
#   exit 2 — checker could not determine.    stderr: error description (logged loud, no nit).
#
# The tri-state is load-bearing: collapsing "could not determine" into
# "not strict" silently publishes wrong review text — see PR #27 round-2
# bot review. Fail-loud on broken inputs; only post a nit when we are
# confident it reflects reality.
#
# Recognized strict-mode signals (any one is enough):
#   - pyproject.toml [tool.mypy] strict = true
#   - pyproject.toml [tool.pyright] typeCheckingMode = "strict"
#   - pyproject.toml [tool.basedpyright] typeCheckingMode = "strict"
#   - pyrightconfig.json top-level "typeCheckingMode": "strict"
#   - mypy.ini [mypy] strict = True
#   - setup.cfg [mypy] strict = True
#
# Precedence: per pyright docs, when pyrightconfig.json is present it
# overrides [tool.pyright|basedpyright] in pyproject.toml. mypy config
# is independent (its own precedence rules across mypy.ini / setup.cfg /
# pyproject.toml). pyright/basedpyright's `strict` field is a list of
# file patterns (NOT a boolean), so the canonical project-wide signal
# is `typeCheckingMode`. Per-flag mypy strict-mode (e.g.
# `disallow_untyped_defs = true` without `strict = true`) is NOT
# recognized — switch to `strict = true` and override individual flags
# below it.
#
# INI keys are matched structurally via configparser scoped to the [mypy]
# section so an unrelated `strict = true` line in setup.cfg cannot
# spoof the deterministic check.
#
# Trust boundary: the worker runs this against fork-controlled checkouts
# (lib/auth.sh treats fork authors as untrusted). A symlink at
# pyproject.toml / pyrightconfig.json / mypy.ini / setup.cfg — or a
# symlink at PROJECT_DIR itself — could leak one bit per PR about an
# arbitrary readable host file/dir. Refuse symlinks at both levels.
#
# Diff-scope gate: the strict-typing nag is only meaningful when the PR
# actually touches typed code under PROJECT_DIR; running it on a
# package-lock.json-only / docs-only / CI-config-only PR produces a
# useless byte-identical nag every time. If the worker exports
# TOUCHED_FILES_FILE (newline-separated, repo-root-relative paths) and
# zero of those files match `*.py` / `*.pyi` under PROJECT_DIR, exit 0
# with a stderr scope-skip log — the worker treats that identically to
# "strict mode enforced" (no note). Manual invocation without
# TOUCHED_FILES_FILE proceeds unconditionally so the smokes can drive
# every config-detection branch without staging a fake diff.

set -u

PROJECT_DIR="${1:-.}"

if [ -L "$PROJECT_DIR" ]; then
    echo "checker-error: PROJECT_DIR '$PROJECT_DIR' is a symlink (refused; possible config-injection from fork PR)" >&2
    exit 2
fi
if [ ! -d "$PROJECT_DIR" ]; then
    echo "checker-error: PROJECT_DIR '$PROJECT_DIR' is not a directory" >&2
    exit 2
fi

if [ -n "${TOUCHED_FILES_FILE:-}" ] && [ -f "$TOUCHED_FILES_FILE" ]; then
    # Scope match: either a touched Python source/stub, OR a touched
    # config file the helper itself reads. The config-file branch is
    # load-bearing — without it, a PR that disables strict typing by
    # editing only `pyproject.toml` / `mypy.ini` / `pyrightconfig.json`
    # / `setup.cfg` (no `*.py` source touched) would scope-skip and
    # the deterministic gap note would be silently suppressed on a
    # real regression. Same Narrow-Fix class flagged on round 6.
    if [ "$PROJECT_DIR" = "." ]; then
        SCOPE_RE='\.pyi?$|^(pyproject\.toml|mypy\.ini|pyrightconfig\.json|setup\.cfg)$'
    else
        SCOPE_RE="^${PROJECT_DIR}/(.*\.pyi?|pyproject\.toml|mypy\.ini|pyrightconfig\.json|setup\.cfg)$"
    fi
    if ! grep -E "$SCOPE_RE" "$TOUCHED_FILES_FILE" >/dev/null; then
        echo "scope-skip: no Python files (*.py, *.pyi) or strict-typing config (pyproject.toml, mypy.ini, pyrightconfig.json, setup.cfg) touched under '$PROJECT_DIR'" >&2
        exit 0
    fi
fi

cd "$PROJECT_DIR" || {
    echo "checker-error: cannot cd into PROJECT_DIR '$PROJECT_DIR'" >&2
    exit 2
}

python3 - <<'PY'
import configparser, json, os, sys
try:
    import tomllib
except ImportError:
    sys.stderr.write("checker-error: python3 < 3.11 (no tomllib)\n")
    sys.exit(2)

def safe_read(path):
    if os.path.islink(path):
        sys.stderr.write(f"checker-error: {path} is a symlink (refused; possible config-injection from fork PR)\n")
        sys.exit(2)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()

def has_strict():
    # pyrightconfig.json takes precedence over pyproject.toml [tool.pyright|basedpyright]
    # per pyright docs, so resolve pyright's mode here first and short-circuit
    # the pyproject pyright/basedpyright lookup if pyrightconfig.json is present.
    pyright_via_json = False
    raw = safe_read("pyrightconfig.json")
    if raw is not None:
        try:
            cfg = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as e:
            sys.stderr.write(f"checker-error: pyrightconfig.json parse error: {e}\n")
            sys.exit(2)
        pyright_via_json = True
        if cfg.get("typeCheckingMode") == "strict":
            return True

    raw = safe_read("pyproject.toml")
    if raw is not None:
        try:
            d = tomllib.loads(raw.decode("utf-8"))
        except tomllib.TOMLDecodeError as e:
            sys.stderr.write(f"checker-error: pyproject.toml parse error: {e}\n")
            sys.exit(2)
        t = d.get("tool", {})
        if t.get("mypy", {}).get("strict") is True:
            return True
        if not pyright_via_json:
            for tool in ("pyright", "basedpyright"):
                if t.get(tool, {}).get("typeCheckingMode") == "strict":
                    return True

    for fname in ("mypy.ini", "setup.cfg"):
        raw = safe_read(fname)
        if raw is None:
            continue
        cp = configparser.ConfigParser()
        try:
            cp.read_string(raw.decode("utf-8"))
        except configparser.Error as e:
            sys.stderr.write(f"checker-error: {fname} parse error: {e}\n")
            sys.exit(2)
        if cp.has_option("mypy", "strict") and cp.get("mypy", "strict").strip().lower() == "true":
            return True

    return False

sys.exit(0 if has_strict() else 1)
PY

RC=$?
case $RC in
    0) exit 0 ;;
    1)
        echo "Python project: no strict-mode config (looked for [tool.mypy] strict=true, [tool.pyright|basedpyright] typeCheckingMode=\"strict\" in pyproject.toml; \"typeCheckingMode\":\"strict\" in pyrightconfig.json; [mypy] strict=True in mypy.ini or setup.cfg)"
        exit 1
        ;;
    *) exit 2 ;;
esac
