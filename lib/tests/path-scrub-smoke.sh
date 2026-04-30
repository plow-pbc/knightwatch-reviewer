#!/bin/bash
# Smoke for lib/path-scrub.sh. The reviewer's specialists/aggregator
# can emit absolute paths from the workdir or sibling-repo abs paths.
# scrub_review_paths() runs before `gh pr comment` and rewrites those
# to safe forms.

set -euo pipefail

TMPDIR=$(mktemp -d -t path-scrub-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../path-scrub.sh
. "$SCRIPT_DIR/path-scrub.sh"

WORKDIR="$TMPDIR/.pr-reviewer/workdirs/acme_self__42"
declare -A SOURCE_PATHS=(
    ["acme/self"]="$WORKDIR"
    ["acme/foo"]="/home/op/Hacking/foo"
    ["acme/bar"]="/home/op/Hacking/bar"
)

# Input body simulating real specialist + aggregator output.
input=$(cat <<EOF
## Findings

1. The new seam at $WORKDIR/app/Phoenix/ContainerRegistry.swift:93 bypasses
   the existing routing target.
   Files: [app/Phoenix/X.swift]($WORKDIR/app/Phoenix/X.swift:1)

2. /home/op/Hacking/foo/src/main.py:42 still calls the old API.
   Files: /home/op/Hacking/foo/src/main.py:42, /home/op/Hacking/bar/lib/x.py:7

3. Workdir-internal sibling cite: .siblings/acme/foo/src/other.py:10
EOF
)

got=$(scrub_review_paths "$input" "$WORKDIR" SOURCE_PATHS)

# 1. Workdir prefix gone.
if printf '%s' "$got" | grep -q "$WORKDIR"; then
    echo "FAIL: workdir abs path still present"
    printf '%s\n' "$got"
    exit 1
fi
if ! printf '%s' "$got" | grep -q 'app/Phoenix/ContainerRegistry.swift:93'; then
    echo "FAIL: workdir-relative path lost"
    exit 1
fi

# 2. SOURCE_PATHS abs paths replaced with slug.
if printf '%s' "$got" | grep -q '/home/op/Hacking/foo'; then
    echo "FAIL: sibling abs path still present"
    exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/foo/src/main.py:42'; then
    echo "FAIL: sibling slug-prefixed form missing"
    exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/bar/lib/x.py:7'; then
    echo "FAIL: second sibling slug-prefixed form missing"
    exit 1
fi

# 3. .siblings/ prefix stripped.
if printf '%s' "$got" | grep -q '\.siblings/'; then
    echo "FAIL: .siblings/ prefix not stripped"
    exit 1
fi
if ! printf '%s' "$got" | grep -q 'acme/foo/src/other.py:10'; then
    echo "FAIL: .siblings-stripped path lost"
    exit 1
fi

echo "  ok: scrub_review_paths normalizes workdir + sibling + .siblings paths"
