#!/bin/bash
# Hourly: rebuild ~/.pr-reviewer/specialist-bakeoff.md from posted bot
# reviews + trusted-human /srosro-memorize comments across tracked repos.
#
# Pure post-hoc measurement: read GitHub state, write a markdown table.
# No pipeline changes, no extra LLM calls, no new state coupling.
#
# WHAT IT MEASURES (rolling 30-day window):
#   - shipped:  count of [from: <specialist>] attributions in posted reviews
#   - loved:    count of /srosro-memorize comments by trusted humans where
#               the body quoted a [from: <specialist>] tag
#   - reviews:  total review comments observed (for normalization)
#
# WHAT IT DOESN'T MEASURE:
#   - findings emitted-but-dropped pre-aggregator (specialist files don't
#     persist past the run); see plan doc for the trade.
#   - sentiment on memorize bodies (opt-in is the signal, not text valence).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "FATAL: bash required"; exit 1; }

# ---- config ----
STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
WINDOW_DAYS="${WINDOW_DAYS:-30}"
OUT_FILE="${OUT_FILE:-$STATE_DIR/specialist-bakeoff.md}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/bakeoff.log}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$STATE_DIR"

# Source repos.conf for the REPOS array (same source-of-truth as every
# other script; if the operator adds a tracked repo, the bake-off picks
# it up automatically).
. "$SCRIPT_DIR/repos.conf"

# Source the parsers + trust-gate (shared with review.sh and
# learn-from-replies.sh). Provides count_attributions,
# extract_memorize_attributions, and is_trusted_repo_author.
. "$SCRIPT_DIR/lib/bakeoff-parsers.sh"

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }

# ---- per-repo collection ----
SINCE_ISO=$(date -u -d "$WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v "-${WINDOW_DAYS}d" +%Y-%m-%dT%H:%M:%SZ)

# Accumulate attributions in temp files: one specialist name per line.
shipped_tmp=$(mktemp)
loved_tmp=$(mktemp)
trap 'rm -f "$shipped_tmp" "$loved_tmp"' EXIT

review_count=0

# In-memory trust cache: avoid repeated collaborator API calls for the
# same user within a single run. Key: "<repo>/<user>", value: "0" or "1".
declare -A _trusted_cache=()

trusted_cached() {
    local repo="$1" user="$2"
    local key="$repo/$user"
    if [[ -v _trusted_cache["$key"] ]]; then
        return "${_trusted_cache[$key]}"
    fi
    if is_trusted_repo_author "$repo" "$user"; then
        _trusted_cache["$key"]=0
        return 0
    else
        _trusted_cache["$key"]=1
        return 1
    fi
}

for repo in "${REPOS[@]}"; do
    log "scanning $repo since $SINCE_ISO..."

    # Fetch all issue comments (where bot posts reviews) in the window.
    # --paginate handles high-volume repos. jq -s merges the pages.
    comments_json=$(gh api --paginate \
        "repos/$repo/issues/comments?since=$SINCE_ISO" \
        2>>"$LOG_FILE" | jq -s 'add // []') \
        || { log "WARN: gh api failed for $repo, skipping"; continue; }

    # Bot reviews: contain the auto-post marker and are NOT the 👀 placeholder.
    # Count via jq (avoids grep-on-multiline-body problems); emit bodies for
    # attribution parsing.
    this_count=$(printf '%s' "$comments_json" \
        | jq '[.[] | select(
            .body | (contains("<!-- knightwatch-reviewer:auto-post -->")
                     and (contains("👀 reviewing") | not))
          )] | length')
    review_count=$((review_count + this_count))

    printf '%s' "$comments_json" \
        | jq -r '.[] | select(
            .body | (contains("<!-- knightwatch-reviewer:auto-post -->")
                     and (contains("👀 reviewing") | not))
          ) | .body' \
        | count_attributions >> "$shipped_tmp"

    # Memorize signals: /srosro-memorize comments by trusted humans.
    # Exclude bot ACKs (they contain the auto-post marker and quote the
    # original /srosro-memorize body, which would double-count attributions).
    while IFS=$'\t' read -r author body; do
        [ -z "$author" ] && continue
        if trusted_cached "$repo" "$author"; then
            printf '%s' "$body" | extract_memorize_attributions >> "$loved_tmp"
        fi
    done < <(printf '%s' "$comments_json" \
        | jq -r '.[] | select(
              (.body | test("/srosro-memorize"; "i"))
              and (.body | contains("<!-- knightwatch-reviewer:auto-post -->") | not)
          ) | [.user.login, .body] | @tsv')
done

log "scanned $review_count bot reviews across ${#REPOS[@]} repos"

# ---- assemble the table ----
shipped_counts=$(sort "$shipped_tmp" | uniq -c | awk '{print $2"\t"$1}' || true)
loved_counts=$(sort "$loved_tmp" | uniq -c | awk '{print $2"\t"$1}' || true)

# Union of all specialist names seen in either column.
all_specialists=$( (sort -u "$shipped_tmp"; sort -u "$loved_tmp") | sort -u | grep -v '^$' || true)

{
    echo "# Specialist bake-off — last $WINDOW_DAYS days"
    echo
    echo "_Generated $(date -u +%FT%TZ) from $review_count posted reviews across ${#REPOS[@]} tracked repos. See \`docs/plans/2026-05-04-specialist-bakeoff.md\` for measurement notes._"
    echo
    echo "| Specialist | Shipped | Loved | Loved/Shipped |"
    echo "|---|---:|---:|---:|"
    if [ -n "$all_specialists" ]; then
        while read -r spec; do
            [ -z "$spec" ] && continue
            shipped=$(printf '%s\n' "$shipped_counts" | awk -v s="$spec" '$1==s{print $2; exit}')
            loved=$(printf '%s\n' "$loved_counts" | awk -v s="$spec" '$1==s{print $2; exit}')
            shipped=${shipped:-0}
            loved=${loved:-0}
            if [ "$shipped" -gt 0 ]; then
                ratio=$(awk -v l="$loved" -v s="$shipped" 'BEGIN{printf "%.2f", l/s}')
            else
                ratio="—"
            fi
            echo "| $spec | $shipped | $loved | $ratio |"
        done <<< "$all_specialists" | sort -t'|' -k3,3rn
    fi
} > "$OUT_FILE"

log "wrote $OUT_FILE"
echo "OK: $OUT_FILE"
