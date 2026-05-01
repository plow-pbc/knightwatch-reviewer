#!/bin/bash
# Reviews one PR end-to-end. Invoked by review.sh as:
#   TRIGGER_COMMENT_FILE=<path> lib/review-one-pr.sh REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# where FORCE_WHOLE_PR is "true" or "false". TRIGGER_COMMENT_FILE is
# optional and points to a tmp file holding the body of the comment that
# kicked off this review (when triggered by /review or @bot mention);
# the worker slurps it and rm -fs the file early.

set -u
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

REPO="$1"
PR_NUM="$2"
PR_SHA="$3"
PR_BRANCH="$4"
PR_TITLE="$5"
FORCE_WHOLE_PR="${6:-false}"

PR_ID="${REPO}#${PR_NUM}"
PR_URL="https://github.com/$REPO/pull/$PR_NUM"

# Trigger-comment context: review.sh sets TRIGGER_COMMENT_FILE to a tmp
# path holding the body of the comment that kicked off this review (when
# the trigger was a /review or @bot mention). Slurp it now and rm -f
# eagerly so the tmp file doesn't survive past this worker, regardless
# of which exit path we take below. Empty string when this review
# wasn't triggered by a comment.
TRIGGER_COMMENT_BODY=""
if [ -n "${TRIGGER_COMMENT_FILE:-}" ] && [ -f "${TRIGGER_COMMENT_FILE}" ]; then
    TRIGGER_COMMENT_BODY=$(cat "${TRIGGER_COMMENT_FILE}")
    rm -f "${TRIGGER_COMMENT_FILE}"
fi

# Captured here (before anything that can take minutes: just test, specialists,
# aggregator) and stamped into state.reviewed_at on success. The orchestrator
# filters "new comments since last review" with created_at > reviewed_at, so if
# we stamped completion time instead, a /review posted during this run would
# fall before the stamp and be invisible to the next tick.
REVIEW_START_TS=$(date +%s)

# --- per-PR advisory lock ----------------------------------------------------
# Prevents two concurrent invocations from stepping on each other for the same
# PR. If we can't acquire, exit silently (with a log line) — the other
# invocation will finish its own work.
#
# Lock acquisition lives in lib/locking.sh::acquire_pr_lock so the
# smoke test can call the same function this production path does —
# a regression that moves the lock dir back to /tmp would have to
# break the helper too, which the smoke catches directly.
#
# NB: this block runs BEFORE state-io.sh is sourced, so `log` isn't yet
# available. Use raw echo+tee for the contention message. We also don't have
# LOG_FILE defaulted yet (the per-run dir is set up below). Fall back to
# $STATE_DIR/orchestrator.log so this skip line still lands somewhere durable.
STATE_DIR="${STATE_DIR:-$HOME/.pr-reviewer}"
_LIB_DIR_EARLY="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LIB_DIR_EARLY/locking.sh"
PR_LOCK_SLUG="${REPO//\//_}__${PR_NUM}"
if ! acquire_pr_lock "$STATE_DIR" "$PR_LOCK_SLUG"; then
    _raw_log="${LOG_FILE:-${STATE_DIR:-$HOME/.pr-reviewer}/orchestrator.log}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $PR_ID: another review already in flight (lock held on $PR_LOCK_FILE) — skipping this invocation" \
        | tee -a "$_raw_log" 2>/dev/null || true
    exit 0
fi
# flock is held for the lifetime of PR_LOCK_FD; releases automatically on exit.

STATE_FILE="${STATE_FILE:-$STATE_DIR/state.json}"
# Per-run dir is set up below once we've sourced helpers; until then the
# orchestrator-level fallback catches any early `log` call.
LOG_FILE="${LOG_FILE:-$STATE_DIR/orchestrator.log}"
REPOS_DIR="${REPOS_DIR:-$STATE_DIR/repos}"
# Per-PR workdirs live under $STATE_DIR (not /tmp). When the service runs with
# PrivateTmp=yes, /tmp is a unit-private mount — codex 0.122's unified-exec
# helper doesn't inherit that namespace and fails to find cwds under /tmp.
WORKDIRS_DIR="${WORKDIRS_DIR:-$STATE_DIR/workdirs}"

# Tracked-repo manifest (REPOS array + KID_PATHS assoc array). Bash
# arrays don't survive the process boundary between review.sh and this
# worker, so we re-source via the shared loader. Loader also picks up
# config.env (the legacy override seam) and pins $TMPDIR=$STATE_DIR/tmp
# post-config — keeps the worker's mktemp calls (KID / dead-code /
# strict-typing stderr capture below) out of the unit-private /tmp the
# systemd unit tears down under detached workers (see lib/tracked-repos.sh
# and PR #33 for the full why).
. "$_LIB_DIR_EARLY/tracked-repos.sh"
BOT_USER="${BOT_USER:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"

# Source helpers. Prefer REVIEWER_LIB_DIR if caller set it (smoke-test
# isolation); fall back to the worker's own directory.
_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LIB_DIR/state-io.sh"
. "$_LIB_DIR/auth.sh"

# --- prompt-build helpers (sourced from lib/prompt-build.sh) ---
. "$_LIB_DIR/prompt-build.sh"

# --- knightwatch-config helper (per-repo .knightwatch/ reads) ---
. "$_LIB_DIR/knightwatch-config.sh"

# --- search-roots coverage-state helper ---
. "$_LIB_DIR/search-roots.sh"

# --- diff-build helper (clean-incremental-vs-fallback predicate) ---
. "$_LIB_DIR/diff-build.sh"

# --- sibling-repo symlinks (cross-repo grep without leaking host paths) ---
. "$_LIB_DIR/sibling-symlinks.sh"

# --- path-scrub safety net (strip leaked host paths before posting) ---
. "$_LIB_DIR/path-scrub.sh"

# --- agent-failure + run-dir helpers ---
. "$_LIB_DIR/agent-fallback.sh"
. "$_LIB_DIR/run-dir.sh"

# --- loc-trend computation (compute_loc_trend / _loc_trend_display) ---
# Sources run-dir.sh internally for is_run_author_visible /
# author_visible_rounds, but run-dir.sh is sourced just above and
# multi-source is idempotent (function redefinition).
. "$_LIB_DIR/loc-trend.sh"

# --- per-run dir -------------------------------------------------------------
# Every worker invocation gets its own runs/<RUN_ID>/ dir holding the run log,
# input scratch, and one subdir per agent (prompt + output + log). The git
# checkout under workdirs/<slug>__<pr>/ is rm -rf'd at the end of the run
# (large + ephemeral); meta.json records its path so a post-mortem reader
# can locate it before cleanup, and `sha` lets you re-check out from
# repos/<slug>/ at any time.
REPO_SLUG_FOR_RUN="${REPO//\//_}"
# Millisecond resolution minimizes collisions on back-to-back retries of
# the same SHA. allocate_run_dir is the actual no-overwrite guarantee:
# if anything ever produces a duplicate RUN_ID — format revert, logic
# bug, race we didn't anticipate — the second worker aborts loud
# instead of silently corrupting the first run's run.log/output.md.
RUN_TS="$(date -u +%Y%m%dT%H%M%S%3NZ)"
RUN_ID="${REPO_SLUG_FOR_RUN}__${PR_NUM}__${RUN_TS}__${PR_SHA:0:7}"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
if ! allocate_run_dir "$RUN_DIR"; then
    exit 1
fi
LOG_FILE="$RUN_DIR/run.log"

# meta.json — minimal post-mortem header. Title is JSON-escaped via jq so
# titles with quotes / newlines don't break the file. Workdir path is
# recorded for the live-run window even though rm -rf eventually clears it.
if ! jq -n \
        --arg repo "$REPO" \
        --arg pr_id "$PR_ID" \
        --argjson pr_num "$PR_NUM" \
        --arg sha "$PR_SHA" \
        --arg branch "$PR_BRANCH" \
        --arg title "$PR_TITLE" \
        --arg force_whole_pr "$FORCE_WHOLE_PR" \
        --arg workdir "$WORKDIRS_DIR/${REPO_SLUG_FOR_RUN}__${PR_NUM}" \
        --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{repo: $repo, pr_id: $pr_id, pr_num: $pr_num, sha: $sha, branch: $branch, title: $title, force_whole_pr: ($force_whole_pr == "true"), workdir: $workdir, started_at: $started_at}' \
        > "$RUN_DIR/meta.json"; then
    # Without meta.json the run header is broken from the start — abort
    # rather than running blind. Falls through to the EXIT trap, which
    # may in turn fail to update meta.json; that's acceptable because
    # the file already doesn't exist as expected.
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $PR_ID: failed to write $RUN_DIR/meta.json — aborting" >&2
    exit 1
fi

# write_scratch — writes input artifacts into the run dir's inputs/ and
# exposes them under the codex-scratch view in the workdir so agents can
# read them via the paths their prompts cite (e.g. ".codex-scratch/diff.patch").
write_scratch() {
    local repo_dir="$1" filename="$2" content="$3"
    local input_path="$RUN_DIR/inputs/$filename"
    local scratch_dir="$repo_dir/.codex-scratch"
    mkdir -p "$(dirname "$input_path")" "$scratch_dir/specialists"
    printf '%s' "$content" > "$input_path"
    ln -sfn "$input_path" "$scratch_dir/$filename"
}

# Convenience symlink: latest run for this PR. Lets `tail -f
# runs-by-pr/<repo-slug>/<pr>/latest/run.log` follow the most recent worker
# without knowing the run id.
LATEST_LINK_DIR="$STATE_DIR/runs-by-pr/$REPO_SLUG_FOR_RUN/$PR_NUM"
mkdir -p "$LATEST_LINK_DIR"
ln -sfn "$RUN_DIR" "$LATEST_LINK_DIR/latest"

# Run-status finalization. The success path flips RUN_STATUS to "completed"
# right before exit 0; every other exit (errors, signals, abort branches)
# leaves "aborted" so post-mortem tooling can tell completed from "still
# running" / "died mid-flight" by reading meta.json alone — the previous
# code only stamped status on the success path, so abort dirs were
# indistinguishable from in-flight ones.
RUN_STATUS="aborted"
# Tracks whether `gh pr comment` ever returned success during this run.
# Used by finalize_meta_json to repair meta.json.posted_at when the early
# stamp fails — once we've published the review, persisting that fact
# must be guaranteed before exit so the recurrence detector never
# undercounts a real prior author-visible review. Set to "true" right
# after the gh pr comment success in the post-aggregator section.
GH_POSTED=false
# True when we wanted to take a clean incremental diff but couldn't —
# either the prior reviewed SHA was evicted from the branch's history
# (rebase/force-push), or the branch merged origin/<default-branch>
# between then and now (merge-from-main would pollute attribution).
# When true, REVIEW_SCOPE becomes `fallback:<sha>` and the worker
# emits a "clean incremental unavailable" disclosure at the top of
# the posted review.
USED_FALLBACK=false
finalize_run() {
    # Thin wrapper around finalize_meta_json (lib/run-dir.sh) that supplies
    # the worker's runtime closure (RUN_DIR / RUN_STATUS / GH_POSTED / now).
    # Helper handles the atomic jq+mv + posted_at repair; this only logs
    # on failure (the trap fires from EXIT, so we can't recover, but we
    # can fail loud rather than silently leaving meta.json un-stamped).
    if ! finalize_meta_json "$RUN_DIR/meta.json" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_STATUS" "$GH_POSTED"; then
        log "$PR_ID: finalize_run failed — meta.json left un-stamped"
    fi
}

log "Reviewing $PR_ID (force_whole_pr=$FORCE_WHOLE_PR)"

# Post a "reviewing" placeholder immediately so the PR author sees the bot
# picked up the work — the full run (`just test` up to 30m + 6 specialists +
# critic + aggregator) can take many minutes. We keep the comment ID so we
# can DELETE the placeholder once the real review posts as a fresh comment.
# We post the review as a NEW comment (not by editing this placeholder)
# because GitHub does not fire notifications on comment edits — authors
# would see "👀 reviewing" silently transform 14 minutes later and never
# know the review was ready, leading to "@srosro review please" pings even
# though the review was already up. On any abort path, the EXIT trap edits
# the placeholder to "aborted" instead so it doesn't read as "still
# reviewing" forever.
#
# The leading HTML comment is invisible in rendered Markdown but lets the
# orchestrator's jq filter recognize this as one of our auto-posts so we
# don't self-trigger on the next tick.
EYES_COMMENT_ID=$(gh api "repos/$REPO/issues/$PR_NUM/comments" \
    --method POST \
    -f body="$BOT_AUTO_POST_MARKER
👀 reviewing — [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)" \
    --jq '.id' 2>/dev/null) || EYES_COMMENT_ID=""

EYES_RESOLVED=false
cleanup_eyes() {
    if [ "$EYES_RESOLVED" = "true" ] || [ -z "$EYES_COMMENT_ID" ]; then
        return 0
    fi
    gh api "repos/$REPO/issues/comments/$EYES_COMMENT_ID" --method PATCH \
        -f body="$BOT_AUTO_POST_MARKER
review aborted before completion — see knightwatch-reviewer logs; will retry on the next tick if the PR head hasn't moved." \
        >/dev/null 2>&1 || true
}
trap 'finalize_run; cleanup_eyes' EXIT

if [ -n "$EYES_COMMENT_ID" ]; then
    log "$PR_ID: posted reviewing placeholder (comment id=$EYES_COMMENT_ID)"
else
    log "$PR_ID: failed to post reviewing placeholder (continuing)"
fi

# Canonical clone lives at $REPOS_DIR/<slug>/ and is the source of truth for
# `fetch`. Multiple PR reviews on the same repo coexist by each working in
# their own per-PR workdir that shares objects (via git clone --shared) with
# the canonical clone.
#
# A repo-scoped flock serializes canonical clone/fetch and the per-PR
# shared-clone read. Without this, two workers on the same repo race through
# `git fetch` and can hand a half-initialized object store to `git clone
# --shared`. The lock is released before the slow specialist/aggregator
# phases, so cross-repo fan-out remains fully parallel and same-repo fan-out
# is only serialized for the short clone/fetch window.
REPO_SLUG=$(echo "$REPO" | tr '/' '_')
CANONICAL_DIR="$REPOS_DIR/$REPO_SLUG"
PR_WORKDIR_SLUG="${REPO_SLUG}__${PR_NUM}"
REPO_DIR="$WORKDIRS_DIR/${PR_WORKDIR_SLUG}"

CANONICAL_LOCK_DIR="$STATE_DIR/canonical-locks"
mkdir -p "$CANONICAL_LOCK_DIR"
CANONICAL_LOCK_FILE="$CANONICAL_LOCK_DIR/$REPO_SLUG"
exec {CANONICAL_LOCK_FD}> "$CANONICAL_LOCK_FILE"
flock "$CANONICAL_LOCK_FD" || { log "$PR_ID: canonical flock failed — aborting"; exit 1; }

if [ ! -d "$CANONICAL_DIR/.git" ]; then
    log "Cloning canonical $REPO..."
    if ! gh repo clone "$REPO" "$CANONICAL_DIR" -- --depth=500 --no-single-branch; then
        log "$PR_ID: canonical clone failed — aborting"
        exit 1
    fi
fi

# Fetch latest refs into the canonical clone. We fetch the PR head via
# `refs/pull/N/head` rather than by branch name, so fork PRs work
# uniformly with same-repo PRs (fork PRs' heads live on the fork, not
# on the base repo, so `origin/$PR_BRANCH` doesn't exist there — but
# GitHub mirrors every open PR's head at `refs/pull/N/head` on the base
# repo regardless of source). We still alias it into `refs/heads/
# $PR_BRANCH` so downstream code (per-PR workdir checkout, diff, log
# messages) can use the human-readable branch name.
#
# The default branch stays as a plain fetch (updating only refs/remotes/
# origin/$DEFAULT_BRANCH) because canonical has $DEFAULT_BRANCH checked
# out and git refuses to force-update a checked-out ref. Stale local
# main is fine for our use — we only need it for listing touched files.
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')
if [ -z "$DEFAULT_BRANCH" ]; then
    log "$PR_ID: could not resolve default branch from gh repo view — aborting"
    exit 1
fi
if ! git -C "$CANONICAL_DIR" fetch origin "$DEFAULT_BRANCH" --depth=500 --quiet; then
    log "$PR_ID: canonical fetch of $DEFAULT_BRANCH failed — aborting"
    exit 1
fi
if ! git -C "$CANONICAL_DIR" fetch origin "+refs/pull/$PR_NUM/head:$PR_BRANCH" --depth=500 --quiet; then
    log "$PR_ID: refs/pull/$PR_NUM/head not fetchable (PR closed?) — skipping"
    exit 0
fi

# Tear down any stale per-PR workdir and create a fresh shared clone.
# --shared gives us hardlinked objects from canonical, so this is cheap.
# Canonical's refs/heads/$PR_BRANCH shows up here as origin/$PR_BRANCH.
rm -rf "$REPO_DIR"
mkdir -p "$(dirname "$REPO_DIR")"
if ! git clone --shared "$CANONICAL_DIR" "$REPO_DIR" --no-single-branch --quiet; then
    log "$PR_ID: git clone --shared failed — aborting"
    exit 1
fi

# Release the canonical lock now; the rest of the worker operates in
# $REPO_DIR and doesn't touch canonical object state.
exec {CANONICAL_LOCK_FD}>&-

# Check out the PR branch. Fail loud if it isn't there — silently falling
# back to the default branch (as the old code did) made every incremental
# re-review diff against the wrong base.
if ! git -C "$REPO_DIR" checkout -B "pr-$PR_NUM" "origin/$PR_BRANCH" --quiet; then
    log "$PR_ID: checkout of origin/$PR_BRANCH failed in workdir — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Snapshot the SHA we *actually* reviewed (local HEAD after fetch +
# checkout), distinct from PR_SHA (the SHA the orchestrator enumerated
# earlier in `gh pr list`). If the PR head moved between enumeration and
# the worker's fetch — a normal race in a fast-cadence orchestrator —
# PR_SHA points at an older commit and the worker's diff actually covers
# `KNOWN_SHA..REVIEWED_SHA`. Using PR_SHA in the posted header would
# render a `git diff` command that doesn't reproduce what the bot
# reviewed (PR #35 round-1 finding); using PR_SHA in `state_set` would
# also record a SHA that may no longer be on the branch (force-push
# eviction) so the next tick can't anchor an incremental diff.
# REVIEWED_SHA is the source of truth for "what this run evaluated";
# the stale-head disclosure later compares it against the PR's
# CURRENT_HEAD via gh API to catch movement that happens AFTER this
# point but before posting.
REVIEWED_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
if [ -z "$REVIEWED_SHA" ]; then
    log "$PR_ID: rev-parse HEAD returned empty after checkout — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
if [ "$REVIEWED_SHA" != "$PR_SHA" ]; then
    log "$PR_ID: orchestrator enumerated ${PR_SHA:0:7}, worker checked out ${REVIEWED_SHA:0:7} — using checked-out SHA for header + state"
fi

# Redirect-safe staging — a PR checkout could commit .codex-scratch as a
# symlink to a writable service path (e.g. ~/.pr-reviewer/runs/...) so that
# write_scratch + the per-specialist symlinks would redirect critic /
# momentum / dead-code outputs into our own state dir. Wipe + recreate
# unconditionally before any write so the worker owns the directory.
# Mirrors lib/sibling-symlinks.sh's .siblings/ wipe-then-recreate pattern.
rm -rf "$REPO_DIR/.codex-scratch"
mkdir -p "$REPO_DIR/.codex-scratch"

# Stamp the actually-reviewed SHA into meta.json. The earlier write
# (line ~268) used PR_SHA — the orchestrator-enumerated SHA before
# fetch + checkout — but the worker's source of truth for "what was
# evaluated" is REVIEWED_SHA (post-checkout HEAD). Downstream
# consumers (compute_loc_trend / author_visible_rounds) prefer
# .reviewed_sha when present, falling back to .sha for legacy runs
# pre-dating this field. Atomic jq + mv so a crash mid-write doesn't
# leave a torn file.
META_TMP="$RUN_DIR/meta.json.tmp"
if jq --arg sha "$REVIEWED_SHA" '. + {reviewed_sha: $sha}' \
        "$RUN_DIR/meta.json" > "$META_TMP" 2>/dev/null; then
    mv -f "$META_TMP" "$RUN_DIR/meta.json" || rm -f "$META_TMP"
else
    rm -f "$META_TMP"
    log "$PR_ID: meta.json reviewed_sha stamp failed — LOC trajectory may use enumerated SHA for this run"
fi

# Fetch PR metadata once, here, so PR_AUTHOR is available before the env
# mirror runs (the trust gate below depends on it). The full PR_DATA blob
# is reused later for AUTHOR_INTENT, commits, and linked-issue context.
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json title,body,author,commits,closingIssuesReferences 2>/dev/null)
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
if [ -z "$PR_AUTHOR" ]; then
    log "$PR_ID: gh pr view returned no author handle — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Mirror gitignored env files from canonical into the workdir. `git clone
# --shared` only carries tracked content, so .env files the user keeps in
# canonical's working tree (e.g. live-API credentials for `just test`'s
# scenario suites) never land here, and recipes that source them trip
# `${ANTHROPIC_API_KEY:?...}`-style guards identically on every PR. For
# each `.env*.example` the repo ships, copy the matching real env file
# (name minus `.example`) from canonical if one exists. Deleted right
# after `just test` so secret-bearing files don't linger.
#
# Trust gate: only mirror when PR_AUTHOR has push access to the repo.
# Otherwise an untrusted contributor's `just test` recipe could
# exfiltrate live API keys before the eager-delete runs. Untrusted PRs
# still get a `just test` run, just without canonical's secrets — the
# scenario-suite recipes that need live keys will trip their guards
# (unchanged from pre-72a9cad behavior for those PRs).
COPIED_ENV_FILES=()
if is_trusted_repo_author "$REPO" "$PR_AUTHOR"; then
    while IFS= read -r -d '' example_path; do
        rel="${example_path#"$REPO_DIR"/}"
        target_rel="${rel%.example}"
        canonical_src="$CANONICAL_DIR/$target_rel"
        workdir_dst="$REPO_DIR/$target_rel"
        if [ -e "$canonical_src" ] && [ ! -e "$workdir_dst" ]; then
            cp -L "$canonical_src" "$workdir_dst"
            COPIED_ENV_FILES+=("$workdir_dst")
        fi
    done < <(find "$REPO_DIR" -type f -name '.env*.example' \
        -not -path '*/.git/*' -not -path '*/node_modules/*' -print0)
    [ "${#COPIED_ENV_FILES[@]}" -gt 0 ] && \
        log "$PR_ID: mirrored ${#COPIED_ENV_FILES[@]} env file(s) from canonical (PR_AUTHOR=$PR_AUTHOR trusted)"
else
    log "$PR_ID: skipping .env mirror — PR_AUTHOR=$PR_AUTHOR has no push access (just test will run without canonical's secrets)"
fi

# ---- build diff + REVIEW_TASK (three paths) ----
# Hoisted ahead of `just test` so an empty-diff abort (re-review triggered
# without new commits since the prior review) costs seconds instead of
# burning a full `just test` cycle — including live-API recipes — on a
# workdir that has nothing to review.

# Single gh pr diff call up front — the canonical "what's in this PR"
# view, same one humans see on the PR's "Files changed" tab. Used for
# both KID_INPUT_DIFF (the diff specialists review) by default, and
# FULL_PR_DIFF (the aggregator's "verify prior findings against
# current state" reference) always.
#
# Capture stderr separately and classify the failure mode. GitHub
# caps `gh pr diff` at 300 files (HTTP 406 with "exceeded max files");
# the prior code swallowed stderr via `2>/dev/null` and reported every
# empty-stdout case as "auth/network", which lost reviewable
# 300-650-file PRs entirely. On the cap, fall back to a local
# `git diff origin/<base>...HEAD` (same three-dot semantics, no cap).
GH_DIFF_STDERR=$(mktemp)
FULL_PR_DIFF=$(gh pr diff "$PR_NUM" --repo "$REPO" 2>"$GH_DIFF_STDERR")
GH_DIFF_ERR=$(cat "$GH_DIFF_STDERR")
rm -f "$GH_DIFF_STDERR"
case "$(classify_gh_pr_diff_failure "$FULL_PR_DIFF" "$GH_DIFF_ERR")" in
    ok) ;;
    cap-exceeded)
        log "$PR_ID: gh pr diff hit GitHub's 300-file cap — falling back to local git diff origin/${DEFAULT_BRANCH}...HEAD"
        FULL_PR_DIFF=$(git -C "$REPO_DIR" diff "origin/$DEFAULT_BRANCH"...HEAD)
        if [ -z "$FULL_PR_DIFF" ]; then
            log "$PR_ID: local git diff fallback also empty (origin/${DEFAULT_BRANCH} missing in workdir?) — aborting"
            rm -rf "$REPO_DIR"
            exit 1
        fi
        log "$PR_ID: local fallback diff size = ${#FULL_PR_DIFF} bytes"
        ;;
    error)
        log "$PR_ID: gh pr diff failed — aborting before specialists run. stderr: ${GH_DIFF_ERR:-no stderr}"
        rm -rf "$REPO_DIR"
        exit 1
        ;;
esac
KID_INPUT_DIFF="$FULL_PR_DIFF"

KNOWN_SHA=$(state_get "$PR_ID" "sha")
PREV_BODY=""
PREV_APPROVED=""

# Optimization: use a local incremental diff for KID_INPUT_DIFF ONLY
# when (a) the prior reviewed SHA is still on the branch's history AND
# (b) no merge commits exist in the incremental range. Any other
# condition (rebase/force-push, OR branch merged main between then and
# now) would leak merge-from-main content or misframe an off-branch
# SHA — leave KID_INPUT_DIFF as the full PR diff and let
# `prepend_review_header` emit a `fallback:<sha>` scope disclosure at
# the top of the review (via REVIEW_SCOPE).
if [ -n "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" != "true" ]; then
    PREV_BODY=$(state_get "$PR_ID" "body")
    PREV_APPROVED=$(state_get "$PR_ID" "approved")
    if is_clean_incremental_available "$REPO_DIR" "$KNOWN_SHA"; then
        KID_INPUT_DIFF=$(git -C "$REPO_DIR" diff "$KNOWN_SHA..HEAD")
        log "$PR_ID: clean incremental diff since ${KNOWN_SHA:0:7}"
    else
        USED_FALLBACK=true
        log "$PR_ID: incremental not clean (rebased or merged-from-main since ${KNOWN_SHA:0:7}); using full PR diff"
    fi
fi

# Single source of truth for "what kind of review is this". Computed
# here so REVIEW_TASK (below) and the post-time scope-note injection
# (much later, just before gh pr comment) read the same value — without
# this seam, the prompt could say "incremental" while the banner said
# "fallback" or vice versa, the BCR class fenced by review-scope-smoke.
REVIEW_SCOPE=$(compute_review_scope "$FORCE_WHOLE_PR" "$KNOWN_SHA" "$USED_FALLBACK")

# REVIEW_TASK is the opening message the specialists/aggregator see.
# It must accurately describe what's in .codex-scratch/diff.patch and
# .codex-scratch/full-diff.patch for THIS run — the static prompt text
# in prompts/common-header.md and prompts/aggregator.md describes the
# general case but defers to this message when it differs (e.g. on the
# fallback path, diff.patch is the full PR, not an incremental subset).
case "$REVIEW_SCOPE" in
    whole)
        REVIEW_TASK="Whole-PR re-review (requested via /srosro-review). Review the full PR diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md. Any prior review is intentionally NOT provided — evaluate this PR from scratch."
        ;;
    first)
        REVIEW_TASK="Review the diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md."
        ;;
    incremental:*)
        REVIEW_TASK="Re-review: the author has pushed new commits since your previous review (at ${KNOWN_SHA:0:7}, approved=$PREV_APPROVED). Your prior review is in .codex-scratch/previous-review.md. The incremental diff since that review is in .codex-scratch/diff.patch; the full PR diff is in .codex-scratch/full-diff.patch (consult it when verifying whether prior findings are addressed). Assess whether the new commits address your prior concerns, then produce an updated review."
        ;;
    fallback:*)
        REVIEW_TASK="Re-review (clean incremental unavailable for ${KNOWN_SHA:0:7} — either rebase/force-push evicted it from the branch's history, or the branch merged origin/${DEFAULT_BRANCH} between then and now). Your prior review is in .codex-scratch/previous-review.md. Because the incremental view is unavailable, .codex-scratch/diff.patch contains the FULL PR diff (identical to .codex-scratch/full-diff.patch) — evaluate accordingly. Assess whether the current state addresses your prior concerns, then produce an updated review."
        ;;
esac

if [ -z "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: empty diff — gh pr diff / git diff returned nothing (possible auth, network, or rebase issue), aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# ---- just test ----
# Bound `just`'s justfile discovery to REPO_DIR — without --justfile,
# `just` walks up the directory tree and could pick up an ancestor
# justfile (workdirs live at $STATE_DIR/workdirs/<pr>; walk-up reaches
# $STATE_DIR and $HOME). Trusted-author runs mirror canonical .env*
# files into the workdir before this call, so executing an unrelated
# ancestor recipe with those secrets in scope is a real boundary
# crossing. The enumerated list mirrors `just`'s full set of accepted
# names so non-canonical-but-real justfiles aren't missed.
TEST_LOG="$REPO_DIR/.test-output.log"
TEST_TIMEOUT=30m

if ! command -v just >/dev/null 2>&1; then
    log "$PR_ID: \`just\` not on PATH — aborting (host misconfig; check Environment=PATH / rerun install.sh)"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Snapshot the base-branch SHA BEFORE running `just test`. Trust model
# for .knightwatch/<file> reads: the worker treats the base branch as
# the source of truth (PR-head edits don't take effect until merged).
# But `just test` runs PR-controlled code in the same workdir AND can
# rewrite local refs (e.g., `git update-ref refs/remotes/origin/main HEAD`).
# After tests, every read of `origin/<default-branch>:.knightwatch/...`
# would silently pick up PR-head policy. Snapshotting the base SHA
# upfront and passing the SHA (immutable) — not the ref — to all
# downstream .knightwatch reads closes that bypass.
DEFAULT_BRANCH_SHA=$(git -C "$REPO_DIR" rev-parse --verify --quiet "origin/$DEFAULT_BRANCH")
if [ -z "$DEFAULT_BRANCH_SHA" ]; then
    log "$PR_ID: failed to resolve origin/$DEFAULT_BRANCH SHA — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

JUST_FILE=""
for n in justfile Justfile JUSTFILE .justfile .Justfile .JUSTFILE; do
    [ -f "$REPO_DIR/$n" ] && { JUST_FILE="$REPO_DIR/$n"; break; }
done

if [ -z "$JUST_FILE" ]; then
    log "$PR_ID: no justfile in $REPO_DIR — skipping \`just test\`"
    TESTS_RAN=false
    TEST_SUMMARY="not run (no justfile in repo root)"
    : > "$TEST_LOG"
else
    log "$PR_ID: running \`just --justfile $JUST_FILE test\` (timeout ${TEST_TIMEOUT})..."
    timeout "$TEST_TIMEOUT" just --justfile "$JUST_FILE" --working-directory "$REPO_DIR" test > "$TEST_LOG" 2>&1
    TEST_EXIT=$?
    IFS=$'\t' read -r TESTS_RAN TEST_SUMMARY < <(classify_just_test_outcome "$TEST_EXIT" "$TEST_LOG" "$TEST_TIMEOUT")
fi
TEST_LOG_TAIL=$(tail -n 500 "$TEST_LOG")

# Env files were only needed for `just test`; delete eagerly so secrets
# don't sit in the workdir during the long specialist phase. REPO_DIR is
# also rm -rf'd on every exit path below, so this is a belt-and-suspenders
# early sweep, not the only cleanup. Runs regardless of which test path
# above fired (or even if no test ran at all).
for f in "${COPIED_ENV_FILES[@]}"; do
    rm -f "$f"
done

log "$PR_ID: just test ${TEST_SUMMARY}"
TEST_RESULTS="**Result:** ${TEST_SUMMARY}

Last 500 lines of \`just test\` output:
\`\`\`
${TEST_LOG_TAIL:-(no output captured)}
\`\`\`"

# ---- standards ----
STANDARDS=""
[ -f ~/.claude/CODING_STANDARDS.md ]     && STANDARDS+=$(cat ~/.claude/CODING_STANDARDS.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/REVIEW_PRACTICES.md ]     && STANDARDS+=$(cat ~/.claude/REVIEW_PRACTICES.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/TESTING.md ]              && STANDARDS+=$(cat ~/.claude/TESTING.md)
STANDARDS+=$'\n\n'
[ -f ~/.claude/COMMENT_REVIEW_MISTAKES.md ] && STANDARDS+="## Known Review Mistakes (avoid repeating these)\n"$(cat ~/.claude/COMMENT_REVIEW_MISTAKES.md)

# ---- kid prior-art ----
PRIOR_ART=""
KID_FLAG="$STATE_DIR/kid-last-failure"
# KID_RAN tracks whether the prior-art lookup actually executed and
# returned. Flipped false on any "didn't run" path so the disclosure
# header (built below) can warn the reader that the simplification
# specialist's cross-repo DRY signal is missing for this run.
KID_RAN=false
# Per-repo kid index path. KID_PATHS was loaded at file scope via the
# tracked-repos.sh loader (Bash arrays don't survive the process
# boundary between review.sh and this worker; the loader pre-declares
# KID_PATHS empty so the lookup is safe under `set -u` even if
# repos.conf is absent in a test sandbox).
KID_PROJECT_PATH="${KID_PATHS[$REPO]:-}"
if [ -n "$KID_PROJECT_PATH" ] && [ -d "$KID_PROJECT_PATH/.keepitdry" ] && [ -n "$KID_INPUT_DIFF" ]; then
    export KID_PROJECT="$KID_PROJECT_PATH"
    KID_STDERR=$(mktemp)
    PRIOR_ART=$(printf '%s' "$KID_INPUT_DIFF" | python3 "$HOME/Hacking/knightwatch-kid/scripts/kid_dry_check.py" 2>"$KID_STDERR")
    KID_EXIT=$?
    if [ $KID_EXIT -ne 0 ]; then
        KID_ERR_SUMMARY=$(tail -n 3 "$KID_STDERR" | tr '\n' ' ')
        log "$PR_ID: KID FAILURE (exit $KID_EXIT, project $KID_PROJECT) — degrading to kid-less review. stderr tail: $KID_ERR_SUMMARY"
        {
            echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "pr: $PR_ID"
            echo "project: $KID_PROJECT"
            echo "exit: $KID_EXIT"
            echo "--- stderr tail ---"
            tail -n 20 "$KID_STDERR"
        } > "$KID_FLAG"
        PRIOR_ART=""
    else
        rm -f "$KID_FLAG"
        KID_RAN=true
        if [ -n "$PRIOR_ART" ]; then
            BLOCK_COUNT=$(printf '%s\n' "$PRIOR_ART" | grep -c '^### New block')
            log "$PR_ID: kid surfaced prior-art for $BLOCK_COUNT block(s)"
        fi
    fi
    rm -f "$KID_STDERR"
elif [ -z "$KID_PROJECT_PATH" ]; then
    log "$PR_ID: no KID_PATHS entry for $REPO — skipping prior-art lookup"
elif [ -n "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: kid index not yet built at $KID_PROJECT_PATH — skipping prior-art lookup"
fi

# ---- touched-files derivation (shared by dead-code + strict-typing) ----
# Two pre-checks need a touched-files list, but with different scopes:
#
#   - TOUCHED_FILES_ARR  : POST-IMAGE only (files that exist in HEAD).
#                          Bash array, positional args for the per-repo
#                          dead-code command (`bash -c "$cmd" -- "$@"`,
#                          referenced inside as "$@"). PR-controlled
#                          filenames never flow through `eval`; the
#                          array form quotes whitespace and shell
#                          metacharacters correctly. Excludes deleted
#                          files because dead-code analysis on a
#                          missing path would error.
#
#   - TOUCHED_FILES_FILE : BOTH SIDES of every file change (pre AND
#                          post image), captured from `diff --git a/X
#                          b/Y` headers via extract_touched_files_both_sides.
#                          Newline-separated, repo-root-relative.
#                          Exported for the strict-typing helpers'
#                          scope gate. A PR that DELETES `foo.py` or
#                          RENAMES `foo.ts` → `foo.js` touched typed
#                          code, but post-image-only would miss both
#                          (the deletion's post-image is `/dev/null`;
#                          a similarity-100% pure rename has no +++ b/
#                          line at all) — silently suppressing the
#                          strict-typing note (Narrow-Fix flagged in
#                          PR #31 round 1).
#
# Empty diff → empty array + empty file → every consumer no-ops correctly.
TOUCHED_FILES_ARR=()
if [ -n "$KID_INPUT_DIFF" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] && TOUCHED_FILES_ARR+=("$f")
    done < <(printf '%s' "$KID_INPUT_DIFF" | grep -E '^\+\+\+ b/' | sed 's|^+++ b/||')
fi
TOUCHED_FILES_FILE=$(mktemp)
if [ -n "$KID_INPUT_DIFF" ]; then
    printf '%s' "$KID_INPUT_DIFF" | extract_touched_files_both_sides > "$TOUCHED_FILES_FILE"
fi
export TOUCHED_FILES_FILE
log "$PR_ID: touched-files post-image=${#TOUCHED_FILES_ARR[@]} both-sides=$(wc -l < "$TOUCHED_FILES_FILE")"

# ---- dead-code static-tool pre-pass ----
# Mirrors the kid block above: per-repo command, graceful degrade on
# failure, output to a scratch file consumed by ONE downstream step
# (the dead-code-search LLM pre-pass). DEAD_CODE_CMDS was loaded at
# file scope via the tracked-repos.sh loader; the pre-declared empty
# assoc array makes the lookup safe under `set -u` even in sandboxes
# without repos.conf.
#
# Exit-code policy: keep stdout regardless of exit. Some tools (vulture)
# exit 1 *because* findings exist. Treat empty-stdout-AND-non-zero-exit
# as the only degrade signal; non-empty stdout is data.
DEAD_CODE_STATIC=""
# Dead-code static-analysis command: try .knightwatch/dead-code.sh first
# (per-repo, committed to the base branch), fall back to DEAD_CODE_CMDS[$REPO]
# from repos.conf (legacy operator-managed).
DEAD_CODE_CMD=""
DEAD_CODE_CMD=$(read_knightwatch_file "$REPO_DIR" "$DEFAULT_BRANCH_SHA" "dead-code.sh")
case $? in
    0) : ;;  # PRESENT: use as-is (empty content = "no dead-code check for this repo")
    1) DEAD_CODE_CMD="${DEAD_CODE_CMDS[$REPO]:-}" ;;  # ABSENT: legacy fallback
    *) log "$PR_ID: knightwatch-config error reading dead-code.sh — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
# TOUCHED_FILES_ARR is hoisted earlier (post-image side, shared with the
# strict-typing scope gate) so no inline rebuild here. Empty array → skip.
if [ -n "$DEAD_CODE_CMD" ] && [ "${#TOUCHED_FILES_ARR[@]}" -gt 0 ]; then
    DC_STATIC_STDERR=$(mktemp)
    DEAD_CODE_STATIC=$(cd "$REPO_DIR" && bash -c "$DEAD_CODE_CMD" -- "${TOUCHED_FILES_ARR[@]}" 2>"$DC_STATIC_STDERR")
    DC_STATIC_EXIT=$?
    if [ -n "$DEAD_CODE_STATIC" ]; then
        DC_LINE_COUNT=$(printf '%s\n' "$DEAD_CODE_STATIC" | wc -l)
        log "$PR_ID: dead-code static pre-pass produced $DC_LINE_COUNT candidate line(s) (exit $DC_STATIC_EXIT)"
    elif [ "$DC_STATIC_EXIT" -ne 0 ]; then
        DC_ERR_SUMMARY=$(tail -n 3 "$DC_STATIC_STDERR" | tr '\n' ' ')
        log "$PR_ID: dead-code static pre-pass exit $DC_STATIC_EXIT, no output — degrading. stderr tail: $DC_ERR_SUMMARY"
    fi
    rm -f "$DC_STATIC_STDERR"
fi

# ---- deterministic pre-checks ----
# Pre-checks that produce findings the LLM never sees. Each check sets a
# variable here; the unified REVIEW_NOTES assembly block near the end of
# this file (search "REVIEW_NOTES=()") joins them — along with scope,
# stale-head, and skipped-checks disclosures — into one blockquote at the
# top of the posted comment. Single registry, one render target, no
# severity-prioritization seam to hide them.
#
# Helper contract is TRI-STATE — load-bearing per PR #27 round-2 review.
# Collapsing checker errors into "gap" silently publishes wrong review
# text when the helper's inputs are broken (bad PROJECT_DIR, malformed
# config file, refused symlink), so a new check MUST distinguish:
#
#     exit 0 — check passed.                     stdout: empty.
#     exit 1 — real gap.                         stdout: gap detail (logged).
#     exit 2 — checker could not determine.      stderr: error details.
#
# Adding a new deterministic check is two blocks: (1) run the helper here,
# capture stderr + rc separately, and on rc=1 set a NEW_CHECK_NOTE var to
# the short fragment that should appear in the header; (2) push that var
# into REVIEW_NOTES at the assembly block. Never `2>/dev/null` the stderr
# away or treat any non-empty stdout as a gap:
#
#     CHECK_STDERR=$(mktemp)
#     CHECK_OUT=$(cd "$REPO_DIR" && bash -c "$NEW_CHECK_CMD" 2>"$CHECK_STDERR")
#     CHECK_RC=$?
#     case $CHECK_RC in
#         0) ;;                                              # pass
#         1) log "$PR_ID: <check> gap — $CHECK_OUT"
#            NEW_CHECK_NOTE="❌ <short fragment>" ;;          # gap
#         *) log "$PR_ID: <check> CHECKER ERROR (rc=$CHECK_RC) — $(cat "$CHECK_STDERR")" ;;
#     esac
#     rm -f "$CHECK_STDERR"
#
# Personality (sass, opinion, voice) does NOT belong here — every PR sees
# the byte-identical string and it gets repetitive fast. Keep fragments
# bare-fact; voice lives in the LLM body where each PR is novel.

# REVIEWER_LIB_DIR is referenced by the per-repo cmds in repos.conf
# (which call $REVIEWER_LIB_DIR/checks/<lang>-strict-typing.sh). Export
# so it propagates into the `bash -c "$cmd"` subshells below.
export REVIEWER_LIB_DIR="$_LIB_DIR"

# Strict-typing pre-check. Per-repo cmd from repos.conf delegates to
# lib/checks/<lang>-strict-typing.sh. Helper contract is tri-state:
#   exit 0 — strict mode enforced.
#   exit 1 — gap (stdout has verbose detail → logged).
#   exit 2 — checker error (stderr has details → logged loud, no note).
# The tri-state is load-bearing: collapsing checker errors into "gap"
# silently publishes wrong review text on broken inputs (bad PROJECT_DIR,
# malformed config file, refused symlink). Fail-loud here keeps the
# deterministic section honest.
STRICT_TYPING_NOTE=""
# Strict-typing pre-check: try .knightwatch/strict-typing.sh first
# (per-repo, committed to the base branch), fall back to STRICT_TYPING_CMDS[$REPO]
# from repos.conf (legacy operator-managed).
STRICT_TYPING_CMD=""
STRICT_TYPING_CMD=$(read_knightwatch_file "$REPO_DIR" "$DEFAULT_BRANCH_SHA" "strict-typing.sh")
case $? in
    0) : ;;  # PRESENT: use as-is (empty content = "no strict-typing check for this repo")
    1) STRICT_TYPING_CMD="${STRICT_TYPING_CMDS[$REPO]:-}" ;;  # ABSENT: legacy fallback
    *) log "$PR_ID: knightwatch-config error reading strict-typing.sh — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
if [ -n "$STRICT_TYPING_CMD" ]; then
    STRICT_STDERR=$(mktemp)
    STRICT_GAP=$(cd "$REPO_DIR" && bash -c "$STRICT_TYPING_CMD" 2>"$STRICT_STDERR")
    STRICT_RC=$?
    case $STRICT_RC in
        0) ;;
        1)
            log "$PR_ID: strict-typing gap detected — $STRICT_GAP"
            STRICT_TYPING_NOTE="❌ Strict typing not enforced"
            ;;
        *)
            STRICT_ERR=$(cat "$STRICT_STDERR")
            log "$PR_ID: strict-typing CHECKER ERROR (rc=$STRICT_RC) — ${STRICT_ERR:-no stderr}"
            ;;
    esac
    rm -f "$STRICT_STDERR"
fi

# TOUCHED_FILES_FILE was only needed by the deterministic pre-checks
# (dead-code, strict-typing). Clean up before the LLM specialists run —
# they read the diff directly from the staged scratch files, not the
# touched-files list.
rm -f "$TOUCHED_FILES_FILE"
unset TOUCHED_FILES_FILE

log "$PR_ID: diff is ${#KID_INPUT_DIFF} bytes"

# ---- search-roots for cross-repo grep ----
# Single worker-owned coverage-state seam: every whitelisted sibling
# (SOURCE_PATHS in repos.conf) is classified as `included` (checkout
# present on disk) or `missing` (operator-config gap, checkout absent),
# and the resulting machine-readable content is consumed by the
# dead-code-search pre-pass and the consumers specialist as the sole
# source of truth. Lives in lib/search-roots.sh (regression-fenced by
# lib/tests/search-roots-smoke.sh) so the staging logic can't drift
# into per-prompt rediscovery again.
if ! SEARCH_ROOTS=$(stage_search_roots "$REPO" "$REPO_DIR" "$DEFAULT_BRANCH_SHA"); then
    log "$PR_ID: stage_search_roots failed (knightwatch-config error) — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Materialize sibling-repo symlinks under .siblings/<owner>/<repo>, but
# ONLY for siblings stage_search_roots above just classified as
# `included` (whitelisted in SOURCE_PATHS AND checkout present on disk).
# Running before stage_search_roots would symlink siblings whose
# checkouts are absent — symlinks would dangle and specialists would
# get confused.
INCLUDED_SLUGS=()
while IFS= read -r line; do
    case "$line" in
        *' included '*) INCLUDED_SLUGS+=("${line%% included *}") ;;
    esac
done <<< "$SEARCH_ROOTS"
materialize_sibling_symlinks "$REPO_DIR" SOURCE_PATHS "${INCLUDED_SLUGS[@]}"

# ---- write scratch files ----
write_scratch "$REPO_DIR" "diff.patch"         "$KID_INPUT_DIFF"
write_scratch "$REPO_DIR" "previous-review.md" "$PREV_BODY"
write_scratch "$REPO_DIR" "test-results.md"    "$TEST_RESULTS"
write_scratch "$REPO_DIR" "prior-art.md"       "${PRIOR_ART:-}"
write_scratch "$REPO_DIR" "dead-code-static.md" "${DEAD_CODE_STATIC:-}"
write_scratch "$REPO_DIR" "search-roots.md"    "${SEARCH_ROOTS:-}"
write_scratch "$REPO_DIR" "standards.md"       "$STANDARDS"
[ -n "${FULL_PR_DIFF:-}" ] && \
    write_scratch "$REPO_DIR" "full-diff.patch" "$FULL_PR_DIFF"
[ -n "$TRIGGER_COMMENT_BODY" ] && \
    write_scratch "$REPO_DIR" "trigger-comment.md" "$TRIGGER_COMMENT_BODY"

# Stage prior aggregator outputs for this PR (every preserved run dir
# except the current one) so the aggregator can detect Bug-Class-Recurrence
# across reviews. Uses the per-run layout from PR #11; before that layout
# only the most recent scratch was kept, so longitudinal recurrence couldn't
# be detected. Empty / absent on the first review of a PR. Logic lives in
# lib/run-dir.sh::stage_prior_reviews so the smoke test exercises the same
# function the worker calls.
#
# Skipped when FORCE_WHOLE_PR=true (i.e. the user explicitly invoked
# /srosro-review): the trigger text on that path commits to "Any prior
# review is intentionally NOT provided — evaluate this PR from scratch."
# Staging prior-reviews.md anyway would silently break that contract,
# letting the bot consult prior reviews while telling the reader it
# didn't. loc-trend.md (LOC trajectory) is independent of prior review
# content and stays staged — it's derived from runs/ metadata, not from
# what previous reviewers said.
if [ "$FORCE_WHOLE_PR" = "true" ]; then
    log "$PR_ID: FORCE_WHOLE_PR=true — skipping prior-reviews.md (whole-PR re-review evaluates from scratch)"
else
    PRIOR_REVIEWS=$(stage_prior_reviews "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
    if [ -n "$PRIOR_REVIEWS" ]; then
        PRIOR_COUNT=$(printf '%s' "$PRIOR_REVIEWS" | grep -c '^--- review at ')
        log "$PR_ID: staging $PRIOR_COUNT prior review(s) for recurrence detection"
        write_scratch "$REPO_DIR" "prior-reviews.md" "$PRIOR_REVIEWS"
    fi
fi

# Product context: try .knightwatch/product-context.md first (per-repo,
# committed to the base branch), fall back to ~/.pr-reviewer/contexts/<slug>.md
# (legacy operator-managed). Once every tracked repo has its .knightwatch/
# committed, the fallback can be removed.
PRODUCT_CONTEXT=""
PRODUCT_CONTEXT=$(read_knightwatch_file "$REPO_DIR" "$DEFAULT_BRANCH_SHA" "product-context.md")
case $? in
    0) : ;;  # PRESENT: use as-is (empty content = "explicitly no product context for this repo")
    1)
        # ABSENT: legacy fallback
        CONTEXT_FILE="$HOME/.pr-reviewer/contexts/$(echo "$REPO" | tr '/' '_').md"
        if [ -f "$CONTEXT_FILE" ]; then
            PRODUCT_CONTEXT=$(cat "$CONTEXT_FILE")
        else
            PRODUCT_CONTEXT="(no product context configured for $REPO)"
        fi
        ;;
    *) log "$PR_ID: knightwatch-config error reading product-context.md — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
write_scratch "$REPO_DIR" "product-context.md" "$PRODUCT_CONTEXT"

# review-priority.md — per-repo operating point + voice posture
# (Broken-Glass Test in standards.md cites this file by name).
# Tri-state: PRESENT use file; ABSENT use embedded default; ERROR abort.
REVIEW_PRIORITY=""
REVIEW_PRIORITY=$(read_knightwatch_file "$REPO_DIR" "$DEFAULT_BRANCH_SHA" "review-priority.md")
case $? in
    0) : ;;  # PRESENT: use as-is
    1)
        # ABSENT: emit a short pointer at the canonical universal policy
        # in standards.md instead of carrying a second policy source
        # here (drift hazard with the per-repo .knightwatch/review-priority.md).
        # The universal Broken-Glass posture lives in standards.md
        # § Broken-Glass Test; cold-start operators get reasonable
        # behavior without us shadowing the canonical text.
        REVIEW_PRIORITY=$(cat <<'PRIORITY_EOF'
# Review priority (default — no per-repo file configured)

This repo has no `.knightwatch/review-priority.md` committed. Default behavior:
- Apply `standards.md` § Broken-Glass Test on all findings (universal Broken-Glass policy).
- Treat the repo's `.knightwatch/product-context.md` (if present) as the operating-point source.
- No repo-specific contrast pairs. The universal contrast pairs in `standards.md` apply.

If this repo needs a different operating point, commit `.knightwatch/review-priority.md` to the base branch.
PRIORITY_EOF
)
        log "$PR_ID: review-priority.md ABSENT in $DEFAULT_BRANCH_SHA — using default content"
        ;;
    *) log "$PR_ID: knightwatch-config error reading review-priority.md — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
write_scratch "$REPO_DIR" "review-priority.md" "$REVIEW_PRIORITY"

# loc-trend.md — per-round LOC trajectory for the momentum specialist
# and aggregator's loop-breaker mode (see § Broken-Glass Test).
LOC_TREND=$(compute_loc_trend "$REPO" "$PR_NUM" "$REPO_DIR" "$DEFAULT_BRANCH_SHA" "$STATE_DIR" "$RUN_DIR" "$REVIEWED_SHA")
write_scratch "$REPO_DIR" "loc-trend.md" "$LOC_TREND"

FILE_HISTORY=""
# Derive file-history's file list from $KID_INPUT_DIFF via the shared
# extract_touched_files_both_sides helper (lib/diff-build.sh) — single
# source of truth for "paths touched by this diff." The previous inline
# `^diff --git a/(.*) b/.*` parse only emitted the a/ side, which
# silently dropped rename targets and any path that only appears on
# the b/ side (the same Narrow-Fix gap the strict-typing scope gate
# already routes around by reusing this helper).
while IFS= read -r f; do
    [ -z "$f" ] && continue
    FILE_HISTORY+="### $f"$'\n'
    hist=$(git -C "$REPO_DIR" log --oneline -n 5 -- "$f" 2>/dev/null)
    FILE_HISTORY+="${hist:-(no history)}"$'\n\n'
done < <(printf '%s' "$KID_INPUT_DIFF" | extract_touched_files_both_sides | head -30)
write_scratch "$REPO_DIR" "file-history.md" "${FILE_HISTORY:-(no touched files)}"

# PR_DATA + PR_AUTHOR were fetched earlier (above the env mirror) so the
# trust gate could see the author. Reuse them here.
AUTHOR_INTENT="## PR Title
$(printf '%s' "$PR_DATA" | jq -r '.title // empty')

## PR Description (author's own explanation)

$(printf '%s' "$PR_DATA" | jq -r '.body // "(no description provided)"')
"
ISSUE_COUNT=0
while IFS=$'\t' read -r IS_OWNER IS_NAME IS_NUM; do
    [ -z "$IS_NUM" ] && continue
    [ "$ISSUE_COUNT" -ge 5 ] && break
    ISSUE_DATA=$(gh issue view "$IS_NUM" --repo "$IS_OWNER/$IS_NAME" --json title,body 2>/dev/null)
    IS_TITLE=$(printf '%s' "$ISSUE_DATA" | jq -r '.title // empty')
    IS_BODY=$(printf '%s' "$ISSUE_DATA" | jq -r '.body // empty')
    if [ -n "$IS_TITLE" ]; then
        [ "$ISSUE_COUNT" -eq 0 ] && AUTHOR_INTENT+=$'\n## Linked issues (this PR closes)\n\n'
        AUTHOR_INTENT+="### $IS_OWNER/$IS_NAME#$IS_NUM: $IS_TITLE
$IS_BODY

"
        ISSUE_COUNT=$((ISSUE_COUNT+1))
    fi
done < <(printf '%s' "$PR_DATA" | jq -r '.closingIssuesReferences[]? | [.owner.login, .repo.name, (.number|tostring)] | @tsv' 2>/dev/null)
write_scratch "$REPO_DIR" "author-intent.md" "$AUTHOR_INTENT"

COMMITS=$(printf '%s' "$PR_DATA" | jq -r '.commits[]? | "\(.oid[0:7]) \(.messageHeadline)"')
if [ -z "$COMMITS" ]; then
    log "$PR_ID: gh pr view returned no commits — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
write_scratch "$REPO_DIR" "commits.md" "$COMMITS"

SPECIALISTS_DIR="$REPO_DIR/.codex-scratch/specialists"
mkdir -p "$SPECIALISTS_DIR"

# Every codex invocation goes through run-specialist.sh — it writes the
# prompt, output, and codex stderr into runs/<RUN_ID>/agents/<name>/.
# Symlinks under .codex-scratch/ keep the prompt-cited paths
# (.codex-scratch/inferred-intent.md, .codex-scratch/specialists/<angle>.md,
# .codex-scratch/critic.md) resolving to those outputs.
log "$PR_ID: inferring developer intent..."
INTENT_PROMPT=$(substitute_placeholders \
    "$HOME/.pr-reviewer/prompts/intent.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
"$_LIB_DIR/run-specialist.sh" "intent" "$REPO_DIR" "$INTENT_PROMPT" "$RUN_DIR/agents/intent"
INTENT_EXIT=$?
INTENT_OUT="$RUN_DIR/agents/intent/output.md"
ln -sfn "$INTENT_OUT" "$REPO_DIR/.codex-scratch/inferred-intent.md"

if [ "$INTENT_EXIT" -ne 0 ] || [ ! -s "$INTENT_OUT" ]; then
    log "$PR_ID: intent inference failed (codex exit=$INTENT_EXIT, output empty=$([ ! -s "$INTENT_OUT" ] && echo true || echo false)) — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

INTENT_NONBLANK_LINES=$(grep -cv '^[[:space:]]*$' "$INTENT_OUT")
if [ "$INTENT_NONBLANK_LINES" -ne 1 ]; then
    log "$PR_ID: intent output has $INTENT_NONBLANK_LINES non-blank lines, expected exactly 1 — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

if ! grep -q '^Inferred intent: ' "$INTENT_OUT"; then
    log "$PR_ID: intent output missing 'Inferred intent: ' prefix — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

log "$PR_ID: intent inference complete: $(head -1 "$INTENT_OUT")"

# ---- dead-code-search LLM pre-pass ----
# Reads .codex-scratch/dead-code-static.md (raw static-tool output) +
# diff.patch and writes structured evidence to .codex-scratch/dead-code.md
# for the `consumers` specialist to file findings from. Same pattern as
# the intent pre-pass above: synchronous, sequential, non-fatal on
# failure (degrades to empty evidence; consumers specialist falls back
# to its degraded LLM-grep mode).
log "$PR_ID: dead-code search..."
DC_PROMPT=$(substitute_placeholders \
    "$HOME/.pr-reviewer/prompts/dead-code-search.md" \
    "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
"$_LIB_DIR/run-specialist.sh" "dead-code-search" "$REPO_DIR" "$DC_PROMPT" "$RUN_DIR/agents/dead-code-search"
DC_EXIT=$?
DC_OUT="$RUN_DIR/agents/dead-code-search/output.md"
if [ "$DC_EXIT" -eq 0 ] && [ -s "$DC_OUT" ]; then
    ln -sfn "$DC_OUT" "$REPO_DIR/.codex-scratch/dead-code.md"
    log "$PR_ID: dead-code search complete ($(wc -l < "$DC_OUT") line(s) of evidence)"
else
    log "$PR_ID: dead-code search failed (exit $DC_EXIT, empty=$([ ! -s "$DC_OUT" ] && echo true || echo false)) — consumers specialist falls back to degraded LLM-grep mode"
    : > "$REPO_DIR/.codex-scratch/dead-code.md"
fi

ANGLES=(security data-integrity architecture simplification tests shape performance consumers)

log "$PR_ID: launching ${#ANGLES[@]} specialists in parallel..."
declare -A AGENT_PIDS=()
for angle in "${ANGLES[@]}"; do
    PROMPT=$(build_specialist_prompt \
        "$angle" \
        "$HOME/.pr-reviewer/prompts/${angle}.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
    "$_LIB_DIR/run-specialist.sh" \
        "$angle" \
        "$REPO_DIR" \
        "$PROMPT" \
        "$RUN_DIR/agents/$angle" &
    AGENT_PIDS["$angle"]=$!
done

# Per-PID wait so a non-zero exit from run-specialist.sh (codex error or
# empty output) actually surfaces as a worker abort. Bare `wait` returns 0
# even when individual children failed, so a partial codex output could
# previously slip through the empty-file check and reach the aggregator.
SPECIALIST_FAILURE=0
for angle in "${ANGLES[@]}"; do
    if ! wait "${AGENT_PIDS[$angle]}"; then
        log "$PR_ID: specialist $angle exited non-zero (see $RUN_DIR/agents/$angle/log.txt)"
        SPECIALIST_FAILURE=1
    fi
done
# Symlink each specialist's output into the codex-scratch view so the
# critic + aggregator prompts ('.codex-scratch/specialists/<angle>.md')
# resolve to it. Created after the per-PID wait completes — half-written
# outputs aren't visible through the symlink during the parallel phase.
for angle in "${ANGLES[@]}"; do
    ln -sfn "$RUN_DIR/agents/$angle/output.md" "$SPECIALISTS_DIR/${angle}.md"
done
if [ "$SPECIALIST_FAILURE" -ne 0 ]; then
    log "$PR_ID: at least one specialist failed — aborting review"
    rm -rf "$REPO_DIR"
    exit 1
fi
log "$PR_ID: all ${#ANGLES[@]} specialists completed"
for angle in "${ANGLES[@]}"; do
    LINES=$(wc -l < "$SPECIALISTS_DIR/${angle}.md")
    NO_FINDINGS=""
    grep -q '^No findings\.' "$SPECIALISTS_DIR/${angle}.md" && NO_FINDINGS=" (no findings)"
    log "$PR_ID: specialist=$angle lines=$LINES$NO_FINDINGS"
done

# Momentum specialist — runs only on re-reviews. Outputs prose-only
# trajectory meta-finding for the aggregator's loop-breaker (Path 2).
# Skipped on first reviews (where the aggregator handles absence by
# design); on re-reviews failure is fail-loud — see the abort below.
if [ -s "$RUN_DIR/inputs/previous-review.md" ]; then
    log "$PR_ID: launching momentum specialist (re-review)..."
    MOMENTUM_PROMPT=$(substitute_placeholders \
        "$HOME/.pr-reviewer/prompts/momentum.md" \
        "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR")
    "$_LIB_DIR/run-specialist.sh" "momentum" "$REPO_DIR" "$MOMENTUM_PROMPT" "$RUN_DIR/agents/momentum"
    MOMENTUM_EXIT=$?
    if [ $MOMENTUM_EXIT -ne 0 ]; then
        # Fail-fast > graceful degradation. Path 2 of the aggregator's
        # loop-breaker depends on this output; an absent momentum.md
        # silently demotes Path 2 to "no structural callout," which is
        # wrong output on exactly the re-reviews where the callout
        # matters most. Mirror the existing fail-loud abort pattern
        # (see knightwatch-config error arms above).
        log "$PR_ID: momentum specialist failed (exit $MOMENTUM_EXIT) — aborting review (Path 2 needs this output; silent degrade would produce wrong loop-breaker behavior)"
        rm -rf "$REPO_DIR"
        exit 1
    fi
    MOMENTUM_OUT="$RUN_DIR/agents/momentum/output.md"
    ln -sfn "$MOMENTUM_OUT" "$REPO_DIR/.codex-scratch/momentum.md"
else
    log "$PR_ID: skipping momentum specialist (first review)"
fi

log "$PR_ID: critic pass..."
CRITIC_PROMPT=$(cat "$HOME/.pr-reviewer/prompts/critic.md")
"$_LIB_DIR/run-specialist.sh" "critic" "$REPO_DIR" "$CRITIC_PROMPT" "$RUN_DIR/agents/critic"
CRITIC_EXIT=$?
CRITIC_OUT="$RUN_DIR/agents/critic/output.md"

# Log the failure mode for the run.log narrative; critic_fallback in
# lib/agent-fallback.sh handles the actual file substitution and is the
# regression-fenced path (see lib/tests/critic-fallback-smoke.sh).
# Empty-output is reported as exit 3 by run-specialist.sh, so it lands
# here as a non-zero CRITIC_EXIT — there's no separate elif branch.
if [ "$CRITIC_EXIT" -ne 0 ]; then
    log "$PR_ID: critic exited $CRITIC_EXIT — discarding any partial/empty output, falling back to placeholder (see agents/critic/log.txt)"
fi
critic_fallback "$CRITIC_EXIT" "$CRITIC_OUT"
ln -sfn "$CRITIC_OUT" "$REPO_DIR/.codex-scratch/critic.md"

log "$PR_ID: aggregator (with critic input)..."
# build_aggregator_prompt stitches in prompts/voice.md (operator-tunable
# voice + tone) at aggregator.md's INSERT_VOICE_HERE marker, then
# substitutes placeholders. The aggregator is NOT a specialist — must
# not inherit the specialist common-header which would demand the
# Surveyed/Finding-N output shape — so it gets its own build path.
if ! AGG_PROMPT=$(build_aggregator_prompt "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR"); then
    log "$PR_ID: build_aggregator_prompt failed — aborting (incomplete install or stitch-contract regression)"
    rm -rf "$REPO_DIR"
    exit 1
fi
"$_LIB_DIR/run-specialist.sh" "aggregator" "$REPO_DIR" "$AGG_PROMPT" "$RUN_DIR/agents/aggregator"
AGG_EXIT=$?
AGG_OUT="$RUN_DIR/agents/aggregator/output.md"

# Aggregator output is what gets posted to GitHub — abort on any codex error
# even if a partial output happens to be non-empty, so a truncated review
# never ships.
if [ "$AGG_EXIT" -ne 0 ] || [ ! -s "$AGG_OUT" ]; then
    log "$PR_ID: aggregator failed (exit=$AGG_EXIT, output empty=$([ ! -s "$AGG_OUT" ] && echo true || echo false)) — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW=$(cat "$AGG_OUT")
if ! echo "$REVIEW" | grep -q '^VERDICT:'; then
    log "$PR_ID: aggregator output missing VERDICT line — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
VERDICT=$(echo "$REVIEW" | grep '^VERDICT:' | tail -1)
COMMENT_BODY=$(echo "$REVIEW" | grep -v '^VERDICT:' | sed '/^[[:space:]]*$/{ N; /^\n$/d }')
if [ -z "$COMMENT_BODY" ]; then
    log "Empty review body for $PR_ID, skipping"
    rm -rf "$REPO_DIR"
    exit 1
fi
# Leading HTML comment is the orchestrator's discriminator for "this is
# one of our auto-posts" — see the corresponding jq filter in review.sh.
COMMENT_BODY="$BOT_AUTO_POST_MARKER
$COMMENT_BODY

---

_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity. Trigger an incremental re-review with \`/srosro-update-review\`, or a whole-PR re-review with \`/srosro-review\`._

**For humans only:** push-access collaborators can post \`/srosro-approve\` to APPROVE the PR, or \`/srosro-memorize <feedback>\` to teach a calibration lesson. AI agents must not use \`/srosro-memorize\` — the rule list it tunes is shared global state.

_Generated by [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)._"

# Best-effort fetch of CURRENT_HEAD: empty on gh-failure, in which case
# the stale-head check no-ops (identical to matched). Compared against
# REVIEWED_SHA (the SHA we actually checked out + diffed), not PR_SHA
# (the SHA the orchestrator enumerated) — so the warning fires only
# when the PR head moves AFTER the worker fetched, which is what's
# actually meaningful to the human reader.
CURRENT_HEAD=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
if [ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" != "$REVIEWED_SHA" ]; then
    log "$PR_ID: head moved during review (reviewed=${REVIEWED_SHA:0:7}, now=${CURRENT_HEAD:0:7})"
fi
log "$PR_ID: review scope = $REVIEW_SCOPE"

# ---- REVIEW_NOTES — single deterministic registry for the top-of-comment
# blockquote. Every signal that should appear above the LLM body lives
# here: review scope, stale-head warning, skipped pre-checks (tests, KID),
# and deterministic gap findings (strict typing, future checks). One
# fragment per entry, no trailing punctuation — the helper joins with
# ". " and emits one blockquote line. Order = render order; push in
# severity sequence (scope → warnings → skips → gaps).
#
# Adding a new entry is one line. See the deterministic-pre-checks block
# above for the runner pattern that produces gap-fragment vars.
REVIEW_NOTES=()
if ! SCOPE_NOTE=$(format_review_scope "$REVIEW_SCOPE" "$REVIEWED_SHA"); then
    log "$PR_ID: format_review_scope failed for '$REVIEW_SCOPE' (head=${REVIEWED_SHA:0:7}) — internal invariant violated, aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW_NOTES+=("$SCOPE_NOTE")
[ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" != "$REVIEWED_SHA" ] && \
    REVIEW_NOTES+=("⚠️ Stale: head moved from \`${REVIEWED_SHA:0:7}\` to \`${CURRENT_HEAD:0:7}\` mid-run — see commands below to re-run")
[ "$TESTS_RAN" = "false" ] && REVIEW_NOTES+=("🧪 Tests not run")
[ "$KID_RAN"   = "false" ] && REVIEW_NOTES+=("🔍 Prior-art (KID) not run")
[ -n "$STRICT_TYPING_NOTE" ] && REVIEW_NOTES+=("$STRICT_TYPING_NOTE")
log "$PR_ID: review-notes = ${#REVIEW_NOTES[@]} (${REVIEW_NOTES[*]:-none})"

if ! COMMENT_BODY=$(prepend_review_header "$COMMENT_BODY" "${REVIEW_NOTES[@]}"); then
    log "$PR_ID: prepend_review_header failed (notes=${#REVIEW_NOTES[@]}) — internal invariant violated, aborting (orchestrator will retry)"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Safety net: scrub any host paths that survived the prompt rules. The
# specialists are told to cite repo-relative + slug-prefixed paths, but
# models occasionally leak the workdir abs path or the .siblings/
# symlink prefix. This is the last hop before the comment becomes
# public — strip any remaining workdir/<sibling-abs>/.siblings prefixes.
COMMENT_BODY=$(scrub_review_paths "$COMMENT_BODY" "$REPO_DIR" SOURCE_PATHS)

if ! gh pr comment "$PR_NUM" --repo "$REPO" --body "$COMMENT_BODY"; then
    log "$PR_ID: gh pr comment FAILED — not updating state (next tick will retry)"
    rm -rf "$REPO_DIR"
    exit 1
fi
# Mark "we posted" as a runtime fact; finalize_run will guarantee
# persistence even if the immediate stamp below fails. The early stamp
# is best-effort — if it succeeds, recurrence detection sees posted_at
# right away (useful for runs that race two workers); if it fails, the
# trap repairs it on the way out.
GH_POSTED=true
META_TMP="$RUN_DIR/meta.json.tmp"
if jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {posted_at: $ts}' \
        "$RUN_DIR/meta.json" > "$META_TMP" 2>/dev/null; then
    mv -f "$META_TMP" "$RUN_DIR/meta.json" || rm -f "$META_TMP"
else
    rm -f "$META_TMP"
    log "$PR_ID: meta.json posted_at stamp failed — finalize_run will repair on exit"
fi
# Review posted as a fresh comment (so the author gets a notification).
# Mark eyes resolved BEFORE attempting the placeholder DELETE — if anything
# below trips, the trap shouldn't mark the placeholder as "aborted" when
# the real review is already up.
EYES_RESOLVED=true
if [ -n "$EYES_COMMENT_ID" ]; then
    if gh api "repos/$REPO/issues/comments/$EYES_COMMENT_ID" --method DELETE \
            >/dev/null 2>&1; then
        log "Posted review on $PR_ID (deleted placeholder id=$EYES_COMMENT_ID)"
    else
        log "Posted review on $PR_ID (placeholder id=$EYES_COMMENT_ID delete failed; leaving in place)"
    fi
else
    log "Posted review on $PR_ID (no placeholder was posted)"
fi

APPROVED=false
if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    # PR_AUTHOR was fetched at line ~305 — pass it through so submit_approval
    # doesn't re-query GitHub for a value the worker already has.
    if submit_approval "$REPO" "$PR_NUM" "$BOT_USER" "$PR_AUTHOR" "$APPROVE_BODY"; then
        APPROVED=true
    fi
else
    log "Commented on $PR_ID (no approval)"
fi

if ! state_set "$PR_ID" "$REVIEWED_SHA" "$APPROVED" "$COMMENT_BODY" "$REVIEW_START_TS"; then
    log "$PR_ID: state_set FAILED — review posted but state.json not updated; next tick will re-review this SHA"
    rm -rf "$REPO_DIR"
    exit 1
fi
rm -rf "$REPO_DIR"
# Mark the run completed; the EXIT trap stamps meta.json on the way out.
RUN_STATUS="completed"
log "Done with $PR_ID"
exit 0
