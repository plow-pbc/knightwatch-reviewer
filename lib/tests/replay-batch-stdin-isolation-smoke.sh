#!/usr/bin/env bash
# Smoke for lib/replay-batch.sh's stdin isolation contract.
#
# The batch driver iterates the PRS CSV via `while read ... done <"$PRS"`.
# Each row invokes replay.sh, which invokes codex, which reads stdin
# unconditionally. Without `</dev/null` on the replay.sh call, codex
# consumes the rest of the CSV and only the first PR ever runs — a
# silent "1/N processed" failure observed on the PR #70 canary perf
# batch (cncorp/plow#569 ran; #563 and #565 dropped without warning).
#
# This smoke stubs replay.sh with a script that ALSO reads stdin
# (mimicking codex), passes a 3-row CSV through replay-batch.sh, and
# asserts all 6 expected cells (3 PRs × 2 prompt sets) materialize.

set -uo pipefail

TMPDIR=$(mktemp -d -t replay-batch-stdin-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Stage a sibling pair in a temp dir: the real replay-batch.sh + its
# replay-paths.sh dependency, plus a stub replay.sh that simulates codex.
LIB="$TMPDIR/lib"
mkdir -p "$LIB"
cp "$PROJECT_ROOT/lib/replay-batch.sh" "$LIB/"
cp "$PROJECT_ROOT/lib/replay-paths.sh" "$LIB/"

cat > "$LIB/replay.sh" <<'STUB'
#!/usr/bin/env bash
# Stub replay.sh: simulates codex by draining stdin, then writes the
# expected output marker so the batch driver can see the cell completed.
set -e
out_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output-dir) out_dir="$2"; shift 2 ;;
        --repo|--pr|--sha|--prompts) shift 2 ;;
        *) shift ;;
    esac
done
# THIS is the load-bearing behavior the smoke fences against: codex
# reads stdin. If replay-batch.sh passes the parent loop's stdin
# through, this cat would consume the rest of the CSV.
cat >/dev/null
mkdir -p "$out_dir"
printf '%s\n' "stub-aggregator-output" > "$out_dir/aggregator-output.md"
STUB
chmod +x "$LIB/replay.sh"

# Two prompt dirs with distinct basenames so per-cell paths don't collide.
mkdir -p "$TMPDIR/prompts-A" "$TMPDIR/prompts-B"

# CSV with comments, blank lines, and 3 PRs.
cat > "$TMPDIR/prs.csv" <<'CSV'
# header comment — must be skipped
# format: repo,pr,sha

owner/repoA,1,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
owner/repoB,2,bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
owner/repoC,3,cccccccccccccccccccccccccccccccccccccccc
CSV

bash "$LIB/replay-batch.sh" \
    --prs "$TMPDIR/prs.csv" \
    --prompts "$TMPDIR/prompts-A,$TMPDIR/prompts-B" \
    --output-dir "$TMPDIR/out" \
    >"$TMPDIR/batch.log" 2>&1 || {
    echo "FAIL: replay-batch.sh exited non-zero"
    cat "$TMPDIR/batch.log"
    exit 1
}

cells=$(ls -1 "$TMPDIR/out"/*/aggregator-output.md 2>/dev/null | wc -l)
expected=6
if [ "$cells" != "$expected" ]; then
    echo "FAIL: expected $expected cells (3 PRs × 2 prompt sets), got $cells — stdin-consumption regression"
    echo "--- batch log ---"
    cat "$TMPDIR/batch.log"
    echo "--- cells ---"
    ls -1 "$TMPDIR/out"/ 2>&1
    exit 1
fi

# Index should have one row per PR (header + 3 PR rows + separator).
pr_rows=$(grep -cE '^\| .*owner/repo[ABC]#' "$TMPDIR/out/index.md" 2>/dev/null || echo 0)
if [ "$pr_rows" != "3" ]; then
    echo "FAIL: index.md should list 3 PR rows, got $pr_rows"
    cat "$TMPDIR/out/index.md"
    exit 1
fi

echo "PASS"
