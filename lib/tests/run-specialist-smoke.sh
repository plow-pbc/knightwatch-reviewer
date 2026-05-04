#!/usr/bin/env bash
# Smoke test for lib/run-specialist.sh.
#
# Locks down the artifact contract the per-run logging relies on:
#   - Writes prompt.txt with the prompt body.
#   - Writes output.md (codex's -o target).
#   - Writes log.txt with start/exit markers + raw codex stderr.
#   - Propagates a non-zero codex exit code unchanged.
#   - Exits 3 on empty output even when codex itself succeeds.
#
# Stubs codex via a PATH override so the test runs without a real
# codex binary. Runs in a private tmpdir — does not touch
# ~/.pr-reviewer.

set -uo pipefail

TMPDIR=$(mktemp -d -t run-specialist-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$PROJECT_ROOT/lib/run-specialist.sh"

# Fake .git so run-specialist.sh's "is a git repo" gate passes.
REPO_DIR="$TMPDIR/repo"
mkdir -p "$REPO_DIR/.git"

# PATH-based codex stub. Each test rewrites $TMPDIR/bin/codex to control
# behavior (success, error, empty output).
mkdir -p "$TMPDIR/bin"
export PATH="$TMPDIR/bin:$PATH"

# Stubs log argv here so we can assert specific flags survive (e.g. the
# `-c model=gpt-5.5` pin — guards against silent unpin).
export ARGV_LOG="$TMPDIR/codex-argv.log"

# ---- scenario 1: success path -------------------------------------------
echo "  scenario 1: success path produces prompt/output/log..."
cat > "$TMPDIR/bin/codex" <<'STUB'
#!/bin/bash
# Log argv so the smoke can assert which flags reached codex.
printf '%s\n' "$@" > "$ARGV_LOG"
# Find -o argument and write a deterministic line into it; emit a stderr
# marker so we can assert it lands in log.txt.
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) OUT_FILE="$2"; shift 2 ;;
        -C|-c) shift 2 ;;
        --dangerously-bypass-approvals-and-sandbox) shift ;;
        *) shift ;;
    esac
done
# Emit probe-contract-compliant output so the security/specialist
# probe-shape gate at run-specialist.sh:62-74 accepts. The stub-output-
# marker remains as a downstream-grep anchor for this smoke.
{ printf '### Probe 1\n'; echo "stub-output-marker"; } > "$OUT_FILE"
echo "stub-stderr-marker" >&2
exit 0
STUB
chmod +x "$TMPDIR/bin/codex"

AGENT_DIR="$TMPDIR/agents/security"
bash "$SCRIPT" "security" "$REPO_DIR" "test-prompt-body" "$AGENT_DIR"
RC=$?
if [ "$RC" -ne 0 ]; then
    echo "FAIL: success path exited $RC, expected 0"
    exit 1
fi
for f in prompt.txt output.md log.txt; do
    if [ ! -s "$AGENT_DIR/$f" ]; then
        echo "FAIL: $AGENT_DIR/$f missing or empty"
        exit 1
    fi
done
if ! grep -q '^test-prompt-body$' "$AGENT_DIR/prompt.txt"; then
    echo "FAIL: prompt.txt does not contain the prompt body"
    exit 1
fi
if ! grep -q '^stub-output-marker$' "$AGENT_DIR/output.md"; then
    echo "FAIL: output.md does not contain stubbed codex output"
    exit 1
fi
if ! grep -q 'agent=security starting' "$AGENT_DIR/log.txt"; then
    echo "FAIL: log.txt missing start marker"
    exit 1
fi
if ! grep -q 'agent=security exit=0' "$AGENT_DIR/log.txt"; then
    echo "FAIL: log.txt missing exit marker"
    exit 1
fi
if ! grep -q '^stub-stderr-marker$' "$AGENT_DIR/log.txt"; then
    echo "FAIL: codex stderr not captured into log.txt"
    exit 1
fi
# Pin assertion: the run-specialist wrapper must call codex with the
# explicit model so we don't silently ride the CLI's rolling default.
if ! grep -q '^model=gpt-5.5$' "$ARGV_LOG"; then
    echo "FAIL: codex argv missing 'model=gpt-5.5' pin (silent unpin?)"
    cat "$ARGV_LOG"
    exit 1
fi

# ---- scenario 2: codex non-zero exit propagates -------------------------
echo "  scenario 2: codex non-zero exit propagates..."
cat > "$TMPDIR/bin/codex" <<'STUB'
#!/bin/bash
exit 7
STUB

AGENT_DIR="$TMPDIR/agents/fail"
bash "$SCRIPT" "fail" "$REPO_DIR" "p" "$AGENT_DIR"
RC=$?
if [ "$RC" -ne 7 ]; then
    echo "FAIL: expected exit 7 (codex's exit), got $RC"
    exit 1
fi
if ! grep -q 'agent=fail exit=7' "$AGENT_DIR/log.txt"; then
    echo "FAIL: exit marker did not record codex's non-zero exit"
    exit 1
fi

# ---- scenario 3: empty output → exit 3 ----------------------------------
echo "  scenario 3: empty output → exit 3 even when codex itself succeeds..."
cat > "$TMPDIR/bin/codex" <<'STUB'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) OUT_FILE="$2"; shift 2 ;;
        -C|-c) shift 2 ;;
        --dangerously-bypass-approvals-and-sandbox) shift ;;
        *) shift ;;
    esac
done
: > "$OUT_FILE"
exit 0
STUB

AGENT_DIR="$TMPDIR/agents/empty"
bash "$SCRIPT" "empty" "$REPO_DIR" "p" "$AGENT_DIR"
RC=$?
if [ "$RC" -ne 3 ]; then
    echo "FAIL: expected exit 3 for empty output, got $RC"
    exit 1
fi
if ! grep -q 'produced empty output' "$AGENT_DIR/log.txt"; then
    echo "FAIL: log.txt missing empty-output marker"
    exit 1
fi

echo "  PASS (3 scenarios: success path, codex error propagates, empty output → exit 3)"
