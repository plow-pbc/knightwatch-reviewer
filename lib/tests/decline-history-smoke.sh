#!/usr/bin/env bash
# Smoke for fetch_decline_history (lib/decline-history.sh).
#
# Pure-transform helper _decline_history_from_json drives the test;
# real gh calls are out of scope (the smoke runs without network).
#
# Round-8 reframe contracts (post-classifier-collapse):
#   1. Empty JSON array → "(no decline history)" sentinel.
#   2. All operator-authored, non-bot replies emit VERBATIM under one
#      neutral `## Operator replies` heading — no decline-vs-counter
#      regex split, no class extraction, no class-count buckets. The
#      critic reads them as prose and judges decline / counter / context
#      per its own rules.
#   3. Bot auto-posts (signed as the operator) excluded by HTML marker.
#   4. Non-operator replies ignored.
#   5. Explicit `<!-- decline:class=X -->` markers are counted in the
#      "Explicit class markers" section. THIS is what the critic's
#      ≥3-rounds-auto-drop rule consumes; implicit classes are left to
#      the critic's prose-judgement.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$PROJECT_ROOT/lib/decline-history.sh"

# --- fixture 1: empty comments → sentinel ---
echo "  fixture 1: empty comments → sentinel..."
EMPTY_OUT=$(_decline_history_from_json '[]')
echo "$EMPTY_OUT" | grep -qF "(no decline history)" || {
    echo "FAIL: empty case did not emit sentinel"
    echo "got: $EMPTY_OUT"
    exit 1
}

# --- fixture 2: replies emitted as context (no class buckets) ---
echo "  fixture 2: decline replies emitted verbatim as context..."
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
# All operator replies — both declines AND the counter-proposed — emit
# verbatim under one neutral `## Operator replies` heading. The round-8
# simplification dropped the decline-vs-counter regex split; the critic
# now reads each reply as prose and judges its shape.
echo "$OUT" | grep -qF "documented design intent" || { echo "FAIL: first decline body missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "Documented in tests; not changing" || { echo "FAIL: second decline body missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "Removed the redundant validation" || { echo "FAIL: counter-proposed body missing from Operator replies"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "## Operator replies" || { echo "FAIL: neutral Operator replies H2 missing"; echo "$OUT"; exit 1; }
# Non-operator excluded
echo "$OUT" | grep -qF "some-bot" && { echo "FAIL: non-operator reply leaked into output"; exit 1; } || true
# CRITICAL: no class buckets emitted (round-5 architectural reframe).
# Old "## Class: X (declined N rounds)" header must not appear; nor should
# the obsolete "## Decline replies" or "## Counter-proposed" H2s (round-8).
if echo "$OUT" | grep -qE '^## Class: [a-z]'; then
    echo "FAIL: classifier output detected — should be removed in round-5 reframe"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -qF "## Decline replies" && { echo "FAIL: obsolete Decline replies H2 — round-8 collapsed into Operator replies"; exit 1; } || true
echo "$OUT" | grep -qF "## Counter-proposed" && { echo "FAIL: obsolete Counter-proposed H2 — round-8 collapsed into Operator replies"; exit 1; } || true
# Explicit class markers section present, declaring no markers (none in fixture).
echo "$OUT" | grep -qF "Explicit class markers" || { echo "FAIL: explicit-markers section missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "operator has not declared any explicit" || { echo "FAIL: empty-markers sentinel missing"; echo "$OUT"; exit 1; }

# --- fixture 3: bot auto-posts excluded by HTML marker ---
echo "  fixture 3: bot auto-posts excluded by HTML marker..."
BOT_ECHO=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-05-01T08:00:00Z","body":"<!-- knightwatch-reviewer:auto-post -->\n## Findings\n1. [blocking] Declined — bot's own review body mentioning 'Declined' in finding prose."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T08:30:00Z","body":"Declined — operator's actual decline."}
]
JSON
)
OUT=$(_decline_history_from_json "$BOT_ECHO")
echo "$OUT" | grep -qF "operator's actual decline" || { echo "FAIL: operator decline missed"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qF "bot's own review body" && { echo "FAIL: bot auto-post leaked through marker filter"; exit 1; } || true

# --- fixture 4: explicit class markers counted in their own section ---
echo "  fixture 4: explicit <!-- decline:class=X --> markers counted..."
WITH_MARKERS=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-04-30T12:00:00Z","body":"Declined — same session race we discussed before. <!-- decline:class=session-scoping --> Not changing."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T08:00:00Z","body":"Declined again. <!-- decline:class=session-scoping --> Documented in tests."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T09:00:00Z","body":"Declined this time too. <!-- decline:class=session-scoping --> Spec'd as intent."},
  {"user":{"login":"srosro"},"created_at":"2026-05-01T10:00:00Z","body":"Declined — different class. <!-- decline:class=stale-auth-error --> Edge case for 10 users."}
]
JSON
)
OUT=$(_decline_history_from_json "$WITH_MARKERS")
echo "$OUT" | grep -qE '\*\*`session-scoping`\*\*: 3 rounds' || { echo "FAIL: session-scoping count missing or wrong"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qE '\*\*`stale-auth-error`\*\*: 1 round' || { echo "FAIL: stale-auth-error count missing or wrong"; echo "$OUT"; exit 1; }

# --- fixture 4b: marker-only reply emits class count even without Declined/BCR prose ---
# Round-7 F5 regression: the empty-history sentinel short-circuited before
# explicit_classes was rendered. A reply body that contains just a marker
# (no "Declined" / "[Bug-Class-Recurrence]" / "Counter-proposed" prose)
# would lose its only signal.
echo "  fixture 4b: marker-only reply still emits class count (round-7 F5)..."
MARKER_ONLY=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-05-01T11:00:00Z","body":"Quick note: <!-- decline:class=session-scoping --> not changing this round either."}
]
JSON
)
OUT=$(_decline_history_from_json "$MARKER_ONLY")
echo "$OUT" | grep -qF "(no decline history)" && {
    echo "FAIL: marker-only reply hit empty-history sentinel — explicit_classes was ignored"
    echo "$OUT"
    exit 1
} || true
echo "$OUT" | grep -qE '\*\*`session-scoping`\*\*: 1 round' || {
    echo "FAIL: marker-only reply did not emit explicit-class count"
    echo "$OUT"
    exit 1
}

# --- fixture 5: BCR-prose-only reply emits as context (no auto-classify) ---
echo "  fixture 5: BCR-shaped prose without explicit marker stays as context..."
BCR_PROSE=$(cat <<'JSON'
[
  {"user":{"login":"srosro"},"created_at":"2026-05-01T11:00:00Z","body":"[Bug-Class-Recurrence] This is the 3rd instance of dispatch-routing — bot prose, no marker."}
]
JSON
)
OUT=$(_decline_history_from_json "$BCR_PROSE")
# Body is preserved as context
echo "$OUT" | grep -qF "dispatch-routing" || { echo "FAIL: BCR body not preserved as context"; echo "$OUT"; exit 1; }
# But NOT counted as a class (no explicit marker)
echo "$OUT" | grep -qE '\*\*`dispatch-routing`\*\*' && { echo "FAIL: BCR prose was auto-classified despite no explicit marker (round-5 reframe should leave class-counting to explicit markers only)"; exit 1; } || true
echo "$OUT" | grep -qF "operator has not declared any explicit" || { echo "FAIL: explicit-markers empty sentinel missing"; echo "$OUT"; exit 1; }

echo "  PASS"
