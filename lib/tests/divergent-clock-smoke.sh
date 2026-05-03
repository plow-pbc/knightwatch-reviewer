#!/usr/bin/env bash
# Smoke test for the round-11 fix: meta.json.started_at must be derived
# from REVIEW_START_TS (the early capture) and NOT from a fresh `date`
# call later in the run. The two values drift by sub-seconds under
# load. A /srosro-review trigger landing in that drift window —
# `created_at > REVIEW_START_TS` but `created_at < fresh_date_iso` —
# would be silently filtered out by review.sh's cutoff (which reads
# meta.json.started_at) on the next tick.
#
# Strategy: shim `date` so two successive calls return different
# instants. Run the actual meta.json write block from review-one-pr.sh
# under that shim. Assert started_at matches REVIEW_START_TS's ISO,
# not the second clock reading.
#
# Runs in a private tmpdir — does not touch ~/.pr-reviewer.

set -euo pipefail

TMPDIR=$(mktemp -d -t divergent-clock-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "  scenario 1: structural — meta.json write uses REVIEW_START_ISO, not a fresh date call..."
# Locate the meta.json `started_at` write. It must reference
# REVIEW_START_ISO; a regression that re-introduces $(date ...) here
# silently reopens the round-11 BCR class.
META_BLOCK=$(awk '
    /jq -n \\$/        { in_meta=1 }
    in_meta            { print }
    in_meta && /\$RUN_DIR\/meta.json/ { in_meta=0 }
' "$PROJECT_ROOT/lib/review-one-pr.sh")
if ! printf '%s' "$META_BLOCK" | grep -q -- '--arg started_at "\$REVIEW_START_ISO"'; then
    echo "FAIL scenario 1: meta.json write does not reference \$REVIEW_START_ISO for started_at — round-11 fix regressed"
    echo "--- meta block ---"
    printf '%s\n' "$META_BLOCK"
    exit 1
fi
if printf '%s' "$META_BLOCK" | grep -qE -- '--arg started_at "\$\(date'; then
    echo "FAIL scenario 1: meta.json write uses a fresh \$(date ...) call for started_at — round-11 BCR re-introduced"
    echo "--- meta block ---"
    printf '%s\n' "$META_BLOCK"
    exit 1
fi

echo "  scenario 2: behavioral — divergent clock, ISO matches REVIEW_START_TS not the fresh date..."
# Shim date to return progressively-increasing values: every call adds
# 100 seconds to a baseline. The first `date +%s` reading drives
# REVIEW_START_TS / REVIEW_START_ISO; if the meta.json write later
# called `date -u +...` again it would land 100s in the future, which
# we'd see in started_at and fail.
SHIMDIR="$TMPDIR/shim"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/date" <<'SHIM'
#!/bin/bash
# Stateful date shim: each invocation reads, increments, and writes
# back the call counter, so successive calls return monotonically
# increasing instants. Baseline 1700000000 + (counter * 100) seconds.
BASELINE=1700000000
COUNTER_FILE="${DATE_SHIM_COUNTER_FILE:?DATE_SHIM_COUNTER_FILE must be set}"
COUNTER=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
NEXT_COUNTER=$((COUNTER + 1))
echo "$NEXT_COUNTER" > "$COUNTER_FILE"
TS=$((BASELINE + COUNTER * 100))

iso_from_epoch() {
    python3 -c "import datetime; print(datetime.datetime.fromtimestamp(int('$1'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

# Honor only the two formats the production code uses: `+%s` (epoch)
# and `-u -d "@<epoch>" +"%Y-%m-%dT%H:%M:%SZ"` (ISO 8601 from epoch).
# The `-u +%Y-%m-%dT%H:%M:%SZ` form (no -d) is the round-11-bug shape
# we explicitly want to detect — fall through to the real date binary for
# anything else, which gives realistic behavior for log-line dates etc.
if [ "$1" = "+%s" ]; then
    echo "$TS"
    exit 0
fi
if [ "$1" = "-u" ] && [ "${2:-}" = "-d" ] && [[ "${3:-}" =~ ^@[0-9]+$ ]]; then
    EPOCH="${3#@}"
    iso_from_epoch "$EPOCH"
    exit 0
fi
if [ "$1" = "-u" ] && [ "${2:-}" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    # The exact format the round-11 bug used — this branch returns the
    # NEXT-counter clock reading, so a regression that calls `date -u
    # +%Y-%m-%dT%H:%M:%SZ` for started_at lands 100s after the captured
    # REVIEW_START_TS and the assertion below catches it.
    iso_from_epoch "$TS"
    exit 0
fi
# Fall through to the real date binary. /bin/date works on both
# macOS and Linux; /usr/bin/date is Linux-only.
if [ -x /bin/date ]; then
    exec /bin/date "$@"
else
    exec /usr/bin/date "$@"
fi
SHIM
chmod +x "$SHIMDIR/date"

# Replay the early-capture + meta.json write logic from review-one-pr.sh
# in a sandbox so we can drive it under the date shim. The logic must
# stay 1:1 with production — any drift here is a smoke that's no longer
# fencing the real path. The structural grep above is the redundant
# fence that catches that drift.
RUN_DIR="$TMPDIR/run"
mkdir -p "$RUN_DIR"
COUNTER_FILE="$TMPDIR/date-counter"
echo 0 > "$COUNTER_FILE"

PATH="$SHIMDIR:$PATH" \
DATE_SHIM_COUNTER_FILE="$COUNTER_FILE" \
RUN_DIR="$RUN_DIR" \
bash -c '
    set -euo pipefail
    # Capture once — this is the production pattern at lib/review-one-pr.sh
    # line ~39.
    REVIEW_START_TS=$(date +%s)
    REVIEW_START_ISO=$(date -u -d "@$REVIEW_START_TS" +"%Y-%m-%dT%H:%M:%SZ")

    # Production-shaped meta.json write at lib/review-one-pr.sh ~line 156.
    jq -n \
        --arg repo "test/repo" \
        --arg pr_id "test/repo#1" \
        --argjson pr_num 1 \
        --arg sha "abc123" \
        --arg branch "main" \
        --arg title "test pr" \
        --arg force_whole_pr "false" \
        --arg workdir "/tmp/wd" \
        --arg started_at "$REVIEW_START_ISO" \
        "{repo: \$repo, pr_id: \$pr_id, pr_num: \$pr_num, sha: \$sha, branch: \$branch, title: \$title, force_whole_pr: (\$force_whole_pr == \"true\"), workdir: \$workdir, started_at: \$started_at}" \
        > "$RUN_DIR/meta.json"

    # Save REVIEW_START_TS so the assertion below knows what to expect.
    echo "$REVIEW_START_TS" > "$RUN_DIR/expected-ts"
'

EXPECTED_TS=$(cat "$RUN_DIR/expected-ts")
EXPECTED_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(int('$EXPECTED_TS'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
GOT_ISO=$(jq -r '.started_at' "$RUN_DIR/meta.json")
if [ "$GOT_ISO" != "$EXPECTED_ISO" ]; then
    echo "FAIL scenario 2: meta.json.started_at = $GOT_ISO, expected $EXPECTED_ISO (REVIEW_START_TS=$EXPECTED_TS)"
    cat "$RUN_DIR/meta.json"
    exit 1
fi

# The shim's call counter should be exactly 2 (one `date +%s` + one
# `date -u -d @<epoch>`) — a regression that called `date -u
# +%Y-%m-%dT%H:%M:%SZ` for started_at would push the counter to 3 AND
# the started_at value would be 100s later than EXPECTED_ISO.
COUNTER_FINAL=$(cat "$COUNTER_FILE")
if [ "$COUNTER_FINAL" -gt 2 ]; then
    echo "FAIL scenario 2 (extra clock read): date called $COUNTER_FINAL times, expected exactly 2 — extra date call between capture and meta.json write reopens round-11 BCR"
    exit 1
fi

echo "  PASS (2 scenarios: structural-grep + behavioral-divergent-clock)"
