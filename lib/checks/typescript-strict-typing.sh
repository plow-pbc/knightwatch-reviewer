#!/bin/bash
# Detects whether the working dir's TypeScript project enforces strict typing.
#
# Usage: typescript-strict-typing.sh [PROJECT_DIR]
#   PROJECT_DIR: optional subdir relative to cwd; defaults to ".". Set
#   per-repo in repos.conf::STRICT_TYPING_CMDS for nested project roots.
#
# Outputs the gap description on stdout if NOT enforced; empty stdout if
# strict mode is set. Same shape as python-strict-typing.sh: caller
# treats non-empty stdout as a deterministic-finding signal that
# bypasses LLM judgment entirely.
#
# Recognized: tsconfig.json's `compilerOptions.strict === true`. Per-flag
# strict (e.g. only `strictNullChecks=true`) is NOT recognized — for
# parity with python-strict-typing.sh, the rule is "all-strict or gap."
# Operators who want a softer policy can edit this file, but the goal
# is to nudge toward unconditional strict mode, not to encode every
# project's bespoke definition of "strict enough."
#
# tsconfig.json reached via symlink is refused (same trust-boundary
# reasoning as python-strict-typing.sh).

set -u

PROJECT_DIR="${1:-.}"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

if [ -L tsconfig.json ]; then
    echo "TypeScript project: tsconfig.json is a symlink — refused (possible config-injection from fork PR)"
    exit 0
fi

if [ ! -f tsconfig.json ]; then
    echo "TypeScript project: tsconfig.json not found at repo root"
    exit 0
fi

if jq -e '.compilerOptions.strict == true' tsconfig.json >/dev/null 2>&1; then
    exit 0
fi

echo "TypeScript project: tsconfig.json compilerOptions.strict is not true"
