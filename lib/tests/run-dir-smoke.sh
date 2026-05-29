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

echo "  seed roundtrip: a completed run (meta + recovered output.md) is author-visible, resolves KNOWN_SHA, and exposes the prior body..."
SEED_STATE=$(mktemp -d); SLUG="acme_widget"; PRN="42"; HEAD="cafef00dbabe"
RID="${SLUG}__${PRN}__20260529T000000000Z__${HEAD:0:7}"
RD="$SEED_STATE/runs/$RID"; mkdir -p "$RD/agents/aggregator"
# what the backstop writes: recovered review body + meta with sha=HEAD, started_at from the comment
printf 'recovered prior review body\nVERDICT: COMMENT\n' > "$RD/agents/aggregator/output.md"
jq -n --arg repo "acme/widget" --arg pr_num "$PRN" --arg sha "$HEAD" \
   '{repo: $repo, pr_num: ($pr_num|tonumber), sha: $sha, started_at: "2026-05-29T00:00:00Z"}' > "$RD/meta.json"
finalize_meta_json "$RD/meta.json" "2026-05-29T00:00:01Z" "completed" "true"
is_run_author_visible "$RD" || { echo "FAIL: seeded run should be author-visible"; exit 1; }
got=$(latest_author_visible_review_sha "$SEED_STATE" "$SLUG" "$PRN" "")
[ "$got" = "$HEAD" ] || { echo "FAIL: seeded KNOWN_SHA — want [$HEAD] got [$got]"; exit 1; }
body=$(latest_author_visible_review "$SEED_STATE" "$SLUG" "$PRN" "")
printf '%s' "$body" | grep -q "recovered prior review body" \
  || { echo "FAIL: seeded run should expose its recovered body to prior-review staging"; exit 1; }

echo "  PASS (4 scenarios: clean allocation, collision detected, subdir-failure rollback, real failure not mislabeled + 5 latest_reviewed_sha_comment incl. spoof-gate + quote-injection-fence + 1 seed roundtrip)"
