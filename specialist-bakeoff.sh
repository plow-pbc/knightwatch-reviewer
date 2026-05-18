#!/bin/bash
# Hourly: walk new GitHub state into ~/.pr-reviewer/bakeoff.db and
# regenerate ~/.pr-reviewer/specialist-bakeoff.md.
#
# Architecture: walker (writes to SQLite store) → reporter (queries the
# store, renders markdown). Walker fetches the full WINDOW_DAYS comment
# window every cron so every in-window review gets edited_after re-
# evaluated against the current commit graph — an older in-window
# review whose post-review commit landed between cron runs must still
# get its flag flipped/cleared, which an incremental-since-watermark
# fetch would miss once newer reviews advance the watermark past it.
set -euo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo "FATAL: bash required"; exit 1; }

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
# REWALK_HOURS bounds the walker's per-repo comment-fetch floor (with
# last_walked_at as the further-back fallback for missed-cron backfill).
# SCORECARD_DAYS bounds the renderer's scorecard horizon — read from the
# persistent store, independent of walker state.
REWALK_HOURS="${REWALK_HOURS:-24}"
SCORECARD_DAYS="${SCORECARD_DAYS:-14}"
DB_FILE="${DB_FILE:-$STATE_DIR/bakeoff.db}"
OUT_FILE="${OUT_FILE:-$STATE_DIR/specialist-bakeoff.md}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/bakeoff.log}"
mkdir -p "$STATE_DIR"

BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
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
    and (.body | contains("How to use: auto-reviews"))
    and (.created_at >= $window_floor)'

walked_reviews=0
fetch_failures=0

for repo in "${REPOS[@]}"; do
    repo_failures=0
    rewalk_floor=$(date -u -d "$REWALK_HOURS hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
                  || date -u -v "-${REWALK_HOURS}H" +%Y-%m-%dT%H:%M:%SZ)
    last_walked=$(get_last_walked_at "$DB_FILE" "$repo")
    # Walk floor: the EARLIER of (REWALK_HOURS_ago, last_walked_at). The
    # rewalk floor refreshes edited_after on recent reviews; last_walked_at
    # extends the scan further back when crons were missed. ISO8601 strings
    # sort lexicographically the same as chronologically.
    if [ -n "$last_walked" ] && [ "$last_walked" \< "$rewalk_floor" ]; then
        window_floor="$last_walked"
    else
        window_floor="$rewalk_floor"
    fi
    log "scanning $repo since $window_floor (rewalk_floor=$rewalk_floor last_walked=${last_walked:-never})..."

    comments_json=$(gh api --paginate \
        "repos/$repo/issues/comments?since=$window_floor" \
        2>>"$LOG_FILE" | jq -s 'add // []') \
        || { log "WARN: gh api comments failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); repo_failures=$((repo_failures + 1)); continue; }

    trusted_set=$(gh api --paginate "repos/$repo/collaborators?affiliation=direct" 2>>"$LOG_FILE" \
        | jq -rs '[.[][]] | map(select(.permissions.push == true) | .login) | .[]') \
        || { log "WARN: gh api collaborators failed for $repo, skipping"; fetch_failures=$((fetch_failures + 1)); repo_failures=$((repo_failures + 1)); continue; }

    declare -A pr_paths_cache=()
    declare -A pr_files_cache=()
    declare -A pr_files_ok_cache=()
    declare -A pr_post_paths_cache=()
    declare -A pr_post_paths_ok_cache=()

    # Pass 1: walk substantive bot reviews. Each row is one (review × specialist).
    # The roster marker drives row creation; probe parsing drives flag updates.
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
                pr_files_ok_cache["$cache_key"]="1"
            else
                log "WARN: gh api pulls/files failed for $repo#$pr_num, skipping applied check"
                fetch_failures=$((fetch_failures + 1))
                repo_failures=$((repo_failures + 1))
                pr_paths_cache["$cache_key"]=""
                pr_files_cache["$cache_key"]=""
                pr_files_ok_cache["$cache_key"]="0"
            fi
        fi
        pr_paths="${pr_paths_cache[$cache_key]}"
        pr_files_ok="${pr_files_ok_cache[$cache_key]}"
        # Track max severity per specialist across the review's probes. Runs
        # unconditionally (severity is a property of the review body, not the PR
        # diff — so it should be tracked even when pulls/files fails).
        declare -A spec_max_sev=()
        while IFS= read -r probe_line; do
            specialist=$(printf '%s\n' "$probe_line" | count_attributions || true)
            [ -z "$specialist" ] && continue
            sev=$(printf '%s\n' "$probe_line" | probe_severity)
            [ -z "$sev" ] && continue
            cur="${spec_max_sev[$specialist]:-}"
            if [ "$(severity_rank "$sev")" -gt "$(severity_rank "$cur")" ]; then
                spec_max_sev["$specialist"]="$sev"
            fi
        done < <(printf '%s\n' "$review_body" | grep -E '^[0-9]+\.' || true)
        for specialist in "${!spec_max_sev[@]}"; do
            set_max_severity "$DB_FILE" "$repo" "$review_id" "$specialist" "${spec_max_sev[$specialist]}"
        done
        unset spec_max_sev
        # Per-PR set of paths touched by commits LANDING AFTER the review's
        # created_at — fetched lazily (once per cache_key) and intersected
        # with each specialist's cited paths to drive `edited_after`. A
        # pulls/commits or commits/<sha> failure logs WARN and marks
        # post_paths_ok=0; downstream skips both clear and recompute so a
        # transient failure can't erase a previously-correct edited_after.
        post_review_key="${cache_key}#after#${created_at}"
        if [[ -z "${pr_post_paths_cache[$post_review_key]+set}" ]]; then
            post_paths=""
            post_paths_ok=1
            if commits_json=$(gh api --paginate "repos/$repo/pulls/$pr_num/commits" 2>>"$LOG_FILE"); then
                # committer.date (not author.date) is the "landed on branch" timestamp —
                # rebased or prewritten commits keep their original author.date but get
                # a fresh committer.date when they land, which is what "after the review"
                # needs to mean for Edited to count correctly.
                shas=$(printf '%s\n' "$commits_json" \
                    | jq -rs --arg t "$created_at" 'add // [] | .[] | select(.commit.committer.date > $t) | .sha')
                while IFS= read -r sha; do
                    [ -z "$sha" ] && continue
                    if commit_json=$(gh api "repos/$repo/commits/$sha" 2>>"$LOG_FILE"); then
                        # Emit both filename AND previous_filename so a post-review
                        # rename (commit changes old.py → new.py) still matches a
                        # probe citing the pre-rename path.
                        commit_paths=$(printf '%s\n' "$commit_json" | jq -r '.files[]? | (.filename, .previous_filename // empty)')
                        post_paths=$(printf '%s\n%s\n' "$post_paths" "$commit_paths")
                    else
                        log "WARN: gh api commits/$sha failed for $repo"
                        post_paths_ok=0
                        fetch_failures=$((fetch_failures + 1))
                        repo_failures=$((repo_failures + 1))
                    fi
                done <<< "$shas"
                post_paths=$(printf '%s\n' "$post_paths" | grep -v '^$' | sort -u || true)
            else
                log "WARN: gh api pulls/commits failed for $repo#$pr_num"
                post_paths_ok=0
                fetch_failures=$((fetch_failures + 1))
                repo_failures=$((repo_failures + 1))
            fi
            pr_post_paths_cache["$post_review_key"]="$post_paths"
            pr_post_paths_ok_cache["$post_review_key"]="$post_paths_ok"
        fi
        post_paths="${pr_post_paths_cache[$post_review_key]}"
        post_paths_ok="${pr_post_paths_ok_cache[$post_review_key]}"

        if [ "$pr_files_ok" = "1" ]; then
            # Clear stale Applied/+LOC before recomputing — handles the rewalk
            # case where the PR diff stopped touching a previously-matched
            # cited path (incl. the empty-diff force-push edge case where
            # pulls/files succeeds with an empty list). edited_after is
            # cleared separately below, gated on post_paths_ok.
            clear_applied_for_review "$DB_FILE" "$repo" "$review_id"
            [ "$post_paths_ok" = "1" ] && clear_edited_after_for_review "$DB_FILE" "$repo" "$review_id"

            # Collect deduped (specialist, path) pairs across all probes in this review.
            # Empty $pr_paths is a no-op below — the path-intersection grep matches
            # nothing, spec_matched stays empty, no marks issued. No special case needed.
            declare -A spec_paths_seen=()
            while IFS= read -r probe_line; do
                specialist=$(printf '%s\n' "$probe_line" | count_attributions || true)
                [ -z "$specialist" ] && continue
                while IFS= read -r p; do
                    [ -z "$p" ] && continue
                    spec_paths_seen["${specialist}	${p}"]=1
                done < <(printf '%s\n' "$probe_line" | probe_cited_paths)
            done < <(printf '%s\n' "$review_body" | grep -E '^[0-9]+\.' || true)

            # Single intersection pass — for each (specialist, cited_path):
            #   - if path ∈ PR diff: accumulate +LOC/−LOC + mark applied
            #   - if path ∈ post-review-touched (only when post_paths_ok=1
            #     and the path set is non-empty — guards a half-built set
            #     from under-marking a previously-correct edited_after)
            declare -A spec_added=()
            declare -A spec_removed=()
            declare -A spec_matched=()
            declare -A spec_edited=()
            pr_files_tsv="${pr_files_cache[$cache_key]}"
            check_edited=0
            [ "$post_paths_ok" = "1" ] && [ -n "$post_paths" ] && check_edited=1
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
                if [ "$check_edited" = "1" ] && grep -qFx "$path" <<< "$post_paths"; then
                    spec_edited["$specialist"]=1
                fi
            done
            for specialist in "${!spec_matched[@]}"; do
                mark_applied "$DB_FILE" "$repo" "$review_id" "$specialist"
                set_applied_loc "$DB_FILE" "$repo" "$review_id" "$specialist" \
                    "${spec_added[$specialist]:-0}" "${spec_removed[$specialist]:-0}"
            done
            for specialist in "${!spec_edited[@]}"; do
                mark_edited_after "$DB_FILE" "$repo" "$review_id" "$specialist"
            done
            unset spec_paths_seen spec_added spec_removed spec_matched spec_edited
        fi

        walked_reviews=$((walked_reviews + 1))
    done < <(printf '%s' "$comments_json" \
        | jq -r --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" --arg window_floor "$window_floor" \
             ".[] | select($SUBSTANTIVE_REVIEW_JQ) | [.id, .issue_url, .created_at, .body] | @tsv")

    # Pass 2: feedback comments. For each feedback signal, find the most-recent
    # substantive bot review on the same PR before the feedback's created_at,
    # and mark the corresponding flag on (review, specialist) rows.
    while IFS=$'\t' read -r author issue_url body created_at; do
        [ -z "$author" ] && continue
        grep -qFx "$author" <<< "$trusted_set" || continue
        pr_num="${issue_url##*/}"
        body_decoded=$(printf '%b' "$body")

        positives=$( { printf '%s\n' "$body_decoded" | extract_props_attributions
                       printf '%s\n' "$body_decoded" | extract_memorize_attributions
                     } | sort -u | grep -v '^$' || true)
        negatives=$(printf '%s\n' "$body_decoded" | extract_critique_attributions)

        if [ -n "$positives" ] || [ -n "$negatives" ]; then
            # Attribution rule: feedback (props/critique/memorize) credits
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
                mark_critiqued "$DB_FILE" "$repo" "$target_review" "$specialist"
            done <<< "$negatives"
        fi
    done < <(printf '%s' "$comments_json" \
        | jq -r --arg marker "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" \
              '.[] | select(
                  ((.body | test("^/" + $cmd_prefix + "-props "; "m"))
                   or (.body | test("^/" + $cmd_prefix + "-critique "; "m"))
                   or (.body | test("/" + $cmd_prefix + "-memorize"; "i")))
                  and (.body | contains($marker) | not)
              ) | [.user.login, .issue_url, .body, .created_at] | @tsv')

    # Coverage tally: reuse comments_json (already full-window). Numerator
    # matches the canonical roster-marker regex from lib/bakeoff-parsers.sh —
    # NOT a permissive substring check, which would falsely count bodies
    # discussing the marker token in prose. Drives the snapshot's
    # "based on N of M" caption.
    if [ "$repo_failures" -eq 0 ]; then
        total_in_window=$(printf '%s' "$comments_json" \
            | jq --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" --arg window_floor "$window_floor" \
                 "[.[] | select($SUBSTANTIVE_REVIEW_JQ)] | length")
        with_marker_in_window=$(printf '%s' "$comments_json" \
            | jq --arg bot_user "$BOT_USER" --arg marker "$BOT_AUTO_POST_MARKER" --arg roster "$ROSTER_MARKER_REGEX" --arg window_floor "$window_floor" \
                 "[.[] | select($SUBSTANTIVE_REVIEW_JQ and (.body | test(\$roster)))] | length")
        set_repo_coverage "$DB_FILE" "$repo" "$total_in_window" "$with_marker_in_window"
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

# Coverage caption: sum per-repo total + with-marker.
coverage_total=$(sqlite3 "$DB_FILE" "SELECT COALESCE(SUM(reviews_total_in_window), 0) FROM walks;")
coverage_with_marker=$(sqlite3 "$DB_FILE" "SELECT COALESCE(SUM(reviews_with_marker_in_window), 0) FROM walks;")
if [ "$coverage_total" -gt 0 ]; then
    coverage_pct=$(awk -v w="$coverage_with_marker" -v t="$coverage_total" 'BEGIN{printf "%.0f", 100*w/t}')
else
    coverage_pct="—"
fi

{
    echo "# Specialist bake-off — last $WINDOW_DAYS days"
    echo
    echo "_Generated $(date -u +%FT%TZ). Based on $coverage_with_marker of $coverage_total substantive bot reviews in window (${coverage_pct}% coverage; reviews without the roster marker are not measured). Source: \`$DB_FILE\`._"
    echo
    if [ "$total_reviews" = "0" ]; then
        echo "_Awaiting first reviews with the roster marker — table populates as new reviews land._"
    else
        echo "**Per-repo coverage**"
        echo
        echo "| Repo | With marker | Total | Coverage |"
        echo "|---|---:|---:|---:|"
        sqlite3 -separator '|' "$DB_FILE" \
            "SELECT repo, reviews_with_marker_in_window, reviews_total_in_window FROM walks ORDER BY reviews_total_in_window DESC;" \
        | while IFS='|' read -r repo wm total; do
            if [ "${total:-0}" -gt 0 ]; then
                pct=$(awk -v w="${wm:-0}" -v t="$total" 'BEGIN{printf "%.0f%%", 100*w/t}')
            else
                pct="—"
            fi
            echo "| \`$repo\` | $wm | $total | $pct |"
          done
        echo
        echo "**Per-specialist (current window)**"
        echo
        echo "| Specialist | Reviews | Shipped | Cited | Edited | Blocking | Medium | Low+Nit | Open | +LOC | −LOC |"
        echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
        query_window_aggregates "$DB_FILE" "$window_iso" \
        | while IFS=$'\t' read -r spec reviews shipped applied added removed edited blocking medium low_nit open_cnt; do
            # Drop aggregator's row only when it had zero shipped probes —
            # noise reduction for the common case. If the aggregator prompt
            # uses its `From: aggregator` escape hatch for a cross-angle
            # finding, render the row so the decision table reflects it.
            [ "$spec" = "aggregator" ] && [ "${shipped:-0}" -eq 0 ] && continue
            echo "| $spec | $reviews | $shipped | $applied | $edited | $blocking | $medium | $low_nit | $open_cnt | $added | $removed |"
        done
        echo
        echo "_Loved=$( sqlite3 "$DB_FILE" "SELECT COALESCE(SUM(loved_positive), 0) FROM specialist_runs WHERE ran_at >= '$window_iso';") · Critiqued=$( sqlite3 "$DB_FILE" "SELECT COALESCE(SUM(critiqued), 0) FROM specialist_runs WHERE ran_at >= '$window_iso';") in window — still persisted per-(review × specialist) in the DB but not rendered here; the qualitative signal is too sparse to drive collapse/keep decisions._"
    fi
} > "$OUT_FILE"

log "wrote $OUT_FILE"
echo "OK: $OUT_FILE"
