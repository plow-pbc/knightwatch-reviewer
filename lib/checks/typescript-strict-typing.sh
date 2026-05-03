#!/usr/bin/env bash
# Detects whether the working dir's TypeScript project enforces strict typing.
#
# Usage: typescript-strict-typing.sh [PROJECT_DIR]
#   PROJECT_DIR: optional subdir relative to cwd; defaults to ".". Set
#   per-repo in <repo>/.knightwatch/strict-typing.sh for nested project roots.
#
# Tri-state contract (worker treats each exit code distinctly):
#   exit 0 — strict mode is enforced.        stdout: empty.
#   exit 1 — strict mode is NOT enforced.    stdout: gap description (becomes a [nit]).
#   exit 2 — checker could not determine.    stderr: error description (logged loud, no nit).
#
# Same rationale as python-strict-typing.sh: collapsing checker errors
# into "not strict" silently publishes wrong review text. Refuse
# symlinks at both PROJECT_DIR and tsconfig.json (fork trust boundary).
#
# Recognized: tsconfig.json's `compilerOptions.strict === true`. Per-flag
# strict (e.g. only `strictNullChecks=true`) is NOT recognized — for
# parity with python-strict-typing.sh, the rule is "all-strict or gap."
#
# Diff-scope gate: same shape as python-strict-typing.sh. If the worker
# exports TOUCHED_FILES_FILE and zero of those paths match `*.ts` /
# `*.tsx` under PROJECT_DIR, exit 0 with a stderr scope-skip log. JS /
# JSX files are not in scope — strict typing is a TypeScript-specific
# concept; allowJs+strict edge cases are too narrow to gate on by
# default.

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
    # Scope match: either a touched TS source, OR a touched tsconfig.json
    # (the config the helper itself reads). Without the config branch, a
    # PR that disables strict typing by editing only `tsconfig.json` (no
    # `*.ts` / `*.tsx` source touched) would scope-skip and the
    # deterministic gap note would be silently suppressed on a real
    # regression. Same Narrow-Fix class flagged on round 6.
    if [ "$PROJECT_DIR" = "." ]; then
        SCOPE_RE='\.tsx?$|^tsconfig\.json$'
    else
        SCOPE_RE="^${PROJECT_DIR}/(.*\.tsx?|tsconfig\.json)$"
    fi
    if ! grep -E "$SCOPE_RE" "$TOUCHED_FILES_FILE" >/dev/null; then
        echo "scope-skip: no TypeScript files (*.ts, *.tsx) or tsconfig.json touched under '$PROJECT_DIR'" >&2
        exit 0
    fi
fi

cd "$PROJECT_DIR" || {
    echo "checker-error: cannot cd into PROJECT_DIR '$PROJECT_DIR'" >&2
    exit 2
}

if [ -L tsconfig.json ]; then
    echo "checker-error: tsconfig.json is a symlink (refused; possible config-injection from fork PR)" >&2
    exit 2
fi

if [ ! -f tsconfig.json ]; then
    echo "TypeScript project: tsconfig.json not found at repo root"
    exit 1
fi

if ! jq empty tsconfig.json 2>/dev/null; then
    echo "checker-error: tsconfig.json is malformed JSON (TS allows JSONC comments; jq does not)" >&2
    exit 2
fi

if jq -e '.compilerOptions.strict == true' tsconfig.json >/dev/null 2>&1; then
    exit 0
fi

echo "TypeScript project: tsconfig.json compilerOptions.strict is not true"
exit 1
