#!/usr/bin/env bash
# Smoke test for lib/auth.sh — covers is_trusted_repo_author and
# submit_approval. Stubs `gh` so the real GitHub API is never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t auth-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# log() comes from lib/state-io.sh; submit_approval calls it. Set
# LOG_FILE to a tmp path so we can assert which log line fired per
# scenario (the helper writes the same line via tee in production).
export LOG_FILE="$TMPDIR/log"
. "$PROJECT_ROOT/lib/state-io.sh"

# `gh` stub for two endpoints:
#   gh api repos/<repo>/collaborators/<user>/permission --jq .permission
#       → echoes "write" if user ∈ MOCK_TRUSTED_USERS, else "none"
#   gh pr review <num> --repo <repo> --approve --body <body>
#       → records the call, exits 0 unless MOCK_GH_REVIEW_FAILS=1
GH_REVIEW_LOG="$TMPDIR/gh-review.log"
export GH_REVIEW_LOG
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
elif [ "$1" = "pr" ] && [ "$2" = "review" ]; then
    echo "REVIEW $*" >> "$GH_REVIEW_LOG"
    if [ -n "${MOCK_GH_REVIEW_FAILS:-}" ]; then
        echo "gh: server error" >&2
        exit 1
    fi
    exit 0
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Source the helpers under test.
. "$PROJECT_ROOT/lib/auth.sh"

reset_state() {
    : > "$LOG_FILE"
    : > "$GH_REVIEW_LOG"
}

# --- is_trusted_repo_author ---
echo "  scenario 1: is_trusted_repo_author returns true for a write-access user..."
MOCK_TRUSTED_USERS="srosro someuser" is_trusted_repo_author "cncorp/plow" "someuser" || { echo "FAIL scenario 1: expected trust"; exit 1; }

echo "  scenario 2: is_trusted_repo_author returns false for a non-collaborator..."
MOCK_TRUSTED_USERS="srosro" is_trusted_repo_author "cncorp/plow" "stranger" && { echo "FAIL scenario 2: expected no trust"; exit 1; } || true

echo "  scenario 3: is_trusted_repo_author returns false for empty user..."
is_trusted_repo_author "cncorp/plow" "" && { echo "FAIL scenario 3: empty user should not be trusted"; exit 1; } || true

# --- submit_approval ---
echo "  scenario 4: submit_approval skips the API call when bot is the PR author..."
reset_state
submit_approval "cncorp/plow" "100" "srosro" "srosro" "Approving per automated review above." && { echo "FAIL scenario 4: expected return 1 on self-author"; exit 1; } || true
[ ! -s "$GH_REVIEW_LOG" ] || { echo "FAIL scenario 4: gh pr review was called when bot is the PR author"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "Skipping approve on cncorp/plow#100 — PR authored by srosro" "$LOG_FILE" || { echo "FAIL scenario 4: expected 'Skipping approve' log line"; cat "$LOG_FILE"; exit 1; }

echo "  scenario 5: submit_approval calls gh pr review --approve and returns 0 on success..."
reset_state
submit_approval "cncorp/plow" "100" "srosro" "delattre1" "Approving per automated review above." || { echo "FAIL scenario 5: expected return 0 on successful approve"; cat "$LOG_FILE"; exit 1; }
[ "$(grep -c '^REVIEW' "$GH_REVIEW_LOG")" = "1" ] || { echo "FAIL scenario 5: expected exactly 1 gh pr review call, got $(grep -c '^REVIEW' "$GH_REVIEW_LOG" 2>/dev/null || echo 0)"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "Approved cncorp/plow#100" "$LOG_FILE" || { echo "FAIL scenario 5: expected 'Approved' log line"; cat "$LOG_FILE"; exit 1; }

echo "  scenario 6: submit_approval logs failure and returns 1 when gh pr review --approve fails..."
reset_state
MOCK_GH_REVIEW_FAILS=1 submit_approval "cncorp/plow" "100" "srosro" "delattre1" "Approving per automated review above." && { echo "FAIL scenario 6: expected return 1 on gh failure"; exit 1; } || true
[ "$(grep -c '^REVIEW' "$GH_REVIEW_LOG")" = "1" ] || { echo "FAIL scenario 6: expected exactly 1 gh pr review call (the failed attempt)"; cat "$GH_REVIEW_LOG"; exit 1; }
grep -q "gh pr review --approve FAILED" "$LOG_FILE" || { echo "FAIL scenario 6: expected 'FAILED' log line"; cat "$LOG_FILE"; exit 1; }

# --- just_test_skip_reason ---
# `just test` executes PR-controlled code; untrusted authors (no push access)
# must never have their code run — on ANY path, not only container/dind mode.
echo "  scenario 7: just_test_skip_reason runs (empty reason) for a trusted author with a justfile..."
reason=$(just_test_skip_reason "/repo/justfile" true)
[ -z "$reason" ] || { echo "FAIL scenario 7: trusted author with justfile should run (empty reason), got: $reason"; exit 1; }

echo "  scenario 8: just_test_skip_reason skips untrusted authors regardless of mode..."
reason=$(just_test_skip_reason "/repo/justfile" false)
[ -n "$reason" ] || { echo "FAIL scenario 8: untrusted author should be skipped"; exit 1; }
printf '%s' "$reason" | grep -qi "untrusted" || { echo "FAIL scenario 8: skip reason should name the untrusted author, got: $reason"; exit 1; }

echo "  scenario 9: just_test_skip_reason skips when there is no justfile..."
reason=$(just_test_skip_reason "" true)
[ -n "$reason" ] || { echo "FAIL scenario 9: missing justfile should skip"; exit 1; }
printf '%s' "$reason" | grep -qi "justfile" || { echo "FAIL scenario 9: skip reason should name the missing justfile, got: $reason"; exit 1; }

echo "  PASS (9 scenarios: trust-yes, trust-no, trust-empty, approval-self-skipped, approval-success, approval-failure-fail-loud, just-test run/untrusted-skip/no-justfile)"
