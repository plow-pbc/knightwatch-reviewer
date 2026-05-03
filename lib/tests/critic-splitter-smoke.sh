#!/usr/bin/env bash
# Smoke for split_critic_to_specialists (lib/critic-splitter.sh).
#
# Contracts:
#   1. Per-angle [<angle>] sections in critic.md are appended to the
#      corresponding specialists/<angle>.md file under a "## Critic
#      counter-arguments" H2 (so the layered file flows specialist-then-critic).
#   2. The "## Missed findings" section from critic.md is preserved
#      and written to specialists/missed.md.
#   3. Missing specialist file for a section that the critic produced
#      is fail-loud: function returns non-zero, valid per-angle splits
#      still happen on the way through (so we can assert them), but the
#      orchestrator aborts the review on the non-zero return rather
#      than silently dropping the critic resolution. R13 finding —
#      previous fail-soft behavior demoted resolved blockers.
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
SPLIT_RC=$?
if [ "$SPLIT_RC" -eq 0 ]; then
    echo "FAIL: split_critic_to_specialists returned 0 with a missing-target [removed-angle] section — should fail-loud"
    cat "$TMPDIR/stderr.log"
    exit 1
fi

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

echo "  asserting missed findings stay in critic.md (no separate sink)..."
# Round-5 finding: specialists/missed.md was a sink with no runtime
# reader (the aggregator reads missed findings from critic.md directly).
# After dropping the sink, the file should NOT exist.
[ ! -e "$SPECIALISTS_DIR/missed.md" ] || {
    echo "FAIL: critic-splitter still writing missed.md (sink should be dropped — the aggregator reads from critic.md)"
    exit 1
}

echo "  asserting fail-loud message on missing specialist file..."
grep -qF "removed-angle" "$TMPDIR/stderr.log" || {
    echo "FAIL: missing-specialist message not emitted on stderr"
    cat "$TMPDIR/stderr.log"
    exit 1
}
grep -qF "fail-loud" "$TMPDIR/stderr.log" || {
    echo "FAIL: stderr should mention fail-loud (not fail-soft warn)"
    cat "$TMPDIR/stderr.log"
    exit 1
}
[ ! -f "$SPECIALISTS_DIR/removed-angle.md" ] || {
    echo "FAIL: should not have created specialists/removed-angle.md"
    exit 1
}

echo "  asserting probe-format critic resolution routes to per-angle file..."
PROBE_CRITIC="$TMPDIR/probe-critic.md"
cat > "$PROBE_CRITIC" <<'EOF'
## Resolved probes

### [from: shape] Probe 1
- **Answer:** yes
- **Evidence:** grep showed two callsites in app/handlers.py
- **Severity if yes:** blocking

### [from: simplification] Probe 1
- **Answer:** unknown
- **Evidence:** could not confirm whether the helper has a third caller

## Generated probes

### Probe 1
- **From:** critic
- **Class:** complexity-cost
- **Q:** Is the new error envelope necessary at our operating point?
- **Files:** app/api.py:30
- **If yes, edit:** keep
- **If no, cost:** calcifies a wrap-once-then-wrap layer
- **Confidence:** medium
- **Severity if yes:** low
- **Answer:** unknown
- **Evidence:** —
EOF

# Pre-stage the specialists for the probe pass
mkdir -p "$TMPDIR/specialists2"
cat > "$TMPDIR/specialists2/shape.md" <<'EOF'
### Probe 1
- **From:** shape
- **Class:** bypass
- **Q:** Does the diff sidestep Config.load?
EOF
cat > "$TMPDIR/specialists2/simplification.md" <<'EOF'
### Probe 1
- **From:** simplification
- **Class:** DRY
- **Q:** Three near-identical helpers in this PR?
EOF

split_critic_to_specialists "$PROBE_CRITIC" "$TMPDIR/specialists2" 2>"$TMPDIR/stderr2.log"

grep -qF "Answer:** yes" "$TMPDIR/specialists2/shape.md" || {
    echo "FAIL: probe resolution not routed to shape.md"
    cat "$TMPDIR/specialists2/shape.md"
    exit 1
}
grep -qF "Answer:** unknown" "$TMPDIR/specialists2/simplification.md" || {
    echo "FAIL: probe resolution not routed to simplification.md"
    cat "$TMPDIR/specialists2/simplification.md"
    exit 1
}
[ -s "$TMPDIR/specialists2/critic.md" ] || {
    echo "FAIL: generated probes not routed to specialists/critic.md"
    exit 1
}
grep -qF "From:** critic" "$TMPDIR/specialists2/critic.md" || {
    echo "FAIL: generated probe missing 'From: critic' marker"
    cat "$TMPDIR/specialists2/critic.md"
    exit 1
}

echo "  PASS"
