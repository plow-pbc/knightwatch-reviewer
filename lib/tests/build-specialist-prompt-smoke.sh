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

echo "  PASS"
