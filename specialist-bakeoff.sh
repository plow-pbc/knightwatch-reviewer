#!/bin/bash
# Hourly: walk new GitHub state into ~/.pr-reviewer/bakeoff.db and
# regenerate ~/.pr-reviewer/specialist-bakeoff.md.
#
# Architecture: walker (writes to SQLite store, watermark per repo) →
# reporter (queries the store, renders markdown). The store is the
# source of truth for time-series; the markdown is a snapshot view.
#
# The 30-day window is now a query parameter, not an API-cost ceiling —
# subsequent walks only fetch comments newer than the per-repo watermark
# (with OVERLAP_HOURS slack for late-edited memorize comments).
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "FATAL: bash required"; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
WINDOW_DAYS="${WINDOW_DAYS:-30}"
OVERLAP_HOURS="${OVERLAP_HOURS:-24}"
DB_FILE="${DB_FILE:-$STATE_DIR/bakeoff.db}"
OUT_FILE="${OUT_FILE:-$STATE_DIR/specialist-bakeoff.md}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/bakeoff.log}"
mkdir -p "$STATE_DIR"

BOT_USER="${BOT_USER:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
[ ${#REPOS[@]} -ge 1 ] || { echo "FATAL: no tracked repos — populate $STATE_DIR/repos.conf or set REPOS in config.env" >&2; exit 1; }

. "$REVIEWER_LIB_DIR/bakeoff-parsers.sh"
. "$REVIEWER_LIB_DIR/bakeoff-store.sh"

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG_FILE"; }

store_init "$DB_FILE"

SUBSTANTIVE_REVIEW_JQ='.user.login == $bot_user
    and (.body | contains($marker))
    and (.body | contains("👀 reviewing") | not)
    and (.body | contains("How to use: auto-reviews"))'

walked_reviews=0
fetch_failures=0

for repo in "${REPOS[@]}"; do
    repo_failures=0
    window_floor=$(date -u -d "$WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || date -u -v "-${WINDOW_DAYS}d" +%Y-%m-%dT%H:%M:%SZ)
    watermark=$(get_walk_watermark "$DB_FILE" "$repo")
    if [ -n "$watermark" ]; then
        slack_floor=$(date -u -d "$watermark -$OVERLAP_HOURS hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                     || date -u -v "-${OVERLAP_HOURS}H" -j -f "%Y-%m-%dT%H:%M:%SZ" "$watermark" +%Y-%m-%dT%H:%M:%SZ)
        if [[ "$slack_floor" > "$window_floor" ]]; then
            since="$slack_floor"
        else
            since="$window_floor"
        fi
    else
        since="$window_floor"
    fi
    log "scanning $repo since $since (watermark=${watermark:-<none>})..."

    comments_json=$(gh api --paginate \
        "repos/$repo/issues/comments?since=$since" \
        2>>"$LOG_FILE" | jq -s 'add // []') \
        || { log "WARN: gh api comments failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); repo_failures=$((repo_failures + 1)); continue; }

    trusted_set=$(gh api --paginate "repos/$repo/collaborators?affiliation=direct" 2>>"$LOG_FILE" \
        | jq -rs '[.[][]] | map(select(.permissions.push == true) | .login) | .[]') \
        || { log "WARN: gh api collaborators failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); repo_failures=$((repo_failures + 1)); continue; }

    declare -A pr_paths_cache=()
    declare -A pr_files_cache=()

    # Pass 1: walk substantive bot reviews. Each row is one (review × specialist).
    # The roster marker drives row creation; probe parsing drives flag updates.
    max_review_ts=""
    while IFS=$'\t' read -r review_id issue_url created_at review_body; do
        [ -z "$review_id" ] && continue
        pr_num="${issue_url##*/}"
        review_body=$(printf '%b' "$review_body")

        # Roster: which specialists were invoked. Skip review entirely if
        # no marker (legacy review pre-roster — no denominator data).
        roster=$(printf '%s\n' "$review_body" | extract_roster_marker)
        [ -z "$roster" ] && continue

        while IFS= read -r specialist; do
            [ -z "$specialist" ] && continue
            upsert_specialist_run "$DB_FILE" "$repo" "$review_id" "$specialist" "$pr_num" "$created_at"
        done <<< "$roster"

        # Mark published: any [from: <specialist>] in probe lines.
        printf '%s\n' "$review_body" \
            | count_attributions \
            | sort -u \
            | while IFS= read -r specialist; do
                [ -z "$specialist" ] && continue
                mark_published "$DB_FILE" "$repo" "$review_id" "$specialist"
              done

        # Mark applied: per specialist (deduped across its probes), intersect
        # cited paths with PR touched paths and sum LOC across matched paths.
        cache_key="${repo}#${pr_num}"
        if [[ -z "${pr_paths_cache[$cache_key]+set}" ]]; then
            if pr_files_tsv=$(gh api --paginate "repos/$repo/pulls/$pr_num/files" --jq '.[] | [.filename, .additions, .deletions] | @tsv' 2>>"$LOG_FILE"); then
                pr_files_cache["$cache_key"]="$pr_files_tsv"
                pr_paths_cache["$cache_key"]=$(printf '%s\n' "$pr_files_tsv" | cut -f1)
            else
                log "WARN: gh api pulls/files failed for $repo#$pr_num, skipping applied check"
                fetch_failures=$((fetch_failures + 1))
                repo_failures=$((repo_failures + 1))
                pr_paths_cache["$cache_key"]=""
                pr_files_cache["$cache_key"]=""
            fi
        fi
        pr_paths="${pr_paths_cache[$cache_key]}"
        if [ -n "$pr_paths" ]; then
            # Collect deduped (specialist, path) pairs across all probes in this review.
            declare -A spec_paths_seen=()
            while IFS= read -r probe_line; do
                specialist=$(printf '%s\n' "$probe_line" | count_attributions || true)
                [ -z "$specialist" ] && continue
                while IFS= read -r p; do
                    [ -z "$p" ] && continue
                    spec_paths_seen["${specialist}	${p}"]=1
                done < <(printf '%s\n' "$probe_line" | probe_cited_paths)
            done < <(printf '%s\n' "$review_body" | grep -E '^[0-9]+\.' || true)

            # Per specialist: sum LOC across paths that touched the PR; mark + record.
            declare -A spec_added=()
            declare -A spec_removed=()
            declare -A spec_matched=()
            pr_files_tsv="${pr_files_cache[$cache_key]}"
            for key in "${!spec_paths_seen[@]}"; do
                specialist="${key%%	*}"
                path="${key#*	}"
                if grep -qFx "$path" <<< "$pr_paths"; then
                    loc_line=$(printf '%s\n' "$pr_files_tsv" | awk -F'\t' -v p="$path" '$1==p {print $2"\t"$3; exit}')
                    a=$(printf '%s' "$loc_line" | cut -f1)
                    r=$(printf '%s' "$loc_line" | cut -f2)
                    spec_added["$specialist"]=$((${spec_added[$specialist]:-0} + ${a:-0}))
                    spec_removed["$specialist"]=$((${spec_removed[$specialist]:-0} + ${r:-0}))
                    spec_matched["$specialist"]=1
                fi
            done
            for specialist in "${!spec_matched[@]}"; do
                mark_applied "$DB_FILE" "$repo" "$review_id" "$specialist"
                set_applied_loc "$DB_FILE" "$repo" "$review_id" "$specialist" \
                    "${spec_added[$specialist]:-0}" "${spec_removed[$specialist]:-0}"
            done
            unset spec_paths_seen spec_added spec_removed spec_matched
        fi

        walked_reviews=$((walked_reviews + 1))
        if [[ "$created_at" > "$max_review_ts" ]]; then
            max_review_ts="$created_at"
        fi
    done < <(printf '%s' "$comments_json" \
        | jq -r --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" \
             ".[] | select($SUBSTANTIVE_REVIEW_JQ) | [.id, .issue_url, .created_at, .body] | @tsv")

    # Pass 2: feedback comments. For each feedback signal, find the most-recent
    # substantive bot review on the same PR before the feedback's created_at,
    # and mark the corresponding flag on (review, specialist) rows.
    while IFS=$'\t' read -r author issue_url body created_at; do
        [ -z "$author" ] && continue
        grep -qFx "$author" <<< "$trusted_set" || continue
        pr_num="${issue_url##*/}"
        body_decoded=$(printf '%b' "$body")

        positives=$( { printf '%s\n' "$body_decoded" | extract_kw_props_attributions
                       printf '%s\n' "$body_decoded" | extract_memorize_attributions
                     } | sort -u | grep -v '^$' || true)
        negatives=$(printf '%s\n' "$body_decoded" | extract_kw_critique_attributions)

        if [ -n "$positives" ] || [ -n "$negatives" ]; then
            # Attribution rule: feedback (kw-props/kw-critique/srosro-memorize) credits
            # the MOST-RECENT prior review on the same PR, regardless of whether that
            # review's roster actually included the quoted specialist. Rationale:
            # (a) human feedback typically lands within hours of the review they're
            #     reacting to, so "most recent" is almost always the right one;
            # (b) per-review drill-down is out of scope for the current bake-off
            #     (aggregates by specialist over a window — this is fine);
            # (c) if a future column needs sharper attribution (e.g. "which review
            #     was loved?"), the feedback comment's quoted specialist should be
            #     intersected with the target review's roster — not done here yet.
            target_review=$(find_target_review_for_feedback "$DB_FILE" "$repo" "$pr_num" "$created_at")
            [ -z "$target_review" ] && continue
            while IFS= read -r specialist; do
                [ -z "$specialist" ] && continue
                mark_loved_positive "$DB_FILE" "$repo" "$target_review" "$specialist"
            done <<< "$positives"
            while IFS= read -r specialist; do
                [ -z "$specialist" ] && continue
                mark_loved_negative "$DB_FILE" "$repo" "$target_review" "$specialist"
            done <<< "$negatives"
        fi
    done < <(printf '%s' "$comments_json" \
        | jq -r --arg marker "$BOT_AUTO_POST_MARKER" \
              '.[] | select(
                  ((.body | test("^/kw-props "; "m"))
                   or (.body | test("^/kw-critique "; "m"))
                   or (.body | test("/srosro-memorize"; "i")))
                  and (.body | contains($marker) | not)
              ) | [.user.login, .issue_url, .body, .created_at] | @tsv')

    if [ "$repo_failures" -eq 0 ]; then
        if [ -n "$max_review_ts" ]; then
            set_walk_watermark "$DB_FILE" "$repo" "$max_review_ts"
        else
            set_walk_watermark "$DB_FILE" "$repo" "$(date -u +%FT%TZ)"
        fi
    fi
done

log "walked $walked_reviews bot reviews across ${#REPOS[@]} repos"

if [ "$fetch_failures" -gt 0 ]; then
    log "PARTIAL RUN: $fetch_failures fetch failure(s) — store may be missing rows but NOT overwriting $OUT_FILE"
    echo "PARTIAL: $fetch_failures fetch failure(s); $OUT_FILE not updated" >&2
    exit 1
fi

# ---- reporter: render markdown from store ----
window_iso=$(date -u -d "$WINDOW_DAYS days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v "-${WINDOW_DAYS}d" +%Y-%m-%dT%H:%M:%SZ)
total_reviews=$(sqlite3 "$DB_FILE" \
    "SELECT COUNT(DISTINCT comment_id) FROM specialist_runs WHERE ran_at >= '$window_iso';")

{
    echo "# Specialist bake-off — last $WINDOW_DAYS days"
    echo
    echo "_Generated $(date -u +%FT%TZ) from $total_reviews posted reviews across ${#REPOS[@]} tracked repos. Source: \`$DB_FILE\`._"
    echo
    if [ "$total_reviews" = "0" ]; then
        echo "_Awaiting first reviews with the roster marker — table populates as new reviews land._"
    else
        echo "| Specialist | Reviews | Shipped | Applied | +LOC | -LOC | Loved | Critiqued | Loved/Shipped |"
        echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
        query_window_aggregates "$DB_FILE" "$window_iso" \
        | while IFS=$'\t' read -r spec reviews shipped applied added removed loved critiqued; do
            if [ "$shipped" -gt 0 ]; then
                ratio=$(awk -v l="$loved" -v s="$shipped" 'BEGIN{printf "%.2f", l/s}')
            else
                ratio="—"
            fi
            echo "| $spec | $reviews | $shipped | $applied | $added | $removed | $loved | $critiqued | $ratio |"
        done
    fi
} > "$OUT_FILE"

log "wrote $OUT_FILE"
echo "OK: $OUT_FILE"
