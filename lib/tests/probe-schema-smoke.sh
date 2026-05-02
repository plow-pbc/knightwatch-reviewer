#!/usr/bin/env bash
# Asserts that probe-formatted text adheres to the contract in prompts/probe-schema.md.
# Tests probe_validate (rejects probes missing required fields) and probe_extract_field.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Fixture: a valid probe block with all required fields
FIXTURE_OK="$(cat <<'EOF'
### Probe 1
- **From:** shape
- **Class:** complexity-cost
- **Q:** Does the new defensive guard ever fire?
- **Files:** tests/test_oauth.py:120
- **If yes, edit:** keep the lifecycle simulation
- **If no, cost:** calcifies a fake-state branch tests must preserve
- **Confidence:** medium
- **Severity if yes:** low
- **Answer:** unknown
- **Evidence:** —
EOF
)"

# Fixture: missing several required fields
FIXTURE_BAD="$(cat <<'EOF'
### Probe 1
- **From:** shape
- **Q:** missing other fields
EOF
)"

# Fixture: empty input — vacuously valid (no probes to check)
FIXTURE_EMPTY=""

# Source the parser
. "$REPO_ROOT/lib/probe-parse.sh"

if probe_validate <<<"$FIXTURE_OK"; then
    echo "OK: valid probe accepted"
else
    echo "FAIL: valid probe rejected"; exit 1
fi

if ! probe_validate <<<"$FIXTURE_BAD" 2>/dev/null; then
    echo "OK: invalid probe rejected"
else
    echo "FAIL: invalid probe accepted"; exit 1
fi

if probe_validate <<<"$FIXTURE_EMPTY"; then
    echo "OK: empty input accepted (vacuously valid)"
else
    echo "FAIL: empty input rejected"; exit 1
fi

# Test probe_extract_field
EXTRACTED_FROM="$(probe_extract_field "From" <<<"$FIXTURE_OK")"
[ "$EXTRACTED_FROM" = "shape" ] || { echo "FAIL: expected From=shape, got '$EXTRACTED_FROM'"; exit 1; }
echo "OK: probe_extract_field From"

EXTRACTED_CLASS="$(probe_extract_field "Class" <<<"$FIXTURE_OK")"
[ "$EXTRACTED_CLASS" = "complexity-cost" ] || { echo "FAIL: expected Class=complexity-cost, got '$EXTRACTED_CLASS'"; exit 1; }
echo "OK: probe_extract_field Class"

echo "OK: probe-schema smoke"
