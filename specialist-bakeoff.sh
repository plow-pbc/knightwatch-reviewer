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
mkdir -p "$STATE_DIR"

BOT_USER="${BOT_USER:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# Tracked-repo manifest (single source of truth in repos.conf). The
# shared loader at lib/tracked-repos.sh is the ONE seam every consumer
# goes through.  It also pins TMPDIR=$STATE_DIR/tmp so mktemp works
# correctly under systemd PrivateTmp=yes.
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
[ ${#REPOS[@]} -ge 1 ] || { echo "FATAL: no tracked repos — populate $STATE_DIR/repos.conf or set REPOS in config.env" >&2; exit 1; }

# Source the parsers (pure stdin/stdout — count_attributions,
# extract_memorize_attributions) and the trust-gate (is_trusted_repo_author).
. "$REVIEWER_LIB_DIR/bakeoff-parsers.sh"
. "$REVIEWER_LIB_DIR/auth.sh"

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }

# ---- per-repo collection ----
SINCE_ISO=$(date -u -d "$WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v "-${WINDOW_DAYS}d" +%Y-%m-%dT%H:%M:%SZ)

# Accumulate attributions in temp files: one specialist name per line.
shipped_tmp=$(mktemp)
loved_tmp=$(mktemp)
trap 'rm -f "$shipped_tmp" "$loved_tmp"' EXIT

review_count=0
fetch_failures=0

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
        || { log "WARN: gh api failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); continue; }

    # Substantive bot reviews: posted by BOT_USER, contain the auto-post
    # marker, are NOT the 👀 ACK placeholder, and DO contain the final-review
    # footer ("How to use: auto-reviews").  The footer fence is load-bearing:
    # same-bot ACK comments have the marker but not the footer, so marker alone
    # is insufficient.  jq args avoid hardcoding these values inline.
    this_count=$(printf '%s' "$comments_json" \
        | jq --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             '[.[] | select(
                .user.login == $bot_user
                and (.body | contains($marker))
                and (.body | contains("👀 reviewing") | not)
                and (.body | contains("How to use: auto-reviews"))
              )] | length')
    review_count=$((review_count + this_count))

    printf '%s' "$comments_json" \
        | jq -r --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             '.[] | select(
                .user.login == $bot_user
                and (.body | contains($marker))
                and (.body | contains("👀 reviewing") | not)
                and (.body | contains("How to use: auto-reviews"))
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
        | jq -r --arg marker "$BOT_AUTO_POST_MARKER" \
              '.[] | select(
                  (.body | test("/srosro-memorize"; "i"))
                  and (.body | contains($marker) | not)
              ) | [.user.login, .body] | @tsv')
done

log "scanned $review_count bot reviews across ${#REPOS[@]} repos"

if [ "$fetch_failures" -gt 0 ]; then
    log "PARTIAL RUN: $fetch_failures repo(s) failed to fetch — NOT overwriting $OUT_FILE"
    echo "PARTIAL: $fetch_failures repo(s) failed; $OUT_FILE not updated" >&2
    exit 1
fi

# ---- assemble the table ----
shipped_counts=$(sort "$shipped_tmp" | uniq -c | awk '{print $2"\t"$1}')
loved_counts=$(sort "$loved_tmp" | uniq -c | awk '{print $2"\t"$1}')

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
