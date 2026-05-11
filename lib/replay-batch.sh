#!/usr/bin/env bash
# Run lib/replay.sh across the cross-product of (PR list) × (prompt sets)
# and emit a side-by-side index for human comparison. The intended
# workflow: pick ~10 PRs you want to A/B against, point the batch at
# two prompts/ directories (e.g. baseline + experiment), eyeball the
# output table.
#
# Usage:
#   ./lib/replay-batch.sh \
#       --prs PRS_CSV \
#       --prompts DIR1,DIR2[,DIR3...] \
#       [--output-dir BATCH_DIR]
#
# PRS_CSV format: one `repo,pr,sha` per non-blank, non-comment line.
#   srosro/knightwatch-reviewer,42,abc1234
#   facebook/react,28471,def5678
#   # comments and blank lines are skipped
#
# Per-cell outputs land under BATCH_DIR/<repo-slug>-<pr>-<sha7>-<promptset>/.
# Index lands at BATCH_DIR/index.md with one row per PR, one column per
# prompt set, cells linking to that cell's aggregator-output.md.
#
# Failures: if a single replay fails, the cell records "FAILED" and the
# batch keeps going — partial results are more useful than aborting on
# the first stuck PR.
#
# Trust boundary inherits from lib/replay.sh — see that file's header.
set -euo pipefail

PRS=""; PROMPTS=""; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prs) PRS="$2"; shift 2 ;;
        --prompts) PROMPTS="$2"; shift 2 ;;
        --output-dir) OUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$PRS" ] && [ -n "$PROMPTS" ] || {
    echo "usage: $0 --prs PRS_CSV --prompts DIR1,DIR2[,...] [--output-dir DIR]" >&2
    exit 2
}
[ -f "$PRS" ] || { echo "error: PRS_CSV not found: $PRS" >&2; exit 2; }

# Default to operator-local replay tree — see lib/replay.sh for rationale.
OUT="${OUT:-$HOME/.pr-reviewer/replays/batch-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$LIB_DIR/replay-paths.sh"
INDEX="$OUT/index.md"
IFS=',' read -ra PROMPT_LIST <<<"$PROMPTS"

# Build the index header. One column per prompt set, labeled by basename.
{
    printf '# Replay batch — %s\n\n' "$(date -u +%Y-%m-%dT%H:%MZ)"
    printf 'PRs: `%s`\n\n' "$PRS"
    printf '| PR |'
    for p in "${PROMPT_LIST[@]}"; do
        printf ' %s |' "$(basename "$p")"
    done
    printf '\n|---|'
    for _ in "${PROMPT_LIST[@]}"; do
        printf -- '---|'
    done
    printf '\n'
} > "$INDEX"

# Run the cross product. Each (pr, prompt_dir) pair invokes replay.sh
# with an explicit --output-dir under $OUT so all artifacts land together.
while IFS=',' read -r repo pr sha; do
    repo="${repo// /}"; pr="${pr// /}"; sha="${sha// /}"
    [ -z "$repo" ] && continue
    [[ "$repo" == \#* ]] && continue

    pr_label="$repo#$pr @${sha:0:7}"
    echo ">>> $pr_label"
    printf '| %s |' "$pr_label" >> "$INDEX"

    for prompts_dir in "${PROMPT_LIST[@]}"; do
        slug="$(replay_prompt_slug "$prompts_dir")"
        cell_dir="$OUT/$(replay_run_dir "$repo" "$pr" "$sha" "$slug")"
        echo "    [$slug] → $cell_dir"
        # </dev/null is load-bearing: the outer `while read ... done <"$PRS"`
        # iterates the CSV via stdin, and replay.sh invokes codex which
        # reads stdin unconditionally. Without this isolation, codex
        # consumes the rest of the CSV and only the first PR ever runs
        # (observed in batch-pr70-perf-compare's initial run before the
        # fix landed — 1/3 canaries processed, two silently dropped).
        if "$LIB_DIR/replay.sh" \
                --repo "$repo" --pr "$pr" --sha "$sha" \
                --prompts "$prompts_dir" --output-dir "$cell_dir" \
                </dev/null >"$cell_dir.batch.log" 2>&1
        then
            rel="$(basename "$cell_dir")/aggregator-output.md"
            printf ' [%s](%s) |' "$slug" "$rel" >> "$INDEX"
        else
            rc=$?
            printf ' FAILED rc=%s ([log](%s.batch.log)) |' "$rc" "$(basename "$cell_dir")" >> "$INDEX"
        fi
    done
    printf '\n' >> "$INDEX"
done < "$PRS"

echo
echo "batch complete: $INDEX"
