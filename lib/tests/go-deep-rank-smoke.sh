#!/bin/bash
# Behavior smoke for rank_hot_angles (lib/go-deep-rank.sh).
#
# Token-grep on the orchestrator regex passes even when selection logic
# is broken — the round-1 PR #42 finding was exactly that case (regex
# matched the wrong format, hot-list silently emptied). This smoke
# exercises the selection logic with real specialist-file fixtures.
#
# Contracts:
#   1. ≤3 hot angles → all returned in input order.
#   2. >3 hot angles → severity-band rank ([blocking] > [medium] > [low] > [nit]),
#      capped at 3, alphabetical tiebreak within band.
#   3. Severity matched against specialist contract
#      "### Finding N — <severity>" (NOT bracketed [severity]).
#   4. No "Calibration questions for go-deep" token → not hot,
#      regardless of severity.

set -uo pipefail

TMPDIR=$(mktemp -d -t go-deep-rank-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/go-deep-rank.sh"

SPECIALISTS_DIR="$TMPDIR/specialists"
mkdir -p "$SPECIALISTS_DIR"

mk_file() {
    local angle="$1" severity="$2" calibration="$3"
    cat > "$SPECIALISTS_DIR/${angle}.md" <<EOF
## [${angle}] findings

### Finding 1 — ${severity}
something happened in app/foo.py:42.

---

## Critic counter-arguments

### [${angle}] Finding 1 — AGREE
real bug.
**Estimated remedy LOC:** ~50 LOC across 2 files.
EOF
    if [ "$calibration" = "yes" ]; then
        cat >> "$SPECIALISTS_DIR/${angle}.md" <<'EOF'

**Calibration questions for go-deep investigation:**
- Q1: Does this fire at our scale?
- Q2: Is there an existing helper?
EOF
    fi
}

# --- fixture 1: ≤3 hot → all returned ---
echo "  fixture 1: 2 hot specialists → both returned in input order..."
mk_file security medium yes
mk_file architecture blocking yes
mk_file tests low no    # not hot — no calibration block
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests)
[ "$OUT" = "security
architecture" ] || { echo "FAIL: expected 'security\\narchitecture', got: $OUT"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 2: >3 hot, severity-band ranker (the round-1 regression case) ---
echo "  fixture 2: 4 hot specialists with mixed severities → top 3 by severity..."
mk_file security medium yes      # hot, medium
mk_file architecture blocking yes # hot, blocking
mk_file tests medium yes          # hot, medium
mk_file simplification low yes    # hot, low
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests simplification)
# Expected: architecture (blocking), then alphabetical within medium band
# (security, tests), capped at 3. simplification (low) drops off.
EXPECTED="architecture
security
tests"
[ "$OUT" = "$EXPECTED" ] || { echo "FAIL: expected '$EXPECTED', got: '$OUT'"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 3: regression fence — bracketed [severity] format MUST NOT match ---
echo "  fixture 3: aggregator-bracketed [blocking] format does NOT count as specialist severity..."
# Synthesize a file that has "[blocking]" (aggregator format) but NO
# "### Finding N — blocking" (specialist format). Round-1 bug would
# treat this as blocking; the fix should treat it as no-severity-found.
cat > "$SPECIALISTS_DIR/security.md" <<'EOF'
## [security] findings

### Surveyed
- looked at it.

(no findings — the prior aggregator review at [blocking] is unrelated to this round)

---

**Calibration questions for go-deep investigation:**
- Q1: filler
EOF
mk_file architecture blocking yes
mk_file tests medium yes
mk_file simplification low yes
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture tests simplification)
# security has no specialist-format severity → falls through all bands → drops out.
# architecture (blocking) + tests (medium) + simplification (low) → 3 hot, ≤3 path,
# returned in input order.
# But wait — this is >3 hot (4 candidates); only 3 of them have a real specialist
# severity. The ranker walks bands and picks any with severity. Let's trace:
#   blocking band: architecture matches → ranked=[architecture]
#   medium band: tests matches → ranked=[architecture, tests]
#   low band: simplification matches → ranked=[architecture, tests, simplification]
#   nit band: nothing matches
# Result: architecture, tests, simplification. security drops because the
# bracketed [blocking] in its file doesn't satisfy the specialist regex.
EXPECTED="architecture
tests
simplification"
[ "$OUT" = "$EXPECTED" ] || { echo "FAIL: expected '$EXPECTED', got: '$OUT' (round-1 regression: bracketed [blocking] should NOT match specialist contract)"; exit 1; }

rm -f "$SPECIALISTS_DIR"/*.md

# --- fixture 4: zero hot → empty output ---
echo "  fixture 4: zero hot specialists → empty output..."
mk_file security medium no
mk_file architecture blocking no
OUT=$(rank_hot_angles "$SPECIALISTS_DIR" security architecture)
[ -z "$OUT" ] || { echo "FAIL: expected empty, got: '$OUT'"; exit 1; }

echo "  PASS"
