#!/bin/bash
# Smoke test for lib/prompt-build.sh.
#
# Verifies:
#   - All six placeholders ({{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
#     {{SPECIALIST_NAME}}, {{PR_AUTHOR}}, {{OPERATOR_NAME}}) substitute
#     correctly.
#   - No unsubstituted {{...}} markers remain in build_specialist_prompt output.
#   - sed-special chars in inputs are escaped, not interpreted.
#   - Placeholders inside the ANGLE FILE (not just common-header) are
#     substituted by build_specialist_prompt. This covers the case where a
#     non-common-header prompt uses placeholders directly in its body
#     (e.g. prompts/intent.md uses {{PR_AUTHOR}} in its template line).
#   - substitute_placeholders works standalone (used by the intent step,
#     which deliberately bypasses common-header).
#   - {{OPERATOR_NAME}} reads from the OPERATOR_NAME env var (default
#     "Sam"); a forked install can re-skin the bot's voice by exporting
#     a different value before invoking the worker.

set -euo pipefail

TMPDIR=$(mktemp -d -t prompt-build-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock the common-header that build_specialist_prompt expects at
# $HOME/.pr-reviewer/prompts/common-header.md, by overriding $HOME.
export HOME="$TMPDIR"
mkdir -p "$HOME/.pr-reviewer/prompts"
cat > "$HOME/.pr-reviewer/prompts/common-header.md" <<'EOF'
PR: {{PR_ID}}
Title: {{PR_TITLE}}
URL: {{PR_URL}}
Specialist: {{SPECIALIST_NAME}}
Author: {{PR_AUTHOR}}
Operator: {{OPERATOR_NAME}}
EOF

ANGLE_FILE="$TMPDIR/angle.md"
cat > "$ANGLE_FILE" <<'EOF'
Angle: focus on X
Author handle in angle: @{{PR_AUTHOR}}
PR id in angle: {{PR_ID}}
Operator handle in angle: {{OPERATOR_NAME}}
EOF

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_DIR/prompt-build.sh"

OUTPUT=$(build_specialist_prompt \
    "security" \
    "$ANGLE_FILE" \
    "owner/repo#42" \
    "Add caching to /api/foo" \
    "https://github.com/owner/repo/pull/42" \
    "plucas")

echo "  asserting all six placeholders substituted in common-header (default OPERATOR_NAME=Sam)..."
for pair in "PR: owner/repo#42" "Title: Add caching to /api/foo" \
            "URL: https://github.com/owner/repo/pull/42" \
            "Specialist: security" "Author: plucas" "Operator: Sam" \
            "Angle: focus on X"; do
    if ! echo "$OUTPUT" | grep -qF "$pair"; then
        echo "FAIL: expected '$pair' in output"
        echo "--- output ---"
        echo "$OUTPUT"
        exit 1
    fi
done

echo "  asserting placeholders in the ANGLE file are also substituted..."
for pair in "Author handle in angle: @plucas" \
            "PR id in angle: owner/repo#42" \
            "Operator handle in angle: Sam"; do
    if ! echo "$OUTPUT" | grep -qF "$pair"; then
        echo "FAIL: angle-file placeholder not substituted: '$pair'"
        echo "--- output ---"
        echo "$OUTPUT"
        exit 1
    fi
done

echo "  asserting no unsubstituted {{...}} markers..."
if echo "$OUTPUT" | grep -q '{{[^}]*}}'; then
    echo "FAIL: unsubstituted placeholder in output"
    echo "$OUTPUT" | grep '{{[^}]*}}'
    exit 1
fi

echo "  asserting sed-special chars in inputs are escaped..."
TRICKY_OUTPUT=$(build_specialist_prompt \
    "tests" "$ANGLE_FILE" \
    "owner/repo#1" "Title with & ampersand and | pipe and \\backslash" \
    "https://example.com" "user|name")

if ! echo "$TRICKY_OUTPUT" | grep -qF "Title with & ampersand and | pipe and \\backslash"; then
    echo "FAIL: tricky title not preserved verbatim"
    echo "--- output ---"
    echo "$TRICKY_OUTPUT"
    exit 1
fi

echo "  asserting substitute_placeholders works standalone (no common-header)..."
STANDALONE_PROMPT="$TMPDIR/standalone.md"
cat > "$STANDALONE_PROMPT" <<'EOF'
PR: {{PR_ID}}
Author: @{{PR_AUTHOR}}
Title: {{PR_TITLE}}
EOF
STANDALONE_OUTPUT=$(substitute_placeholders \
    "$STANDALONE_PROMPT" \
    "owner/repo#7" "Standalone title" "https://example.com/7" "alice")
for pair in "PR: owner/repo#7" "Author: @alice" "Title: Standalone title"; do
    if ! echo "$STANDALONE_OUTPUT" | grep -qF "$pair"; then
        echo "FAIL: standalone substitute_placeholders missing '$pair'"
        echo "--- output ---"
        echo "$STANDALONE_OUTPUT"
        exit 1
    fi
done
if echo "$STANDALONE_OUTPUT" | grep -q '{{[^}]*}}'; then
    echo "FAIL: standalone output has unsubstituted placeholder"
    echo "$STANDALONE_OUTPUT" | grep '{{[^}]*}}'
    exit 1
fi
# substitute_placeholders alone should NOT prepend common-header content.
if echo "$STANDALONE_OUTPUT" | grep -q "Specialist:"; then
    echo "FAIL: substitute_placeholders unexpectedly included common-header content"
    echo "$STANDALONE_OUTPUT"
    exit 1
fi

echo "  asserting OPERATOR_NAME env override flows through (forked-install voice re-skin)..."
OVERRIDE_PROMPT="$TMPDIR/override.md"
cat > "$OVERRIDE_PROMPT" <<'EOF'
Operator: {{OPERATOR_NAME}}
EOF
OVERRIDE_OUTPUT=$(OPERATOR_NAME="Frankie" substitute_placeholders \
    "$OVERRIDE_PROMPT" \
    "owner/repo#9" "Override title" "https://example.com/9" "bob")
if ! echo "$OVERRIDE_OUTPUT" | grep -qF "Operator: Frankie"; then
    echo "FAIL: OPERATOR_NAME=Frankie did not override the default 'Sam'"
    echo "--- output ---"
    echo "$OVERRIDE_OUTPUT"
    exit 1
fi
if echo "$OVERRIDE_OUTPUT" | grep -qF "Operator: Sam"; then
    echo "FAIL: default 'Sam' leaked through despite OPERATOR_NAME=Frankie"
    exit 1
fi

# =====================================================================
# build_aggregator_prompt — stitches voice.md into aggregator.md
# =====================================================================
# Operator-tunable voice + tone live in prompts/voice.md and get
# inserted at aggregator.md's INSERT_VOICE_HERE marker. Lets a forked
# install reshape the bot's voice without touching aggregator.md (which
# carries load-bearing review-production logic).
mkdir -p "$HOME/.pr-reviewer/prompts"
cat > "$HOME/.pr-reviewer/prompts/aggregator.md" <<'EOF'
You are the aggregator. PR: {{PR_ID}}.

Step 5: rank findings.

<!-- INSERT_VOICE_HERE -->

Step 7: produce the final review.
EOF
cat > "$HOME/.pr-reviewer/prompts/voice.md" <<'EOF'
**Voice — opinionated nudges.** Phrase as "blame {{OPERATOR_NAME}}, but…".

**Tone — self-aware ribbing.** Sparingly. Author: @{{PR_AUTHOR}}.
EOF

echo "  build_aggregator_prompt: voice.md content stitched at marker, placeholders substituted..."
AGG_OUTPUT=$(build_aggregator_prompt "owner/repo#42" "Test PR" "https://github.com/owner/repo/pull/42" "plucas")
for needle in "PR: owner/repo#42" \
              "Step 5: rank findings." \
              "blame Sam, but" \
              "Author: @plucas" \
              "Step 7: produce the final review."; do
    if ! echo "$AGG_OUTPUT" | grep -qF "$needle"; then
        echo "FAIL: build_aggregator_prompt missing '$needle'"
        echo "--- output ---"
        echo "$AGG_OUTPUT"
        exit 1
    fi
done
# The marker itself must NOT survive — voice.md replaced it.
if echo "$AGG_OUTPUT" | grep -qF "INSERT_VOICE_HERE"; then
    echo "FAIL: build_aggregator_prompt left INSERT_VOICE_HERE marker in output"
    exit 1
fi
# Order fence: voice block lands BETWEEN step 5 and step 7.
step5_pos=$(echo "$AGG_OUTPUT" | grep -bo "Step 5:" | head -1 | cut -d: -f1)
voice_pos=$(echo "$AGG_OUTPUT" | grep -bo "Voice —" | head -1 | cut -d: -f1)
step7_pos=$(echo "$AGG_OUTPUT" | grep -bo "Step 7:" | head -1 | cut -d: -f1)
if ! { [ "$step5_pos" -lt "$voice_pos" ] && [ "$voice_pos" -lt "$step7_pos" ]; }; then
    echo "FAIL: voice insertion order regressed (step5=$step5_pos, voice=$voice_pos, step7=$step7_pos)"
    exit 1
fi

echo "  build_aggregator_prompt: OPERATOR_NAME=Frankie reskins voice without touching aggregator.md..."
RESKINNED=$(OPERATOR_NAME="Frankie" build_aggregator_prompt "owner/repo#43" "Reskin" "https://x" "alice")
if ! echo "$RESKINNED" | grep -qF "blame Frankie, but"; then
    echo "FAIL: build_aggregator_prompt did not honor OPERATOR_NAME=Frankie in voice block"
    exit 1
fi

echo "  build_aggregator_prompt: voice.md missing → fail-fast (rc=1, stderr diagnostic)..."
rm -f "$HOME/.pr-reviewer/prompts/voice.md"
# Wrap in `if … ; then FAIL; fi` so the deliberate non-zero exit is
# caught by the conditional rather than tripping set -e. ERR captures
# stderr-only via the `2>&1 >/dev/null` order.
if ERR=$(build_aggregator_prompt "owner/repo#44" "x" "https://x" "alice" 2>&1 >/dev/null); then
    echo "FAIL: missing voice.md should fail-fast (incomplete install)"
    exit 1
fi
if ! echo "$ERR" | grep -qF "voice.md missing"; then
    echo "FAIL: missing voice.md stderr should name the file; got: $ERR"
    exit 1
fi

echo "  build_aggregator_prompt: aggregator.md without INSERT_VOICE_HERE marker → fail-fast..."
cat > "$HOME/.pr-reviewer/prompts/voice.md" <<'EOF'
**Voice.** test
EOF
cat > "$HOME/.pr-reviewer/prompts/aggregator.md" <<'EOF'
You are the aggregator. PR: {{PR_ID}}.
No marker here.
EOF
if ERR=$(build_aggregator_prompt "owner/repo#45" "x" "https://x" "alice" 2>&1 >/dev/null); then
    echo "FAIL: missing INSERT_VOICE_HERE marker should fail-fast (stitch contract violated)"
    exit 1
fi
if ! echo "$ERR" | grep -qF "INSERT_VOICE_HERE"; then
    echo "FAIL: marker-missing stderr should name the marker; got: $ERR"
    exit 1
fi

# Real-prompts scenario: catches marker-format drift between the helper
# and the actual checked-in prompts/aggregator.md + prompts/voice.md.
# The synthetic scenarios above use a controlled bare marker; this one
# uses the real production files so a marker rename (or annotation
# edit) in either file without a corresponding helper update trips
# here. Regression-fence for PR #31 round-5 bot finding 2: an annotated
# `<!-- INSERT_VOICE_HERE — stitched in… -->` marker broke the prior
# exact-match grep gate and would have aborted the worker.
echo "  build_aggregator_prompt: real prompts/aggregator.md + voice.md compose end-to-end..."
cp "$SCRIPT_DIR/../prompts/aggregator.md" "$HOME/.pr-reviewer/prompts/aggregator.md"
cp "$SCRIPT_DIR/../prompts/voice.md" "$HOME/.pr-reviewer/prompts/voice.md"
REAL_OUTPUT=$(build_aggregator_prompt "owner/repo#99" "Real prompts" "https://github.com/owner/repo/pull/99" "alice")
if ! echo "$REAL_OUTPUT" | grep -qF "Voice — opinionated nudges"; then
    echo "FAIL: real-prompts compose missing voice.md content (marker contract drift between helper and production prompts?)"
    echo "--- output ---"
    echo "$REAL_OUTPUT" | head -30
    exit 1
fi
if ! echo "$REAL_OUTPUT" | grep -qF "Tone — self-aware ribbing"; then
    echo "FAIL: real-prompts compose missing voice.md tone block"
    exit 1
fi
if echo "$REAL_OUTPUT" | grep -qF "INSERT_VOICE_HERE"; then
    echo "FAIL: real-prompts compose left INSERT_VOICE_HERE marker in output (stitch failed but no error?)"
    exit 1
fi
# Verify {{OPERATOR_NAME}} flowed through voice.md → output.
if ! echo "$REAL_OUTPUT" | grep -qF "blame Sam"; then
    echo "FAIL: real-prompts compose did not substitute {{OPERATOR_NAME}} inside voice block"
    exit 1
fi

echo "  PASS"
