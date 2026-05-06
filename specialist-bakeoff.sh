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
# extract_memorize_attributions).
. "$REVIEWER_LIB_DIR/bakeoff-parsers.sh"

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }

# ---- per-repo collection ----
SINCE_ISO=$(date -u -d "$WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v "-${WINDOW_DAYS}d" +%Y-%m-%dT%H:%M:%SZ)

# Accumulate attributions in temp files: one specialist name per line.
shipped_tmp=$(mktemp)
loved_tmp=$(mktemp)
applied_tmp=$(mktemp)
declare -A pr_paths_cache=()    # cache: "<repo>#<pr>" → newline-joined paths
trap 'rm -f "$shipped_tmp" "$loved_tmp" "$applied_tmp"' EXIT

review_count=0
fetch_failures=0

# Substantive bot review selector — used by both review_count and
# attribution extraction below. ONE source of truth for the rules
# (bot user, marker, ACK exclusion, footer fence). The footer fence
# distinguishes posted reviews from same-bot ACK comments.
SUBSTANTIVE_REVIEW_JQ='.user.login == $bot_user
    and (.body | contains($marker))
    and (.body | contains("👀 reviewing") | not)
    and (.body | contains("How to use: auto-reviews"))'

for repo in "${REPOS[@]}"; do
    log "scanning $repo since $SINCE_ISO..."

    # Fetch all issue comments (where bot posts reviews) in the window.
    # --paginate handles high-volume repos. jq -s merges the pages.
    comments_json=$(gh api --paginate \
        "repos/$repo/issues/comments?since=$SINCE_ISO" \
        2>>"$LOG_FILE" | jq -s 'add // []') \
        || { log "WARN: gh api comments failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); continue; }

    # Bulk-fetch trusted set (push-access collaborators).
    # Same fail-loud contract as the comment fetch — bumps fetch_failures
    # and skips this repo on lookup failure, so a transient gh hiccup can't
    # silently drop a trusted memorize from the Loved column.
    trusted_set=$(gh api --paginate "repos/$repo/collaborators?affiliation=direct" 2>>"$LOG_FILE" \
        | jq -rs '[.[][]] | map(select(.permissions.push == true) | .login) | .[]') \
        || { log "WARN: gh api collaborators failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); continue; }

    this_count=$(printf '%s' "$comments_json" \
        | jq --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             "[.[] | select($SUBSTANTIVE_REVIEW_JQ)] | length")
    review_count=$((review_count + this_count))

    printf '%s' "$comments_json" \
        | jq -r --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             ".[] | select($SUBSTANTIVE_REVIEW_JQ) | .body" \
        | count_attributions >> "$shipped_tmp"

    # Applied column: for each substantive bot review's body + its issue PR,
    # extract probe-cited paths, look up the PR's touched paths (cached),
    # and if any probe's paths intersect the PR's touched set, credit the
    # probe's specialist with an Applied attribution.
    while IFS=$'\t' read -r issue_url review_body; do
        [ -z "$issue_url" ] && continue
        pr_num="${issue_url##*/}"
        cache_key="${repo}#${pr_num}"
        if [[ -z "${pr_paths_cache[$cache_key]+set}" ]]; then
            if pr_paths_lookup=$(gh api --paginate "repos/$repo/pulls/$pr_num/files" --jq '.[].filename' 2>>"$LOG_FILE"); then
                pr_paths_cache["$cache_key"]="$pr_paths_lookup"
            else
                log "WARN: gh api pulls/files failed for $repo#$pr_num, skipping"
                fetch_failures=$((fetch_failures + 1))
                continue
            fi
        fi
        pr_paths="${pr_paths_cache[$cache_key]}"
        [ -z "$pr_paths" ] && continue

        # Walk each probe line; emit "<specialist>" if any cited path matches.
        while IFS= read -r probe_line; do
            specialist=$(printf '%s\n' "$probe_line" | count_attributions || true)
            [ -z "$specialist" ] && continue

            cited_paths=$(printf '%s\n' "$probe_line" | probe_cited_paths)
            [ -z "$cited_paths" ] && continue

            # Set-intersection: any cited path in the PR's touched set?
            if printf '%s\n' "$cited_paths" \
                | grep -qFxf <(printf '%s\n' "$pr_paths"); then
                echo "$specialist" >> "$applied_tmp"
            fi
        done < <(printf '%b\n' "$review_body" | grep -E '^[0-9]+\.' || true)
    done < <(printf '%s' "$comments_json" \
        | jq -r --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             ".[] | select($SUBSTANTIVE_REVIEW_JQ) | [.issue_url, .body] | @tsv")

    # Memorize signals: /srosro-memorize comments by trusted humans.
    # Exclude bot ACKs (they contain the auto-post marker and quote the
    # original /srosro-memorize body, which would double-count attributions).
    while IFS=$'\t' read -r author body; do
        [ -z "$author" ] && continue
        if grep -qFx "$author" <<< "$trusted_set"; then
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

# Union of all specialist names seen in any column.
all_specialists=$( (sort -u "$shipped_tmp"; sort -u "$loved_tmp"; sort -u "$applied_tmp") | sort -u | grep -v '^$' || true)

{
    echo "# Specialist bake-off — last $WINDOW_DAYS days"
    echo
    echo "_Generated $(date -u +%FT%TZ) from $review_count posted reviews across ${#REPOS[@]} tracked repos._"
    echo
    echo "| Specialist | Shipped | Applied | Loved | Loved/Shipped |"
    echo "|---|---:|---:|---:|---:|"
    if [ -n "$all_specialists" ]; then
        applied_counts=$(sort "$applied_tmp" | uniq -c | awk '{print $2"\t"$1}')
        while read -r spec; do
            [ -z "$spec" ] && continue
            shipped=$(printf '%s\n' "$shipped_counts" | awk -v s="$spec" '$1==s{print $2; exit}')
            applied=$(printf '%s\n' "$applied_counts" | awk -v s="$spec" '$1==s{print $2; exit}')
            loved=$(printf '%s\n' "$loved_counts" | awk -v s="$spec" '$1==s{print $2; exit}')
            shipped=${shipped:-0}
            applied=${applied:-0}
            loved=${loved:-0}
            if [ "$shipped" -gt 0 ]; then
                ratio=$(awk -v l="$loved" -v s="$shipped" 'BEGIN{printf "%.2f", l/s}')
            else
                ratio="—"
            fi
            echo "| $spec | $shipped | $applied | $loved | $ratio |"
        done <<< "$all_specialists" | sort -t'|' -k3,3rn
    fi
} > "$OUT_FILE"

log "wrote $OUT_FILE"
echo "OK: $OUT_FILE"
