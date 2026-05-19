#!/usr/bin/env bash
# Smoke for fetch_issue_comments (lib/gh-comments.sh).
#
# This helper is the shared seam three orchestrator-level scripts go
# through to read PR comments (review.sh, approve-from-replies.sh,
# learn-from-replies.sh). The whole reason it exists is to prevent the
# original bug class from recurring: a caller that forgets `--paginate`
# silently drops every comment past page 1, which can hide
# /srosro-update-review and /srosro-memorize triggers on long PR threads.
#
# Coverage:
#   1. multi-page fetch — stub gh that returns two pages must be merged
#      into one flat array; assertion compares the merged length to the
#      sum of per-page lengths so a future regression that skips
#      `--paginate` (or drops `jq -s 'add'`) trips immediately.
#   2. empty response — stub gh that returns nothing must not crash and
#      must return `[]` so callers can iterate without a guard.
#   3. gh failure — stub gh that exits non-zero must propagate the
#      failure so callers with `set -o pipefail` (approve-/learn-)
#      see a non-zero exit and fall through to their skip-this-PR path.
#
# Hermetic: stubs `gh` via PATH, no network, no real repo access.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub gh: prepend a fake gh shim to PATH that emits canned data based
# on the test's environment vars. Each scenario overrides
# STUB_PAGES_DIR / STUB_EXIT before invoking fetch_issue_comments.
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/gh" <<'STUB'
#!/bin/bash
# Fake gh that emulates --paginate by emitting one JSON document per
# "page" file (sorted) in $STUB_PAGES_DIR. If $STUB_EXIT is set,
# exits with that code instead. Doesn't validate args; the smoke
# arranges the right inputs.
if [ -n "${STUB_EXIT:-}" ]; then
    exit "$STUB_EXIT"
fi
if [ -n "${STUB_PAGES_DIR:-}" ] && [ -d "$STUB_PAGES_DIR" ]; then
    for page in "$STUB_PAGES_DIR"/page-*.json; do
        [ -f "$page" ] && cat "$page"
    done
fi
# Belt: real `gh api --paginate` exits 0 on success regardless of
# how many pages it emitted. Without this, an empty pages-dir would
# leak the trailing `[ -f ]` test's failure into the stub's exit
# code and falsely surface as a gh-failure to the caller.
exit 0
STUB
chmod +x "$TMPDIR/bin/gh"
export PATH="$TMPDIR/bin:$PATH"

. "$PROJECT_ROOT/lib/gh-comments.sh"

# ---- Scenario 1: multi-page merge ----
# Two pages of issue comments; helper must return ONE flat array
# containing both pages' contents. A regression that drops --paginate
# would only return page 1; a regression that drops `jq -s 'add'`
# would emit two arrays instead of one.
echo "  scenario 1: multi-page → flat merged array..."
PAGES_1="$TMPDIR/pages-1"
mkdir -p "$PAGES_1"
cat > "$PAGES_1/page-1.json" <<'EOF'
[{"id": 1, "body": "first comment"}, {"id": 2, "body": "/srosro-review"}]
EOF
cat > "$PAGES_1/page-2.json" <<'EOF'
[{"id": 3, "body": "/srosro-update-review"}, {"id": 4, "body": "fourth"}]
EOF

export STUB_PAGES_DIR="$PAGES_1"
export STUB_EXIT=""
result=$(fetch_issue_comments "owner/repo" "42")
got_len=$(printf '%s' "$result" | jq 'length')
got_first_id=$(printf '%s' "$result" | jq '.[0].id')
got_last_id=$(printf '%s' "$result" | jq '.[-1].id')
if [ "$got_len" != "4" ]; then
    echo "FAIL: scenario 1 — expected 4 comments merged, got $got_len"
    echo "result: $result"
    exit 1
fi
assert_eq "$got_first_id" "1" "scenario 1 — pages out of order or split (first=$got_first_id last=$got_last_id)"
assert_eq "$got_last_id" "4" "scenario 1 — pages out of order or split (first=$got_first_id last=$got_last_id)"
# Critical regression-fence: the page-2 trigger must be in the
# returned array. The original bug surfaced exactly because a
# /srosro-update-review on page 2 was silently dropped.
got_page2_trigger=$(printf '%s' "$result" | jq '[.[] | select(.body | contains("update-review"))] | length')
assert_eq "$got_page2_trigger" "1" "scenario 1 — page-2 /srosro-update-review trigger lost (this is the original bug)"

# ---- Scenario 2: empty response ----
# Real `gh api --paginate` on a PR with zero issue comments emits a
# single `[]` page (not empty stdout) and exits 0. Helper must return
# `[]` so callers can iterate without a guard.
echo "  scenario 2: empty response → []..."
EMPTY="$TMPDIR/pages-empty"
mkdir -p "$EMPTY"
echo '[]' > "$EMPTY/page-1.json"
export STUB_PAGES_DIR="$EMPTY"
export STUB_EXIT=""
result=$(fetch_issue_comments "owner/repo" "42")
assert_eq "$result" "[]" "scenario 2 — empty response should return '[]'"

# ---- Scenario 3: gh failure propagates ----
# When `gh api` exits non-zero (auth lapse, network outage, rate limit),
# callers with `set -o pipefail` (approve-from-replies, learn-from-
# replies) need to see the failure so their `|| { log; continue; }`
# path fires. Verify the helper preserves the non-zero exit through
# the gh→jq pipeline.
echo "  scenario 3: gh failure → non-zero exit..."
export STUB_EXIT="1"
unset STUB_PAGES_DIR
(set -o pipefail; fetch_issue_comments "owner/repo" "42" >/dev/null 2>&1)
exit_code=$?
not_zero=$([ "$exit_code" -eq 0 ] && echo "zero" || echo "")
assert_empty "$not_zero" "scenario 3 — helper returned 0 on gh failure (callers with pipefail won't notice)"

echo "  PASS (3 scenarios: multi-page-merge, empty-response, gh-failure-propagates)"
