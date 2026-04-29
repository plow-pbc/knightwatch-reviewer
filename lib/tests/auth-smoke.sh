#!/bin/bash
# Smoke test for lib/auth.sh — covers both is_trusted_repo_author and
# is_pr_author. Stubs `gh` so the real GitHub API is never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t auth-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# `gh` stub. Two endpoints we care about:
#   gh api repos/<repo>/collaborators/<user>/permission --jq .permission
#       → echoes $MOCK_TRUSTED_USERS membership
#   gh pr view <num> --repo <repo> --json author --jq .author.login
#       → echoes $MOCK_PR_AUTHOR
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ]; then
    endpoint=""
    for arg in "$@"; do
        case "$arg" in repos/*) endpoint="$arg" ;; esac
    done
    if [[ "$endpoint" == */collaborators/*/permission ]]; then
        user="${endpoint##*/collaborators/}"
        user="${user%/permission}"
        for trusted in ${MOCK_TRUSTED_USERS:-}; do
            if [ "$user" = "$trusted" ]; then echo "write"; exit 0; fi
        done
        echo "none"
    else
        echo "{}"
    fi
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    # MOCK_PR_AUTHOR_FAIL=1 simulates a non-existent PR / API outage.
    if [ -n "${MOCK_PR_AUTHOR_FAIL:-}" ]; then
        echo "gh: not found" >&2
        exit 1
    fi
    echo "${MOCK_PR_AUTHOR:-someuser}"
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Source the helpers under test.
. "$PROJECT_ROOT/lib/auth.sh"

# --- is_trusted_repo_author ---
echo "  scenario 1: is_trusted_repo_author returns true for a write-access user..."
MOCK_TRUSTED_USERS="srosro someuser" is_trusted_repo_author "cncorp/plow" "someuser" || { echo "FAIL scenario 1: expected trust"; exit 1; }

echo "  scenario 2: is_trusted_repo_author returns false for a non-collaborator..."
MOCK_TRUSTED_USERS="srosro" is_trusted_repo_author "cncorp/plow" "stranger" && { echo "FAIL scenario 2: expected no trust"; exit 1; } || true

echo "  scenario 3: is_trusted_repo_author returns false for empty user..."
is_trusted_repo_author "cncorp/plow" "" && { echo "FAIL scenario 3: empty user should not be trusted"; exit 1; } || true

# --- is_pr_author ---
echo "  scenario 4: is_pr_author returns true when login matches the PR author..."
MOCK_PR_AUTHOR="srosro" is_pr_author "cncorp/plow" "100" "srosro" || { echo "FAIL scenario 4: expected match"; exit 1; }

echo "  scenario 5: is_pr_author returns false when login differs..."
MOCK_PR_AUTHOR="srosro" is_pr_author "cncorp/plow" "100" "delattre1" && { echo "FAIL scenario 5: expected no match"; exit 1; } || true

echo "  scenario 6: is_pr_author returns false on empty user..."
is_pr_author "cncorp/plow" "100" "" && { echo "FAIL scenario 6: empty user should not be the author"; exit 1; } || true

echo "  scenario 7: is_pr_author returns false on gh API failure (defaults to 'not author')..."
MOCK_PR_AUTHOR_FAIL=1 is_pr_author "cncorp/plow" "100" "srosro" && { echo "FAIL scenario 7: API failure should not assert authorship"; exit 1; } || true

echo "  PASS (7 scenarios: trust-yes, trust-no, trust-empty, author-match, author-mismatch, author-empty, author-api-failure)"
