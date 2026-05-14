#!/bin/bash
# Orchestrator: enumerate eligible PRs across all tracked repos and fan out
# per-PR reviews via lib/review-one-pr.sh. Up to MAX_CONCURRENT reviews run
# concurrently per service tick. Per-PR locking is handled by the worker.
#
# Shebang note: this entrypoint runs only on the production Linux host
# under pr-reviewer.service. It deliberately uses /bin/bash (NOT
# /usr/bin/env bash) because $HOME/.local is writable per
# ReadWritePaths — a writable-interpreter resolution path. Hard-coding
# /bin/bash blocks the writable-PATH attack regardless of $PATH order.
# The systemd unit's Environment=PATH puts system dirs FIRST and trails
# the writable user dirs, so user-installed tools (codex via nvm-managed
# per-version bin, pipx packages in ~/.local/bin) remain reachable without prepending the
# writable dirs in front of system tools. Do NOT re-add an
# `export PATH=$HOME/.local/bin:...` here — that would let an attacker
# place ~/.local/bin/timeout (or gh, git, awk, …) and have it shadow
# the system tool when this script invokes the command by name.

STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
LOG_FILE="${LOG_FILE:-$STATE_DIR/orchestrator.log}"
REPOS_DIR="${REPOS_DIR:-$STATE_DIR/repos}"
WORKDIRS_DIR="${WORKDIRS_DIR:-$STATE_DIR/workdirs}"
STABLE_SECS="${STABLE_SECS:-3600}"
MAX_CONCURRENT="${MAX_CONCURRENT:-4}"

# Tracked-repo manifest (REPOS array + KID_PATHS assoc array). Single
# source of truth at repos.conf — adding a repo only edits one file.
# config.env can still REPOS=(...) override on top. The shared loader
# at lib/tracked-repos.sh is the ONE seam every consumer goes through;
# it also pins $TMPDIR=$STATE_DIR/tmp post-config — keeps mktemp out of
# the unit-private /tmp that the systemd unit tears down under detached
# workers (see lib/tracked-repos.sh and PR #33 for the full why).
REVIEWER_LIB_DIR="${REVIEWER_LIB_DIR:-$HOME/.pr-reviewer/lib}"
. "$REVIEWER_LIB_DIR/tracked-repos.sh"
. "$REVIEWER_LIB_DIR/gh-comments.sh"
[ ${#REPOS[@]} -ge 1 ] || { echo "FATAL: no tracked repos — populate $STATE_DIR/repos.conf or set REPOS in config.env" >&2; exit 1; }
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
# Hidden HTML-comment marker prepended to every auto-post by this repo
# (review ack, final review, learn-from-replies ack). The orchestrator's
# jq filter excludes any comment containing this string so the bot
# doesn't self-trigger on its own posts. Must match the literal used in
# lib/review-one-pr.sh and learn-from-replies.sh — a smoke-test scenario
# catches drift.
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# Source helpers. $REVIEWER_LIB_DIR is the seam used both for sandboxed
# smoke tests and the production symlink ($HOME/.pr-reviewer/lib);
# tracked-repos.sh above already resolved it.
. "$REVIEWER_LIB_DIR/state-io.sh"
. "$REVIEWER_LIB_DIR/auth.sh"
# run-dir.sh exposes the latest_author_visible_review_* projection family
# — the single source of truth for "what did we last review?" state. The
# orchestrator's KNOWN_SHA gate reads from runs/<id>/meta.json (not
# state.json) so a transient write failure after a successful `gh pr
# comment` can't strand us in an infinite-dispatch loop. The legacy
# state.json cache was retired entirely in PR #38; nothing reads or
# writes it anymore.
. "$REVIEWER_LIB_DIR/run-dir.sh"

# Rotate the orchestrator log when it exceeds 5MB. Per-run logs under
# runs/<id>/ aren't rotated — they're already bounded by run.
# `wc -c` is portable; `stat -c%s` is GNU-only (BSD stat uses -f%z).
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')" -gt 5242880 ]; then
    mv "$LOG_FILE" "$LOG_FILE.1"
fi

mkdir -p "$STATE_DIR" "$REPOS_DIR" "$WORKDIRS_DIR" "$STATE_DIR/locks"

# Fail loud at the dispatcher level if the worker script is missing
# or not executable. Catches the catastrophic class of dispatch failures
# (broken install, accidental chmod -x, deleted symlink) before fan-out.
# Checked HERE — before per-PR enumeration — so a doomed-to-abort run
# never materializes a trigger-comment tempfile under $STATE_DIR/tmp
# that no worker would clean up.
if [[ ! -x "$REVIEWER_LIB_DIR/review-one-pr.sh" ]]; then
    log "FATAL: $REVIEWER_LIB_DIR/review-one-pr.sh missing or not executable — aborting fan-out"
    exit 1
fi

# ---------- enumerate eligible PRs ----------
declare -a ELIGIBLE=()

for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number,title,headRefName,headRefOid 2>/dev/null) || {
        log "Failed to list PRs for $REPO"
        continue
    }
    [ "$(echo "$PR_LIST" | jq 'length')" -eq 0 ] && continue

    while IFS= read -r PR_JSON; do
        PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
        # Strip control chars (U+0000-001F, U+007F) from PR_TITLE before
        # it lands in the \x1f-delimited ELIGIBLE spec. GitHub allows
        # control chars in titles via the REST API (only the web UI
        # rejects them), and `jq -r` outputs the literal bytes — so a
        # title like "x\x1fevil\x1f/path" would shift TRIGGER_FILE to an
        # attacker-controlled path on dispatch. REPO/PR_NUM/PR_SHA are
        # restricted character sets and PR_BRANCH per git refs spec
        # can't contain control chars; PR_TITLE is the only PR-derived
        # field that needs this defense.
        PR_TITLE=$(echo "$PR_JSON" | jq -r '.title' | tr -d '\000-\037\177')
        PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
        PR_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid')
        PR_ID="${REPO}#${PR_NUM}"

        # KNOWN_SHA at the dispatch gate reads from runs/<id>/meta.json
        # — the single source of truth since PR #38 retired state.json.
        # meta.json.reviewed_sha is stamped right after the worker checks
        # out the PR head, so this gate sees the actually-reviewed SHA
        # (not the orchestrator-enumerated PR_SHA, which can be stale on
        # fast-cadence pushes). With state.json retired, there's no
        # second write that can fail and leave a stale "have we reviewed
        # this SHA?" answer driving an infinite dispatch loop.
        REPO_SLUG_FOR_GATE="${REPO//\//_}"
        KNOWN_SHA=$(latest_author_visible_review_sha "$STATE_DIR" "$REPO_SLUG_FOR_GATE" "$PR_NUM" "")
        FORCE_REVIEW=false
        FORCE_WHOLE_PR=false
        TRIGGER_FILE=""
        TRIGGER_USER=""
        TRIGGER_BODY=""
        TICK_FETCHED_AT_ISO=""

        if [ -n "$KNOWN_SHA" ]; then
            # Cutoff timestamp sources from runs/ (meta.json.started_at)
            # — single source of truth since state.json was retired in
            # PR #38. started_at is now stamped from max(.created_at) of
            # the dispatcher's fetched comments snapshot (passed to the
            # worker via DISPATCHER_TICK_AT, computed below), NOT the
            # worker's script-entry time NOR our local wall clock. That
            # closes the race where a /srosro-review posted in the gap
            # between dispatcher fetch and worker init would have a
            # created_at older than the worker's started_at, making the
            # next tick's "created_at > started_at" filter silently drop
            # the trigger. Anchoring in GitHub-stamped created_at values
            # also closes the sub-second wall-clock window between the
            # API's processing-time and our post-fetch local clock.
            # Helper returns ISO 8601 directly — meta.json.started_at is
            # already in that format.
            REVIEWED_AT_ISO=$(latest_author_visible_review_started_at "$STATE_DIR" "$REPO_SLUG_FOR_GATE" "$PR_NUM" "")
            # Fail loud on a transient gh outage rather than treating
            # "API broken" as "no comments" and silently missing a
            # /srosro-update-review trigger. Same wrapper shape as
            # approve-from-replies.sh + learn-from-replies.sh.
            COMMENTS_JSON=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
                log "$PR_ID: comments fetch failed — skipping this PR for this tick"
                continue
            }
            # Cutoff = max(.created_at) of fetched snapshot, lower-bounded
            # by the prior REVIEWED_AT_ISO so the cutoff never regresses.
            # Anchoring the cutoff in GitHub-stamped created_at values
            # (rather than our local wall clock post-fetch) closes the
            # remaining sub-second race where a comment created BETWEEN
            # GitHub's API-processing-time and our local capture would be
            # absent from the snapshot yet stamped as "consumed" and lost
            # on the next tick. Empty/missing max falls back to
            # REVIEWED_AT_ISO; this keeps the watermark intact when this
            # tick saw no comments.
            TICK_FETCHED_AT_ISO=$(printf '%s' "$COMMENTS_JSON" | jq -r --arg fb "$REVIEWED_AT_ISO" \
                '[(map(.created_at) | max // empty), $fb] | max')
            # Exclude the bot's own auto-posts (review ack, final review,
            # learn-from-replies acks, and the usage footer that appears on
            # every review and itself contains the slash commands) by
            # matching the hidden HTML-comment marker every auto-post
            # template prepends. The earlier `.user.login != $user` filter
            # (e1d91a0) over-excluded: in single-account deployments
            # BOT_USER is the human's own GH identity, so user-based
            # filtering also drops legitimate slash-command comments the
            # human posts.
            #
            # Two slash commands; substring tests are sufficient because
            # the strings are disjoint (neither contains the other as a
            # substring). Whole-PR check excludes /srosro-update-review so
            # the longer command doesn't accidentally satisfy both paths.
            WHOLE_TRIGGER=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" \
                    '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/" + $cmd_prefix + "-review"; "i")) and ((.body | test("/" + $cmd_prefix + "-update-review"; "i")) | not))] | length')
            INCREMENTAL_TRIGGER=$(printf '%s' "$COMMENTS_JSON" |
                jq --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" \
                    '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/" + $cmd_prefix + "-update-review"; "i")))] | length')
            if [ "${WHOLE_TRIGGER:-0}" -gt 0 ]; then
                FORCE_REVIEW=true
                FORCE_WHOLE_PR=true
            elif [ "${INCREMENTAL_TRIGGER:-0}" -gt 0 ]; then
                FORCE_REVIEW=true
            fi
            # If a comment triggered this re-review, capture the latest matching
            # comment's author + body to a tmp file so the worker can stage it
            # as `.codex-scratch/trigger-comment.md`. Lets the requester's own
            # framing ("trying to DRY but ended up adding 2k LoC...") shape the
            # inferred intent and the review's emphasis. Path is passed via the
            # 7th spec field; the worker reads and rm -fs it once received.
            if [ "$FORCE_REVIEW" = "true" ]; then
                if [ "$FORCE_WHOLE_PR" = "true" ]; then
                    TRIGGER_JSON=$(printf '%s' "$COMMENTS_JSON" |
                        jq -c --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" \
                            '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/" + $cmd_prefix + "-review"; "i")) and ((.body | test("/" + $cmd_prefix + "-update-review"; "i")) | not))] | sort_by(.created_at) | last // empty' 2>/dev/null)
                else
                    TRIGGER_JSON=$(printf '%s' "$COMMENTS_JSON" |
                        jq -c --arg since "$REVIEWED_AT_ISO" --arg mark "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" \
                            '[.[] | select((.body | contains($mark) | not) and .created_at > $since and (.body | test("/" + $cmd_prefix + "-update-review"; "i")))] | sort_by(.created_at) | last // empty' 2>/dev/null)
                fi
                if [ -n "$TRIGGER_JSON" ]; then
                    TRIGGER_USER=$(printf '%s' "$TRIGGER_JSON" | jq -r '.user.login // ""')
                    # Trust gate: the slash-command trigger itself is
                    # honored regardless of who posted it (re-request-poller
                    # and external requesters need to keep working), but the
                    # comment's prose only gets staged as
                    # `.codex-scratch/trigger-comment.md` when the commenter
                    # has push access. Otherwise drive-by commenters could
                    # shape intent inference + aggregator on the
                    # auto-approve path.
                    if is_trusted_repo_author "$REPO" "$TRIGGER_USER"; then
                        # Capture body now; materialize the file post-skip
                        # (below) so an unchanged-SHA /srosro-update-review
                        # never allocates a tempfile only the worker would
                        # have cleaned up. STATE_DIR/tmp is durable now
                        # (no PrivateTmp tear-down to mask the leak).
                        TRIGGER_BODY=$(printf '%s' "$TRIGGER_JSON" | jq -r '.body // ""')
                    else
                        log "$PR_ID: trigger from @$TRIGGER_USER — not staging trigger-comment.md (no push access)"
                    fi
                fi
            fi
        fi

        # Skip if SHA unchanged and not whole-PR-forced. /srosro-update-review
        # on an unchanged SHA would otherwise spawn a worker that runs
        # `git diff KNOWN_SHA..HEAD`, gets an empty diff (KNOWN_SHA == HEAD),
        # and aborts in lib/review-one-pr.sh. /srosro-review
        # (FORCE_WHOLE_PR=true) bypasses this because the worker uses
        # `gh pr diff` for the full PR regardless of base SHA, so there's
        # always something to review.
        #
        # Stale-trigger behavior (deliberate): a skipped /srosro-update-review
        # is NOT consumed — the comment-selection query keys off
        # `created_at > reviewed_at`, so the trigger stays "open" until the
        # next actual review. If the author later pushes a commit before
        # that review, the still-open trigger flips FORCE_REVIEW=true on
        # the next tick and bypasses the 1h stability gate. We accept this
        # as eager-review behavior: the user asked the bot to update, and
        # we deliver it as soon as there is something meaningful to review
        # (the new commits). Marking triggers consumed on skip would
        # require a state schema change for a low-impact edge case at our
        # scale.
        if [ "$PR_SHA" = "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" = "false" ]; then
            continue
        fi

        # Log the trigger reason now that we know we're dispatching. Logged
        # AFTER the skip check so the log matches what actually runs (a
        # /srosro-update-review on an unchanged PR no longer logs
        # "incremental re-review" before silently skipping).
        if [ "$FORCE_WHOLE_PR" = "true" ]; then
            log "$PR_ID: /${BOT_CMD_PREFIX}-review requested — whole-PR re-review"
        elif [ "$FORCE_REVIEW" = "true" ]; then
            log "$PR_ID: /${BOT_CMD_PREFIX}-update-review requested — incremental re-review"
        fi

        # Stability cooldown for non-forced re-reviews.
        if [ -n "$KNOWN_SHA" ] && [ "$FORCE_REVIEW" = "false" ]; then
            LAST_COMMIT_DATE=$(gh api "repos/$REPO/pulls/$PR_NUM/commits" --jq '.[-1].commit.committer.date' 2>/dev/null)
            if [ -z "$LAST_COMMIT_DATE" ]; then
                log "$PR_ID: could not get commit date, skipping"
                continue
            fi
            LAST_COMMIT_TS=$(date -d "$LAST_COMMIT_DATE" +%s)
            AGE_SECS=$(( $(date +%s) - LAST_COMMIT_TS ))
            if [ "$AGE_SECS" -lt "$STABLE_SECS" ]; then
                log "$PR_ID: last commit $(( AGE_SECS / 60 ))m ago — waiting for $(( STABLE_SECS / 3600 ))h stability"
                continue
            fi
        fi

        # Materialize the trigger-comment file only now that we know we're
        # actually dispatching (past every `continue`). Earlier creation
        # leaked stale files under $STATE_DIR/tmp on the unchanged-SHA
        # /srosro-update-review skip path, where no worker runs to clean up.
        if [ -n "$TRIGGER_BODY" ]; then
            # Path-style template (not `-t`): BSD mktemp's `-t` ignores
            # TMPDIR and always uses /var/folders/.../T on macOS, which
            # would land trigger files outside the $STATE_DIR/tmp pin
            # (lib/tracked-repos.sh:47) and reopen the PrivateTmp
            # tear-down race on Linux production. Path-form honors
            # TMPDIR identically on BSD and GNU.
            TRIGGER_FILE=$(mktemp "$TMPDIR/pr-review-trigger.XXXXXX")
            printf 'Comment by @%s:\n\n%s\n' "$TRIGGER_USER" "$TRIGGER_BODY" > "$TRIGGER_FILE"
        fi

        # ASCII Unit Separator (\x1f, non-whitespace) so titles with
        # spaces survive AND adjacent empty fields don't collapse —
        # bash's `read` with whitespace IFS treats consecutive
        # delimiters as one, which would silently shift later fields
        # left (e.g., DISPATCHER_TICK_AT would land in TRIGGER_FILE
        # whenever TRIGGER_FILE was empty).
        ELIGIBLE+=("$REPO"$'\x1f'"$PR_NUM"$'\x1f'"$PR_SHA"$'\x1f'"$PR_BRANCH"$'\x1f'"$PR_TITLE"$'\x1f'"$FORCE_WHOLE_PR"$'\x1f'"$TRIGGER_FILE"$'\x1f'"$TICK_FETCHED_AT_ISO")
    done < <(echo "$PR_LIST" | jq -c '.[]')
done

if [ ${#ELIGIBLE[@]} -eq 0 ]; then
    log "No PRs need review"
    exit 0
fi

# Per-worker timeout. With detached workers (KillMode=process), the
# service-level TimeoutStartSec=90min no longer bounds worker runtime
# (orchestrator returns before workers complete). A wedged Codex phase
# could hold the per-PR flock indefinitely, blocking all future
# /srosro-update-review for that PR. `timeout 90m` re-establishes the
# pre-detach ceiling at the worker level; the worker exits, the flock
# releases, and the next tick can re-dispatch.
WORKER_TIMEOUT="${WORKER_TIMEOUT:-90m}"

log "Fan-out: ${#ELIGIBLE[@]} eligible PR(s), max $MAX_CONCURRENT concurrent, per-worker timeout $WORKER_TIMEOUT"

# ---------- fan out with bounded concurrency ----------
# Rate-limit fan-out to MAX_CONCURRENT in-flight workers per tick. We
# don't track outcomes here — workers detach (KillMode=process on the
# unit) and the next tick runs regardless of this tick's per-worker
# results. Per-worker outcomes live in $STATE_DIR/runs/<id>/run.log
# and the systemd journal. Per-PR flock in lib/review-one-pr.sh
# prevents duplicate-dispatch races for the same PR.
active=0
for spec in "${ELIGIBLE[@]}"; do
    IFS=$'\x1f' read -r REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR TRIGGER_FILE DISPATCHER_TICK_AT <<< "$spec"

    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        wait -n || true
        active=$((active - 1))
    done

    TRIGGER_COMMENT_FILE="$TRIGGER_FILE" \
    DISPATCHER_TICK_AT="$DISPATCHER_TICK_AT" \
    REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
        timeout "$WORKER_TIMEOUT" "$REVIEWER_LIB_DIR/review-one-pr.sh" \
        "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
    active=$((active + 1))
done

# Detached fan-out: workers are running in the background and will
# continue past this script's exit (KillMode=process on the systemd
# unit; children reparent to PID 1). We do NOT wait for them — the
# orchestrator's job is to enumerate eligible PRs and dispatch; per-
# worker outcomes land in $STATE_DIR/runs/<id>/run.log and the systemd
# journal. Without this, the next 2-min timer tick is blocked until the
# slowest worker finishes (15–20 min in production), making
# /srosro-update-review pickup unboundedly slow.
log "Fan-out: dispatched ${#ELIGIBLE[@]} worker(s) (detached, running in background)"
exit 0
