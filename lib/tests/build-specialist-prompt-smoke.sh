#!/bin/bash
# Smoke test for lib/prompt-build.sh's build_specialist_prompt.
#
# Verifies all five placeholders ({{PR_ID}}, {{PR_TITLE}}, {{PR_URL}},
# {{SPECIALIST_NAME}}, {{PR_AUTHOR}}) are substituted correctly, and
# that no unsubstituted {{...}} markers remain in the output.

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
EOF

ANGLE_FILE="$TMPDIR/angle.md"
echo "Angle: focus on X" > "$ANGLE_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_DIR/prompt-build.sh"

OUTPUT=$(build_specialist_prompt \
    "security" \
    "$ANGLE_FILE" \
    "owner/repo#42" \
    "Add caching to /api/foo" \
    "https://github.com/owner/repo/pull/42" \
    "plucas")

echo "  asserting all five placeholders substituted..."
for pair in "PR: owner/repo#42" "Title: Add caching to /api/foo" \
            "URL: https://github.com/owner/repo/pull/42" \
            "Specialist: security" "Author: plucas" \
            "Angle: focus on X"; do
    if ! echo "$OUTPUT" | grep -qF "$pair"; then
        echo "FAIL: expected '$pair' in output"
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

echo "  PASS"
