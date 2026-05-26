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
# Single-call PR enumerator: one `gh api graphql` per ORGS-tracked owner
# plus per-repo `gh pr list` for manual REPOS entries whose owner isn't
# in ORGS. Replaces a 41×-per-tick `gh pr list` loop that was burning
# the per-user GraphQL quota.
. "$REVIEWER_LIB_DIR/pr-enumerate.sh"

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
# Grace before SIGKILL: `timeout` sends SIGTERM at WORKER_TIMEOUT, then SIGKILL
# WORKER_KILL_AFTER later. Without -k, a worker (or same-group child) that
# ignores SIGTERM outlives its ceiling and accumulates in the unit cgroup —
# the cascade the manual /unstick-kwr recipe used to clear by hand. 30s lets a
# worker that DOES trap SIGTERM finish its cleanup_eyes/finalize_run before the
# hard kill. (Codex setsid's into its own session and escapes timeout's
# process-group signal entirely — that residual is accepted, not fixed here.)
WORKER_KILL_AFTER="${WORKER_KILL_AFTER:-30s}"
log "Fan-out: max $MAX_CONCURRENT concurrent, per-worker timeout $WORKER_TIMEOUT (kill-after $WORKER_KILL_AFTER)"

# Parse GNU `timeout` duration syntax ('90m', '30s', '1h', or bare seconds)
# into a seconds integer. Used to derive WORKER_DEADLINE_EPOCH for pipeline.py.
_worker_timeout_seconds() {
    case "$1" in
        *s) printf '%s\n' "${1%s}" ;;
        *m) printf '%s\n' "$(( ${1%m} * 60 ))" ;;
        *h) printf '%s\n' "$(( ${1%h} * 3600 ))" ;;
        *)  printf '%s\n' "$1" ;;
    esac
}

# Single-pass: enumerate PRs and dispatch eligible ones inline. No
# tab-delimited spec serialization, no field-shift attack surface —
# shell variable boundaries are explicit when the worker is invoked
# directly with positional args + env vars. Per-PR flock in
# lib/review-one-pr.sh prevents duplicate-dispatch races.
active=0
dispatched=0
ALL_PRS=$(enumerate_open_prs) || {
    log "Failed to enumerate open PRs (batched graphql or per-repo fallthrough — see prior errors)"
    exit 0
}
[ "$(echo "$ALL_PRS" | jq 'length')" -eq 0 ] && { log "No PRs need review"; exit 0; }

while IFS= read -r PR_JSON; do
    REPO=$(echo "$PR_JSON" | jq -r '.repository.nameWithOwner')
    PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
    PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // ""')
    PR_BRANCH=$(echo "$PR_JSON" | jq -r '.headRefName')
    PR_SHA=$(echo "$PR_JSON" | jq -r '.headRefOid')
    PR_ID="${REPO}#${PR_NUM}"
    # Capture per-PR cutoff at the dispatcher BEFORE fetch + dispatch
    # so the worker can stamp meta.json.started_at from this value
    # instead of its own process-entry time. Closes the race where a
    # comment posted in the gap between dispatcher and worker init
    # would have created_at < worker's started_at, making the next
    # tick's "created_at > started_at" filter drop the trigger.
    TICK_FETCHED_AT_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

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

    if [ -n "$KNOWN_SHA" ]; then
        # Cutoff timestamp sources from runs/ (meta.json.started_at)
        # — single source of truth since state.json was retired in
        # PR #38. started_at is stamped at run init (line ~165 of
        # lib/review-one-pr.sh) BEFORE the worker can crash, so a
        # /srosro-review posted while a review is in flight always
        # falls AFTER the recorded started_at and re-qualifies for
        # the next tick. Helper returns ISO 8601 directly —
        # meta.json.started_at is already in that format.
        REVIEWED_AT_ISO=$(latest_author_visible_review_started_at "$STATE_DIR" "$REPO_SLUG_FOR_GATE" "$PR_NUM" "")
        # Fail loud on a transient gh outage rather than treating
        # "API broken" as "no comments" and silently missing a
        # /srosro-update-review trigger. Same wrapper shape as
        # approve-from-replies.sh + learn-from-replies.sh.
        COMMENTS_JSON=$(fetch_issue_comments "$REPO" "$PR_NUM") || {
            log "$PR_ID: comments fetch failed — skipping this PR for this tick"
            continue
        }
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

    # Throttle to MAX_CONCURRENT in-flight workers per tick. We don't
    # track outcomes here — workers detach (KillMode=process on the
    # unit) and the next tick runs regardless of this tick's per-worker
    # results. Per-worker outcomes live in $STATE_DIR/runs/<id>/run.log
    # and the systemd journal.
    while [ "$active" -ge "$MAX_CONCURRENT" ]; do
        wait -n || true
        active=$((active - 1))
    done

    # Absolute wall-clock deadline of the outer `timeout $WORKER_TIMEOUT`
    # wrap. pipeline.py reads this to decide whether a stale-kill retry
    # fits under the worker cap — `just test` (up to 30 min), Wave A,
    # and earlier specialists all eat into the same budget.
    worker_secs=$(_worker_timeout_seconds "$WORKER_TIMEOUT")
    TRIGGER_COMMENT_FILE="$TRIGGER_FILE" \
    DISPATCHER_TICK_AT="$TICK_FETCHED_AT_ISO" \
    REVIEWER_LIB_DIR="$REVIEWER_LIB_DIR" \
    WORKER_DEADLINE_EPOCH="$(( $(date +%s) + worker_secs ))" \
        timeout -k "$WORKER_KILL_AFTER" "$WORKER_TIMEOUT" "$REVIEWER_LIB_DIR/review-one-pr.sh" \
        "$REPO" "$PR_NUM" "$PR_SHA" "$PR_BRANCH" "$PR_TITLE" "$FORCE_WHOLE_PR" &
    active=$((active + 1))
    dispatched=$((dispatched + 1))
done < <(echo "$ALL_PRS" | jq -c '.[]')

# Detached fan-out: workers run past this script's exit (KillMode=process
# on the systemd unit; children reparent to PID 1). We don't wait —
# enumerate + dispatch is the orchestrator's job, per-worker outcomes
# land in $STATE_DIR/runs/<id>/run.log. Without detach, the next 2-min
# timer tick would block on the slowest worker (15–20 min in prod).
if [ "$dispatched" -eq 0 ]; then
    log "No PRs need review"
else
    log "Fan-out: dispatched $dispatched worker(s) (detached, running in background)"
fi
exit 0
