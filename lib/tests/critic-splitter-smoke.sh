#!/usr/bin/env bash
# Smoke for split_critic_to_specialists (lib/critic-splitter.sh).
#
# Contracts:
#   1. Per-angle [<angle>] sections in critic.md are appended to the
#      corresponding specialists/<angle>.md file under a "## Critic
#      counter-arguments" H2 (so the layered file flows specialist-then-critic).
#   2. The "## Missed findings" section is NOT written to a separate
#      specialists/missed.md sink — the aggregator reads missed findings
#      directly from critic.md, so a sink with no runtime reader was
#      dead surface. Smoke asserts the absence below.
#   3. Missing specialist file for a section that the critic produced
#      is fail-loud: function returns non-zero at first miss. The
#      orchestrator aborts the review on this and rm -rf's REPO_DIR,
#      so partial state from earlier splits in the same pass is
#      unreachable downstream. R13 fixed the silent drop; R14 dropped
#      the missing-target counter (since partial state was unreachable
#      anyway). The smoke fixture below uses an `[architecture]` valid
#      target before the bad `[removed-angle]` target — both R13's
#      "valid splits before the failure point" assertion and R14's
#      "any miss returns nonzero" assertion are exercised.
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
RC=$?
# Pin rc=0 on the success path. orchestrate.sh:run_specialist_pipeline
# treats any non-zero from split_critic_to_specialists as fail-loud abort
# (R13/R14); a regression that returned non-zero while still writing
# partial side effects would be silently green here without this check.
if [ "$RC" -ne 0 ]; then
    echo "FAIL: probe-format split returned rc=$RC, expected 0"
    cat "$TMPDIR/stderr2.log"
    exit 1
fi

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

# Write-failure path: R22 F#1 added `|| return 1` to the awk + target
# rewrite paths so the function fails loud on disk-full / EPERM /
# read-only-target instead of returning 0 with partial state. Exercise
# the Pass-2 rewrite failure by making the target file un-writable +
# the parent dir un-writable so the redirect can't replace the file.
# A non-zero rc is the contract; any green path here means production
# would silently post a review with dropped probe resolutions.
echo "  asserting write-failure on Pass-2 rewrite returns non-zero..."
RO_DIR="$TMPDIR/specialists-readonly"
mkdir -p "$RO_DIR"
# Stage one valid specialist target + a critic probe targeting it.
cat > "$RO_DIR/security.md" <<'EOF'
- security probe content
EOF
RO_CRITIC="$TMPDIR/critic-readonly.md"
cat > "$RO_CRITIC" <<'EOF'
## Resolved probes

### [from: security] Probe 1
- **Answer:** yes
- **Evidence:** test
EOF
chmod 555 "$RO_DIR"  # make dir un-writable so redirect can't replace files
split_critic_to_specialists "$RO_CRITIC" "$RO_DIR" 2>"$TMPDIR/stderr-readonly.log"
RO_RC=$?
chmod 755 "$RO_DIR"  # restore for cleanup
if [ "$RO_RC" -eq 0 ]; then
    echo "FAIL: split returned 0 with read-only target dir — write failure should return non-zero (R22 F#1 regression)"
    cat "$TMPDIR/stderr-readonly.log"
    exit 1
fi

# Probe-contract gate (R35 F#1): critic output that is byte-non-empty
# but contains no real probe blocks must fail loud. Whitespace-only
# `## Generated probes` writes a non-empty critic.md via awk's
# `print > out_file`; the prior `[ -s ... ]` gate let that pass and
# aggregation proceeded with no critic resolution, leaving real probes
# stuck on Answer: unknown.
echo "  asserting whitespace-only ## Generated probes returns non-zero..."
WS_DIR="$TMPDIR/specialists-ws"
mkdir -p "$WS_DIR"
# Stage minimal valid specialist files so the gate is the only trigger.
for angle in security shape; do
    echo "## $angle stub" > "$WS_DIR/$angle.md"
done
WS_CRITIC="$TMPDIR/critic-whitespace.md"
cat > "$WS_CRITIC" <<'CRITIC_WS'
## Resolved probes

## Generated probes


CRITIC_WS
split_critic_to_specialists "$WS_CRITIC" "$WS_DIR" 2>"$TMPDIR/stderr-ws.log"
WS_RC=$?
if [ "$WS_RC" -eq 0 ]; then
    echo "FAIL: split returned 0 for critic with whitespace-only ## Generated probes — gate must require actual probe content (R35 F#1)"
    cat "$TMPDIR/stderr-ws.log"
    exit 1
fi

# No-probes sentinel (R36 #1): when all specialists return No probes.
# AND the critic generates nothing, the prompt instructs `No probes.`
# as the whole critic output. Splitter must accept that as valid
# empty-critic so aggregation proceeds; without this carve-out, the
# meaningful-empty gate would abort an all-clean review.
echo "  asserting 'No probes.' sentinel passes the empty-critic gate..."
SENTINEL_DIR="$TMPDIR/specialists-sentinel"
mkdir -p "$SENTINEL_DIR"
for angle in security shape; do
    echo "## $angle stub" > "$SENTINEL_DIR/$angle.md"
done
SENTINEL_CRITIC="$TMPDIR/critic-sentinel.md"
printf 'No probes.\n' > "$SENTINEL_CRITIC"
split_critic_to_specialists "$SENTINEL_CRITIC" "$SENTINEL_DIR" 2>"$TMPDIR/stderr-sentinel.log"
SENTINEL_RC=$?
if [ "$SENTINEL_RC" -ne 0 ]; then
    echo "FAIL: split returned non-zero for 'No probes.' sentinel — clean-empty critic must pass (R36 #1)"
    cat "$TMPDIR/stderr-sentinel.log"
    exit 1
fi

echo "  PASS"
