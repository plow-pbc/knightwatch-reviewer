#!/bin/bash
# Detects whether the working dir's TypeScript project enforces strict typing.
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

set -u

if jq -e '.compilerOptions.strict == true' tsconfig.json >/dev/null 2>&1; then
    exit 0
fi

if [ ! -f tsconfig.json ]; then
    echo "TypeScript project: tsconfig.json not found at repo root"
else
    echo "TypeScript project: tsconfig.json compilerOptions.strict is not true"
fi
