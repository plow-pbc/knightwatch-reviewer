#!/bin/bash
# Smoke for fetch_decline_history (lib/decline-history.sh).
#
# Pure-transform helper _decline_history_from_json drives the test;
# real gh calls are out of scope (the smoke runs without network).
#
# Contracts:
#   1. Empty JSON array → emits "(no decline history)" sentinel.
#   2. Operator (srosro) decline replies are extracted, classified, and
#      counted; class header includes "declined N round(s)" with the
#      first/last decline timestamps.
#   3. Counter-proposed replies are captured under their own H2 (operator
#      applied a LOC-negative version — useful signal for the critic).
#   4. Non-operator replies are ignored.
#   5. Free-form pushback that doesn't match a known class falls back to
#      "(unclassified)" rather than dropping the signal.

set -uo pipefail

TMPDIR=$(mktemp -d -t decline-history-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/decline-history.sh"

# --- fixture 1: empty comments ---
echo "  fixture 1: empty comments → sentinel..."
EMPTY_OUT=$(_decline_history_from_json '[]')
echo "$EMPTY_OUT" | grep -qF "(no decline history)" || {
    echo "FAIL: empty case did not emit sentinel"
    echo "got: $EMPTY_OUT"
    exit 1
}

# --- fixture 2: classified declines + counter-proposed + non-operator noise ---
echo "  fixture 2: classified declines + counter-proposed + non-operator noise..."
SAMPLE=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-04-30T12:00:00Z","body":"Declined — conflicts with Fail-Fast in standards.md. The session-scoping finding is documented design intent (testFinishKeepsLaunchPhaseLaunching)."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T08:00:00Z","body":"Declined again — same session-scoping. Documented in tests; not changing without spec."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T10:00:00Z","body":"Counter-proposed — applied LOC-negative version. Removed the redundant validation."},
  {"user":{"login":"some-bot"},"created_at":"2026-05-01T10:30:00Z","body":"Declined — bot's own reply, should be ignored."}
]
JSON
)

OUT=$(_decline_history_from_json "$SAMPLE")
echo "$OUT" | grep -qF "session-scoping" || { echo "FAIL: missing session-scoping class"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "declined 2 rounds" || { echo "FAIL: missing 2-round count"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "Counter-proposed" || { echo "FAIL: missing Counter-proposed entry"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "some-bot" && { echo "FAIL: non-operator reply leaked into output"; echo "$OUT"; exit 1; } || true

# --- fixture 3: free-form pushback → "(unclassified)" ---
echo "  fixture 3: free-form pushback → unclassified..."
FREEFORM=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-04-29T10:00:00Z","body":"Declined - I don't think this is worth doing right now."}
]
JSON
)
OUT=$(_decline_history_from_json "$FREEFORM")
echo "$OUT" | grep -qF "(unclassified)" || { echo "FAIL: free-form pushback did not classify as unclassified"; echo "$OUT"; exit 1; }

echo "  PASS"
