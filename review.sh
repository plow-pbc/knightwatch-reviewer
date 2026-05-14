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

# ---------- enumerate + dispatch (single-pass) ----------
# Per-worker timeout. With detached workers (KillMode=process), the
# service-level TimeoutStartSec=90min no longer bounds worker runtime
# (orchestrator returns before workers complete). A wedged Codex phase
# could hold the per-PR flock indefinitely, blocking all future
# /srosro-update-review for that PR. `timeout 90m` re-establishes the
# pre-detach ceiling at the worker level; the worker exits, the flock
# releases, and the next tick can re-dispatch.
WORKER_TIMEOUT="${WORKER_TIMEOUT:-90m}"
log "Fan-out: max $MAX_CONCURRENT concurrent, per-worker timeout $WORKER_TIMEOUT"

# Single-pass: enumerate PRs and dispatch eligible ones inline. No
# ELIGIBLE serialization, no \x1f delimiter, no PR-title scrub — shell
# variable boundaries are explicit when we invoke the worker directly
# with positional args + env vars. Per-PR flock in lib/review-one-pr.sh
# prevents duplicate-dispatch races for the same PR.
active=0
dispatched=0
for REPO in "${REPOS[@]}"; do
    PR_LIST=$(gh pr list --repo "$REPO" --json number,title,headRefName,headRefOid 2>/dev/null) || {
        log "Failed to list PRs for $REPO"
        continue
    }
    [ "$(echo "$PR_LIST" | jq 'length')" -eq 0 ] && continue

    while IFS= read -r PR_JSON; do
        PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
        PR_TITLE=$(echo "$PR_JSON" | jq -r '.title')
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
        NEXT_SLASH_CUTOFF_AT=""

        if [ -n "$KNOWN_SHA" ]; then
            # Cutoff timestamp sources from runs/ (meta.json.started_at)
            # — single source of truth since state.json was retired in
            # PR #38. started_at is now stamped from max(.created_at) of
            # the dispatcher's fetched comments snapshot (passed to the
            # worker via SLASH_CUTOFF_AT, computed below), NOT the
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
            SLASH_CUTOFF_AT=$(latest_author_visible_slash_cutoff_at "$STATE_DIR" "$REPO_SLUG_FOR_GATE" "$PR_NUM" "")
            # Fail loud on a transient gh outage rather than treating
            # "API broken" as "no comments" and silently missing a
            # /srosro-update-review trigger. Same wrapper shape as
            # approve-from-replies.sh + learn-from-replies.sh.
            COMMENTS_JSON=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
                log "$PR_ID: comments fetch failed — skipping this PR for this tick"
                continue
            }
            # NEXT_SLASH_CUTOFF_AT is set below (after FORCE_REVIEW is
            # determined) — only advance to the snapshot max when a slash
            # trigger was actually consumed, otherwise carry the prior
            # SLASH_CUTOFF_AT forward. Advancing on push-only dispatches
            # would let eventual-consistency hide a slash command: if a
            # /srosro-* comment is older than a newer non-trigger comment
            # in the fetched snapshot but propagation delay omits the
            # slash command from THIS tick, advancing past the newer
            # comment would orphan the slash command on the next tick.
            # Single source for the consumed slash trigger: ONE jq call
            # selects the highest-priority comment newer than the prior
            # cutoff and returns it (or empty). Priority is /srosro-review
            # (whole-PR) over /srosro-update-review (incremental); within
            # each kind, the latest by created_at wins. Bot auto-posts are
            # excluded via the HTML-comment marker (review acks, the usage
            # footer that itself contains the slash commands, etc.); the
            # marker filter is more reliable than .user.login != $user
            # because single-account deployments run the bot AS the human,
            # so user-based filtering also drops the human's legitimate
            # slash commands.
            #
            # FORCE_REVIEW / FORCE_WHOLE_PR / TRIGGER_* / NEXT_SLASH_CUTOFF_AT
            # all derive from this one selection, so the cutoff and the
            # staged trigger body can never drift apart. Empty selection =
            # no slash trigger this tick = carry the prior cutoff forward
            # (push-only dispatch path); this is the eventual-consistency
            # fail-loud shape — if GitHub hid an older /srosro-* comment
            # behind a newer non-trigger in this tick's snapshot, the next
            # tick's filter still sees it.
            TRIGGER_JSON=$(printf '%s' "$COMMENTS_JSON" |
                jq -c --arg since "$SLASH_CUTOFF_AT" --arg mark "$BOT_AUTO_POST_MARKER" --arg cmd_prefix "$BOT_CMD_PREFIX" '
                    def is_whole: (.body | test("/" + $cmd_prefix + "-review"; "i")) and ((.body | test("/" + $cmd_prefix + "-update-review"; "i")) | not);
                    def is_incr:  .body | test("/" + $cmd_prefix + "-update-review"; "i");
                    [.[] | select((.body | contains($mark) | not) and .created_at > $since)] as $eligible |
                    ([$eligible[] | select(is_whole)] | sort_by(.created_at) | last) //
                    ([$eligible[] | select(is_incr)]  | sort_by(.created_at) | last) //
                    empty' 2>/dev/null)
            if [ -n "$TRIGGER_JSON" ]; then
                FORCE_REVIEW=true
                TRIGGER_USER=$(printf '%s' "$TRIGGER_JSON" | jq -r '.user.login // ""')
                TRIGGER_BODY_RAW=$(printf '%s' "$TRIGGER_JSON" | jq -r '.body // ""')
                TRIGGER_CREATED_AT=$(printf '%s' "$TRIGGER_JSON" | jq -r '.created_at // ""')
                # Whole-PR if body matches /srosro-review WITHOUT /srosro-update-review.
                if printf '%s' "$TRIGGER_BODY_RAW" | grep -qiE "/${BOT_CMD_PREFIX}-update-review"; then
                    FORCE_WHOLE_PR=false
                else
                    FORCE_WHOLE_PR=true
                fi
                # Cutoff = consumed trigger's .created_at, lower-bounded by
                # prior SLASH_CUTOFF_AT so the watermark never regresses.
                # Anchored in the SPECIFIC comment we consumed (not the
                # snapshot max), so a hidden higher-scope command behind
                # a visible lower-scope one doesn't get filtered out next
                # tick. ISO 8601 sorts lexicographically.
                NEXT_SLASH_CUTOFF_AT=$(printf '%s\n%s\n' "$TRIGGER_CREATED_AT" "$SLASH_CUTOFF_AT" | sort | tail -1)
                # Trust gate: honor the trigger regardless of who posted
                # it (the re-request-poller and external requesters need
                # to keep working), but the body only gets staged as
                # `.codex-scratch/trigger-comment.md` when the commenter
                # has push access. Otherwise drive-by commenters could
                # shape intent inference + aggregator on the auto-approve
                # path.
                if is_trusted_repo_author "$REPO" "$TRIGGER_USER"; then
                    TRIGGER_BODY="$TRIGGER_BODY_RAW"
                else
                    log "$PR_ID: trigger from @$TRIGGER_USER — not staging trigger-comment.md (no push access)"
                fi
            else
                NEXT_SLASH_CUTOFF_AT="$SLASH_CUTOFF_AT"
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

        # Throttle to MAX_CONCURRENT in-flight workers per tick. We don't
        # track outcomes here — workers detach (KillMode=process on the
        # unit) and the next tick runs regardless of this tick's per-worker
        # results. Per-worker outcomes live in $STATE_DIR/runs/<id>/run.log
        # and the systemd journal. Per-PR flock in lib/review-one-pr.sh
        # prevents duplicate-dispatch races for the same PR.
        while [ "$active" -ge "$MAX_CONCURRENT" ]; do
            wait -n || true
            active=$((active - 1))
        done

        TRIGGER_COMMENT_FILE="$TRIGGER_FILE" \
        SLASH_CUTOFF_AT="$NEXT_SLASH_CUTOFF_AT" \
        REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
            timeout "$WORKER_TIMEOUT" "$REVIEWER_LIB_DIR/review-one-pr.sh" \
            "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
        active=$((active + 1))
        dispatched=$((dispatched + 1))
    done < <(echo "$PR_LIST" | jq -c '.[]')
done

if [ "$dispatched" -eq 0 ]; then
    log "No PRs need review"
    exit 0
fi

# Detached fan-out: workers are running in the background and will
# continue past this script's exit (KillMode=process on the systemd
# unit; children reparent to PID 1). We do NOT wait for them — the
# orchestrator's job is to enumerate eligible PRs and dispatch; per-
# worker outcomes land in $STATE_DIR/runs/<id>/run.log and the systemd
# journal. Without this, the next 2-min timer tick is blocked until the
# slowest worker finishes (15–20 min in production), making
# /srosro-update-review pickup unboundedly slow.
log "Fan-out: dispatched $dispatched worker(s) (detached, running in background)"
exit 0
