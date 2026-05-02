#!/bin/bash
# Behavior smoke for rank_hot_angles (lib/go-deep-rank.sh).
#
# Round-5 reframe: ranking is FINDING-level, not file-level. The bot
# repeatedly flagged that file-level ranking could pick a specialist
# whose calibrated finding was a low-severity nit, ahead of another
# file's correctly-calibrated blocking, just because the first file
# ALSO had an uncalibrated blocking elsewhere. This smoke fixtures
# that exact case as the load-bearing regression.

set -uo pipefail

TMPDIR=$(mktemp -d -t go-deep-rank-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/go-deep-rank.sh"

SPECIALISTS_DIR="$TMPDIR/specialists"
mkdir -p "$SPECIALISTS_DIR"

# Helper: build a layered specialist file with $angle's findings, where each
# finding has a (severity, calibrated) tuple. SPECIALIST_FINDINGS is "sev1:cal1 sev2:cal2 ..."
# e.g. "blocking:no medium:yes" → Finding 1 blocking uncalibrated, Finding 2 medium calibrated.
mk_layered() {
    local angle="$1"
    shift
    local file="$SPECIALISTS_DIR/${angle}.md"
    {
        echo "## [${angle}] findings"
        echo
        echo "### Surveyed"
        echo "- looked at code"
        local i=0
        for spec in "$@"; do
            i=$((i+1))
            local sev="${spec%%:*}"
            echo
            echo "### Finding $i — $sev"
            echo "Some finding text in app/foo.py:42."
        done
        echo
        echo "---"
        echo
        echo "## Critic counter-arguments"
        echo
        i=0
        for spec in "$@"; do
            i=$((i+1))
            local sev="${spec%%:*}"
            local cal="${spec##*:}"
            echo "### [${angle}] Finding $i — AGREE"
            echo "real bug."
            echo "**Estimated remedy LOC:** ~50 LOC across 2 files."
            if [ "$cal" = "yes" ]; then
                echo
                echo "**Calibration questions for go-deep investigation:**"
                echo "- Q1: scale firing rate?"
                echo "- Q2: existing helper?"
            fi
            echo
        done
    } > "$file"
}

# --- fixture 1: ≤3 hot — all returned in input order ---
echo "  fixture 1: 2 hot specialists → both returned in input order..."
mk_layered security medium:yes
mk_layered architecture blocking:yes
mk_layered tests low:no  # not hot — no calibration block
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests)
[ "$OUT" = "security
architecture" ] || { echo "FAIL: expected 'security\\narchitecture', got: $OUT"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 2: >3 hot, severity-band ranker by max-calibrated-severity ---
echo "  fixture 2: 4 hot specialists with mixed severities → top 3 by max-calibrated-severity..."
mk_layered security medium:yes        # max-calibrated = medium
mk_layered architecture blocking:yes  # max-calibrated = blocking
mk_layered tests medium:yes           # max-calibrated = medium
mk_layered simplification low:yes     # max-calibrated = low
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests simplification)
EXPECTED="architecture
security
tests"
[ "$OUT" = "$EXPECTED" ] || { echo "FAIL: expected '$EXPECTED', got: '$OUT'"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 3: ROUND-5 REGRESSION — uncalibrated blocking + calibrated nit must NOT outrank a calibrated medium elsewhere ---
echo "  fixture 3: round-5 regression — file-level ranker would mis-pick the blocking-w/-uncalibrated-blocking file..."
# security.md: Finding 1 blocking uncalibrated + Finding 2 nit calibrated → max-calibrated = NIT
mk_layered security blocking:no nit:yes
# architecture.md: Finding 1 medium calibrated → max-calibrated = MEDIUM
mk_layered architecture medium:yes
# tests.md: Finding 1 low calibrated → max-calibrated = LOW
mk_layered tests low:yes
# simplification.md: Finding 1 nit calibrated → max-calibrated = NIT
mk_layered simplification nit:yes
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests simplification)
# Expected ordering: architecture (medium) → tests (low) → security/simplification (nit).
# Within the nit band, the tiebreak is CALLER ORDER. Caller passes
# `security` BEFORE `simplification` here, so security wins the third
# slot. Round-8 F2 noted: this fixture happens to be ambiguous because
# alphabetical also picks `security`; see fixture 3b below for a case
# that uniquely fences caller-order.
# A file-level ranker would put security FIRST (because it has a
# [blocking] header somewhere) — that's the bug fixture 3 catches.
EXPECTED="architecture
tests
security"
[ "$OUT" = "$EXPECTED" ] || {
    echo "FAIL: round-5 regression — expected '$EXPECTED' (max-calibrated-severity ranking), got: '$OUT'"
    echo "If 'security' comes first, the ranker is still file-level (matches uncalibrated [blocking] severity)."
    exit 1
}

# --- fixture 3b: caller-order tiebreak distinguishes from alphabetical ---
# Round-8 F2 regression: pass `simplification` BEFORE `security`. With
# caller order, simplification wins the third slot. With alphabetical,
# security would. The contract is caller order, so simplification first.
echo "  fixture 3b: round-8 regression — caller-order tiebreak (not alphabetical)..."
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" simplification security architecture tests)
# Same severity scoring, but caller order is now: simplification, security, architecture, tests.
# Bands: architecture (medium), tests (low), then nits in caller order
# from `hot[]` which preserved input order: simplification, security.
# Top 3: architecture, tests, simplification. (security drops off; alphabetical would have picked it.)
EXPECTED_3B="architecture
tests
simplification"
[ "$OUT" = "$EXPECTED_3B" ] || {
    echo "FAIL: round-8 F2 regression — expected '$EXPECTED_3B' (caller order, simplification picked over security)"
    echo "If 'security' is in the output instead of 'simplification', the tiebreak silently regressed to alphabetical."
    echo "Got: '$OUT'"
    exit 1
}

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 4: zero hot → empty output ---
echo "  fixture 4: zero hot specialists → empty output..."
mk_layered security medium:no
mk_layered architecture blocking:no
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture)
[ -z "$OUT" ] || { echo "FAIL: expected empty, got: '$OUT'"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 5: aggregator-bracketed [blocking] format does NOT count as specialist severity ---
echo "  fixture 5: aggregator-bracketed [blocking] in commentary does NOT match specialist contract..."
cat > "$SPECIALISTS_DIR/security.md" <<'EOF'
## [security] findings

### Surveyed
- looked at it.

(prior aggregator review at [blocking] severity is unrelated.)

---

## Critic counter-arguments

### [security] Finding 1 — AGREE
filler

**Calibration questions for go-deep investigation:**
- Q1: filler
EOF
mk_layered architecture blocking:yes
mk_layered tests medium:yes
mk_layered simplification low:yes
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests simplification)
# security has no specialist-format `### Finding N — <severity>` header → falls
# through severity bands → drops out. Other three sort by max-calibrated.
EXPECTED="architecture
tests
simplification"
[ "$OUT" = "$EXPECTED" ] || {
    echo "FAIL: bracketed [blocking] in prose should NOT match specialist contract; expected '$EXPECTED', got: '$OUT'"
    exit 1
}

echo "  PASS"
