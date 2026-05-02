#!/bin/bash
# Smoke for split_critic_to_specialists (lib/critic-splitter.sh).
#
# Contracts:
#   1. Per-angle [<angle>] sections in critic.md are appended to the
#      corresponding specialists/<angle>.md file under a "## Critic
#      counter-arguments" H2 (so the layered file flows specialist-then-critic).
#   2. The "## Missed findings" section from critic.md is preserved
#      and written to specialists/missed.md.
#   3. Missing specialist file for a section that the critic produced is
#      a fail-soft warn (log line; don't abort) — handles a future angle
#      removed without prompt sync.
#   4. Each specialists/<angle>.md keeps its original content UNCHANGED
#      ahead of the critic block (specialist's own findings preserved).

set -uo pipefail

TMPDIR=$(mktemp -d -t critic-splitter-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/critic-splitter.sh"

SPECIALISTS_DIR="$TMPDIR/specialists"
mkdir -p "$SPECIALISTS_DIR"

# --- fixture: synthesize specialist files ---
cat > "$SPECIALISTS_DIR/security.md" <<'EOF'
## [security] findings

### Surveyed
- looked at auth code
### Finding 1 — medium
sql injection in `app/api.py:42`.
EOF
cat > "$SPECIALISTS_DIR/architecture.md" <<'EOF'
## [architecture] findings

### Surveyed
- nothing notable
EOF

# --- fixture: synthesize critic.md ---
CRITIC="$TMPDIR/critic.md"
cat > "$CRITIC" <<'EOF'
## Critic counterarguments

### [security] Finding 1 — AGREE
Real injection, fix is bind-param.
**Estimated remedy LOC:** ~5 LOC across 1 file.

### [architecture] Finding 1 — REFRAME-AS-QUESTION
Specialist found nothing structural; the diff is small enough.

### [removed-angle] Finding 1 — AGREE
Some other thing — the specialist file was removed though.

## Missed findings (if any)
- [low] missing CSP header.
EOF

split_critic_to_specialists "$CRITIC" "$SPECIALISTS_DIR" 2>"$TMPDIR/stderr.log"

echo "  asserting critic block appended to security.md..."
grep -qF "## Critic counter-arguments" "$SPECIALISTS_DIR/security.md" || {
    echo "FAIL: missing '## Critic counter-arguments' H2 in security.md"
    cat "$SPECIALISTS_DIR/security.md"
    exit 1
}
grep -qF "Real injection" "$SPECIALISTS_DIR/security.md" || {
    echo "FAIL: critic content not appended to security.md"
    cat "$SPECIALISTS_DIR/security.md"
    exit 1
}
grep -qF "Estimated remedy LOC" "$SPECIALISTS_DIR/security.md" || {
    echo "FAIL: remedy-LOC line not preserved in security.md"
    exit 1
}

echo "  asserting original specialist content preserved in security.md..."
grep -qF "## [security] findings" "$SPECIALISTS_DIR/security.md" || {
    echo "FAIL: original specialist content lost in security.md"
    exit 1
}
grep -qF "sql injection in" "$SPECIALISTS_DIR/security.md" || {
    echo "FAIL: original Finding 1 content dropped"
    exit 1
}

echo "  asserting REFRAME critic block on architecture.md..."
grep -qF "REFRAME-AS-QUESTION" "$SPECIALISTS_DIR/architecture.md" || {
    echo "FAIL: REFRAME not appended to architecture.md"
    cat "$SPECIALISTS_DIR/architecture.md"
    exit 1
}

echo "  asserting missed findings written to specialists/missed.md..."
grep -qF "missing CSP" "$SPECIALISTS_DIR/missed.md" || {
    echo "FAIL: missed findings not captured"
    [ -f "$SPECIALISTS_DIR/missed.md" ] && cat "$SPECIALISTS_DIR/missed.md"
    exit 1
}

echo "  asserting fail-soft warn on missing specialist file..."
grep -qF "removed-angle" "$TMPDIR/stderr.log" || {
    echo "FAIL: missing-specialist warn not emitted on stderr"
    cat "$TMPDIR/stderr.log"
    exit 1
}
[ ! -f "$SPECIALISTS_DIR/removed-angle.md" ] || {
    echo "FAIL: should not have created specialists/removed-angle.md"
    exit 1
}

echo "  PASS"
