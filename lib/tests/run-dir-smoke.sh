#!/usr/bin/env bash
# Smoke for allocate_run_dir (lib/run-dir.sh).
#
# Locks down the no-overwrite guarantee at the worker's runtime guard:
#   1. Clean run dir → created with agents/ + inputs/ subdirs, returns 0
#   2. Pre-existing run dir → returns 1, logs "collision"
#   3. Subdir mkdir partially fails → rollback removes RUN_DIR; "as a
#      unit" contract holds (mkdir is function-stubbed since real
#      filesystem partial failures aren't easily simulable)
#   4. RUN_DIR's parent unwritable (read-only) → returns 1, logs the
#      parent-create failure
#
# Sources lib/run-dir.sh directly so this test exercises the same
# function review-one-pr.sh calls. Stubs `log()` to capture log lines
# locally; the production log() is in lib/state-io.sh.

set -uo pipefail

TMPDIR=$(mktemp -d -t run-dir-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR" 2>/dev/null; chmod -R u+w "$TMPDIR" 2>/dev/null; rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../run-dir.sh
. "$PROJECT_ROOT/lib/run-dir.sh"

# Stub the log() seam allocate_run_dir uses. Production log() comes
# from lib/state-io.sh; here we just append to a file the assertions
# can grep.
LOG_CAPTURE="$TMPDIR/log.txt"
PR_ID="test/repo#1"
log() { echo "$*" >> "$LOG_CAPTURE"; }

echo "  scenario 1: clean RUN_DIR → success + agents/inputs created..."
RD="$TMPDIR/state/runs/clean-id"
if ! allocate_run_dir "$RD"; then
    echo "FAIL: clean allocation returned non-zero"
    exit 1
fi
for sub in agents inputs; do
    if [ ! -d "$RD/$sub" ]; then
        echo "FAIL: $RD/$sub not created"
        exit 1
    fi
done

echo "  scenario 2: pre-existing RUN_DIR → returns 1, logs collision..."
: > "$LOG_CAPTURE"
RD="$TMPDIR/state/runs/exists-id"
mkdir -p "$RD"
if allocate_run_dir "$RD"; then
    echo "FAIL: collision allocation should have returned non-zero"
    exit 1
fi
if ! grep -q "RUN_DIR collision" "$LOG_CAPTURE"; then
    echo "FAIL: collision was not logged with the 'collision' marker"
    cat "$LOG_CAPTURE"
    exit 1
fi
if ! grep -q "$RD" "$LOG_CAPTURE"; then
    echo "FAIL: collision log line did not include the dir path"
    cat "$LOG_CAPTURE"
    exit 1
fi

echo "  scenario 3: subdir mkdir partially fails → rollback removes RUN_DIR..."
: > "$LOG_CAPTURE"
RD="$TMPDIR/state/runs/rollback-id"

# Override mkdir to simulate a partial-success failure on the third call
# (the agents/inputs creation in allocate_run_dir): create the first arg,
# fail before the second. Calls 1 (mkdir -p parent) and 2 (mkdir $run_dir)
# go through unchanged.
mkdir_calls=0
mkdir() {
    mkdir_calls=$((mkdir_calls + 1))
    if [ "$mkdir_calls" -eq 3 ]; then
        command mkdir "$1" 2>/dev/null
        return 1
    fi
    command mkdir "$@"
}

if allocate_run_dir "$RD"; then
    echo "FAIL: subdir-mkdir-failure allocation should have returned non-zero"
    unset -f mkdir
    exit 1
fi
unset -f mkdir
if [ -e "$RD" ]; then
    echo "FAIL: $RD was not rolled back after subdir mkdir failure"
    ls -laR "$RD"
    exit 1
fi
if ! grep -q "rolling back" "$LOG_CAPTURE"; then
    echo "FAIL: rollback log line not emitted"
    cat "$LOG_CAPTURE"
    exit 1
fi

echo "  scenario 4: parent unwritable → returns 1, logs real failure (not 'collision')..."
: > "$LOG_CAPTURE"
RO_PARENT="$TMPDIR/readonly"
mkdir -p "$RO_PARENT"
chmod -w "$RO_PARENT"
RD="$RO_PARENT/runs/some-id"
if [ "$(id -u)" -eq 0 ]; then
    echo "  (skipping: running as root, chmod -w doesn't gate root)"
else
    if allocate_run_dir "$RD"; then
        echo "FAIL: unwritable-parent allocation should have returned non-zero"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    if grep -q "collision" "$LOG_CAPTURE"; then
        echo "FAIL: real mkdir failure was mislabeled as 'collision'"
        cat "$LOG_CAPTURE"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    if ! grep -q "failed to create" "$LOG_CAPTURE"; then
        echo "FAIL: parent-create failure not logged"
        cat "$LOG_CAPTURE"
        chmod +w "$RO_PARENT"
        exit 1
    fi
    chmod +w "$RO_PARENT"
fi

echo "  latest_reviewed_sha_comment: returns the bot's comment carrying the head's marker (with created_at + body)..."
HEAD_SHA="deadbeefcafe1234"; BOT="srosro"
COMMENTS=$(jq -n --arg m "$(reviewed_sha_marker "$HEAD_SHA")" '[
  {user: {login: "srosro"}, created_at: "2026-05-29T10:00:00Z",
   body: "<!-- knightwatch-reviewer:auto-post -->\n\($m)\n\n📋 Re-review …\nVERDICT: COMMENT"},
  {user: {login: "srosro"}, created_at: "2026-05-29T11:00:00Z", body: "/srosro-review"}
]')
match=$(latest_reviewed_sha_comment "$COMMENTS" "$HEAD_SHA" "$BOT")
[ -n "$match" ] || { echo "FAIL: should match the bot's marker comment"; exit 1; }
[ "$(printf '%s' "$match" | jq -r '.created_at')" = "2026-05-29T10:00:00Z" ] \
  || { echo "FAIL: should return the matched comment's created_at"; exit 1; }
printf '%s' "$match" | jq -e '(.body|contains("Re-review"))' >/dev/null \
  || { echo "FAIL: should return the matched comment's body"; exit 1; }

echo "  latest_reviewed_sha_comment: SPOOF — a non-bot author's marker comment does NOT match (security gate)..."
SPOOF=$(jq -n --arg m "$(reviewed_sha_marker "$HEAD_SHA")" '[
  {user: {login: "mallory"}, created_at: "2026-05-29T10:00:00Z", body: "\($m)"}
]')
[ -z "$(latest_reviewed_sha_comment "$SPOOF" "$HEAD_SHA" "$BOT")" ] \
  || { echo "FAIL: a non-bot commenter must not be able to suppress review via a pasted marker"; exit 1; }

echo "  latest_reviewed_sha_comment: QUOTE-INJECTION — marker in a bot review's PROSE (not the header block) does NOT match..."
QUOTED=$(jq -n --arg m "$(reviewed_sha_marker "$HEAD_SHA")" '[
  {user: {login: "srosro"}, created_at: "2026-05-29T10:00:00Z",
   body: "<!-- knightwatch-reviewer:auto-post -->\n<!-- knightwatch-reviewer:reviewed-sha=feedfacecafe -->\n\n> 📋 Re-review\nProbe 1: the PR diff quotes a marker:\n```\n\($m)\n```\n"}
]')
[ -z "$(latest_reviewed_sha_comment "$QUOTED" "$HEAD_SHA" "$BOT")" ] \
  || { echo "FAIL: a marker quoted in review prose must not suppress review (header-region fence)"; exit 1; }

echo "  latest_reviewed_sha_comment: no match when the marker SHA differs (head moved)..."
[ -z "$(latest_reviewed_sha_comment "$COMMENTS" "0000000000000000" "$BOT")" ] \
  || { echo "FAIL: should not match a different head"; exit 1; }

echo "  latest_reviewed_sha_comment: no match when no comment carries a marker..."
PLAIN=$(jq -n '[{user: {login: "srosro"}, created_at: "2026-05-29T10:00:00Z", body: "looks good"}]')
[ -z "$(latest_reviewed_sha_comment "$PLAIN" "$HEAD_SHA" "$BOT")" ] \
  || { echo "FAIL: should not match without a marker"; exit 1; }

echo "  latest_reviewed_sha_comment: matches through the REAL post path — prepend_review_header keeps the marker in the trusted block..."
# Mirror review-one-pr.sh's COMMENT_BODY assembly (auto-post, ai-author,
# reviewed-sha, bakeoff, then prose) and run it through prepend_review_header —
# the production transform that relocates non-preserved markers below the
# blockquote. The marker MUST still be matchable, or the backstop never fires
# on a real posted review (the bug round-3 caught: fixture had it pre-placed).
WORKER_BODY=$(printf '%s\n%s\n%s\n<!-- knightwatch-bakeoff: specialists=x -->\n> 📋 First review\nLooks good.' \
  "<!-- knightwatch-reviewer:auto-post -->" "$BOT_AI_AUTHOR_MARKER" "$(reviewed_sha_marker "$HEAD_SHA")")
POSTED_BODY=$(prepend_review_header "$WORKER_BODY" "✅ Tests passed")
POSTED_COMMENTS=$(jq -n --arg login "srosro" --arg b "$POSTED_BODY" \
  '[{user: {login: $login}, created_at: "2026-05-29T10:00:00Z", body: $b}]')
[ -n "$(latest_reviewed_sha_comment "$POSTED_COMMENTS" "$HEAD_SHA" "$BOT")" ] \
  || { echo "FAIL: marker must survive prepend_review_header in the trusted leading block"; \
       printf 'posted body was:\n%s\n' "$POSTED_BODY"; exit 1; }

echo "  latest_reviewed_sha_comment: CRLF body still matches (GitHub web-UI \\r\\n must not false-negative → flood)..."
CRLF=$(jq -n --arg m "$(reviewed_sha_marker "$HEAD_SHA")" '[
  {user: {login: "srosro"}, created_at: "2026-05-29T10:00:00Z",
   body: ("<!-- knightwatch-reviewer:auto-post -->\r\n" + $m + "\r\n\r\n> 📋 Re-review\r\nok\r\n")}
]')
[ -n "$(latest_reviewed_sha_comment "$CRLF" "$HEAD_SHA" "$BOT")" ] \
  || { echo "FAIL: a CRLF-line-ending bot body must still match (exact-equality must tolerate trailing \\r)"; exit 1; }

echo "  cold-cache fallback: reviewed-sha cache provides KNOWN_SHA but NOT a prior body/approval; a real run wins..."
CSTATE=$(mktemp -d); CSLUG="acme_widget"; CPRN="42"; CHEAD="cafef00dbabe"
mkdir -p "$CSTATE/runs"
# Backstop wrote a SHA-only cache entry (no run). The SHA gate must fall back to it.
CACHE=$(reviewed_sha_cache_path "$CSTATE" "$CSLUG" "$CPRN"); mkdir -p "$(dirname "$CACHE")"
printf '%s' "$CHEAD" > "$CACHE"
got=$(latest_author_visible_review_sha "$CSTATE" "$CSLUG" "$CPRN" "")
[ "$got" = "$CHEAD" ] || { echo "FAIL: SHA gate must fall back to the reviewed-sha cache — want [$CHEAD] got [$got]"; exit 1; }
# The cache is a dedup-only signal: body + approval must see NO local prior review.
[ -z "$(latest_author_visible_review "$CSTATE" "$CSLUG" "$CPRN" "")" ] \
  || { echo "FAIL: cache must not surface a prior-review body (it has none)"; exit 1; }
[ -z "$(latest_author_visible_review_approved "$CSTATE" "$CSLUG" "$CPRN" "")" ] \
  || { echo "FAIL: cache must not surface an approval verdict (must be empty/unknown, never a misreported false)"; exit 1; }
# A real run always wins over the cache (cache shadowed once a genuine review lands).
RRID="${CSLUG}__${CPRN}__20260529T000000000Z__9999999"; RRD="$CSTATE/runs/$RRID"; mkdir -p "$RRD/agents/aggregator"
printf 'real review\nVERDICT: COMMENT\n' > "$RRD/agents/aggregator/output.md"
jq -n --arg repo "acme/widget" --arg pr_num "$CPRN" --arg sha "9999999aaaaaaa" \
   '{repo: $repo, pr_num: ($pr_num|tonumber), sha: $sha, started_at: "2026-05-29T00:00:00Z"}' > "$RRD/meta.json"
finalize_meta_json "$RRD/meta.json" "2026-05-29T00:00:01Z" "completed" "true"
[ "$(latest_author_visible_review_sha "$CSTATE" "$CSLUG" "$CPRN" "")" = "9999999aaaaaaa" ] \
  || { echo "FAIL: a real run must win over the reviewed-sha cache"; exit 1; }

echo "  PASS (4 scenarios: clean allocation, collision detected, subdir-failure rollback, real failure not mislabeled + 6 latest_reviewed_sha_comment incl. spoof-gate + quote-injection-fence + real-post-path + CRLF-tolerant + 1 cold-cache fallback)"
