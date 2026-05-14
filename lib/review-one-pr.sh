#!/bin/bash
# Reviews one PR end-to-end. Invoked by review.sh as:
#   TRIGGER_COMMENT_FILE=<path> lib/review-one-pr.sh REPO PR_NUM PR_SHA PR_BRANCH PR_TITLE FORCE_WHOLE_PR
# where FORCE_WHOLE_PR is "true" or "false". TRIGGER_COMMENT_FILE is
# optional and points to a tmp file holding the body of the comment that
# kicked off this review (when triggered by /review or @bot mention);
# the worker slurps it and rm -fs the file early.

set -u
# Inherit PATH from the systemd unit (system dirs first, writable user
# dirs trailing). Do NOT prepend $HOME/.local/bin here — it would let
# an attacker-placed ~/.local/bin/<command> shadow system tools that
# this worker invokes by name. See review.sh's PATH note.

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
# aggregator) and stamped into meta.json.started_at below. Two distinct
# semantics, two fields:
#
#   - started_at      = worker process-entry time. The round's lifecycle
#                       timestamp; rendered in the LoC trend table by
#                       author_visible_rounds(). Stays on the worker clock so
#                       each round has a distinct ts even when no new comments
#                       landed since the prior round (round-driven dispatches).
#   - slash_cutoff_at = the comment-cutoff watermark. Stamped from
#                       SLASH_CUTOFF_AT (review.sh's per-tick computed
#                       max(.created_at) of the fetched snapshot, only
#                       advanced when a slash trigger was actually consumed).
#                       review.sh's NEXT tick reads this via
#                       latest_author_visible_review_started_at and filters
#                       comments with created_at > slash_cutoff_at.
#
# Field split closes the prior overload where started_at carried both
# lifecycle and cutoff meaning — a push-driven dispatch with no new comments
# would inherit the prior round's started_at (because the cutoff didn't
# advance), yielding duplicate (ts, sha) rows in the LoC trend table.
#
# Fallback for direct invocations (tests, manual runs) where SLASH_CUTOFF_AT
# isn't set: slash_cutoff_at uses the worker-entry ISO. For real runs from
# review.sh the env var is always set (possibly carrying forward the
# prior cutoff when the dispatcher decided not to advance it on a
# push-only dispatch).
REVIEW_START_TS=$(date +%s)
# Portable epoch→ISO conversion — `date -u -d "@<epoch>"` is GNU-only and
# breaks on macOS BSD date. Use python3 (already a project dep) for both
# platforms. Same fix as lib/tests/divergent-clock-smoke.sh.
REVIEW_START_ISO=$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(int('$REVIEW_START_TS'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
SLASH_CUTOFF_ISO="${SLASH_CUTOFF_AT:-$REVIEW_START_ISO}"

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
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
# BOT_AI_AUTHOR_MARKER is defined in lib/run-dir.sh (single source of truth);
# this worker sources run-dir.sh below at $_LIB_DIR/run-dir.sh and consumes
# the var when posting the review body.

# Source helpers. Prefer REVIEWER_LIB_DIR if caller set it (smoke-test
# isolation); fall back to the worker's own directory.
_LIB_DIR="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LIB_DIR/state-io.sh"
. "$_LIB_DIR/auth.sh"

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
. "$_LIB_DIR/run-dir.sh"

# --- loc-trend computation (compute_loc_trend / _loc_trend_display) ---
# Sources run-dir.sh internally for is_run_author_visible /
# author_visible_rounds, but run-dir.sh is sourced just above and
# multi-source is idempotent (function redefinition).
. "$_LIB_DIR/loc-trend.sh"

# --- decline-history (fetch_decline_history) — operator's prior declines
# on this PR; consumed by the critic to drop or footnote re-flagged
# findings the operator has pushed back on ≥3 times. Sources gh-comments.sh
# internally; multi-source is idempotent.
. "$_LIB_DIR/decline-history.sh"

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

# meta.json is written later (after REVIEWED_SHA is captured post-checkout)
# so `sha` records what was actually reviewed instead of the orchestrator-
# enumerated PR_SHA. The worker-start timestamp is REVIEW_START_ISO,
# captured at the very top of this script (single-clock-read alongside
# REVIEW_START_TS) — used for meta.json.started_at when meta is written.

# write_scratch lives in lib/scratch.sh so lib/replay.sh can stage scratch
# with the same shape (real files in $RUN_DIR/inputs/, symlinks under
# .codex-scratch/) without reimplementing the contract.
. "$_LIB_DIR/scratch.sh"

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

# Resolve PR metadata BEFORE the placeholder post: if `gh pr view` fails
# (e.g. closingIssuesReferences-bearing gh that the host can't speak),
# abort cleanly without leaving a "👀 reviewing" placeholder + abort-PATCH
# pair on every tick. Metadata is consumed downstream for BASE_REF (canonical
# fetch), PR_AUTHOR (env-mirror trust gate), title/body/linked-issues
# (AUTHOR_INTENT) — single gh call covers all.
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json baseRefName,title,body,author,closingIssuesReferences 2>/dev/null)
BASE_REF=$(printf '%s' "$PR_DATA" | jq -r '.baseRefName // empty')
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
if [ -z "$BASE_REF" ] || [ -z "$PR_AUTHOR" ]; then
    log "$PR_ID: gh pr view returned no baseRefName / author (PR_DATA=${PR_DATA:0:80}) — aborting before placeholder post"
    exit 1
fi

# Install the EXIT trap BEFORE the canonical clone/fetch so finalize_run is
# guaranteed to fire on any abort path. cleanup_eyes is a no-op until
# EYES_COMMENT_ID gets set after the head-ref fetch succeeds (placeholder
# post moved below the canonical fetch — see comment there). An abort BEFORE
# the placeholder post therefore exits with no GitHub side-effects.
#
# Previous structure posted the placeholder before clone/fetch and relied
# on cleanup_eyes to PATCH it to "review aborted" on every abort. That
# left a placeholder + abort-PATCH pair on every 2-min orchestrator tick
# when GitHub hadn't yet published refs/pull/N/head for a freshly-opened
# PR — observed on plow-pbc/watchmepivot#20 (17+ minutes between PR open
# and /head propagation). The canonical fetch is the single readiness
# gate now.
EYES_COMMENT_ID=""
EYES_RESOLVED=false
# Default placeholder body for any abort path; specific aborts (e.g. the
# Wave B timeout branch in the pipeline block below) override this with
# a more informative message before the EXIT trap fires. Single PATCH
# lifecycle — cleanup_eyes is the only writer of the abort placeholder.
EYES_ABORT_BODY="review aborted before completion — see knightwatch-reviewer logs; will retry on the next tick if the PR head hasn't moved."
cleanup_eyes() {
    if [ "$EYES_RESOLVED" = "true" ] || [ -z "$EYES_COMMENT_ID" ]; then
        return 0
    fi
    gh api "repos/$REPO/issues/comments/$EYES_COMMENT_ID" --method PATCH \
        -f body="$BOT_AUTO_POST_MARKER
$BOT_AI_AUTHOR_MARKER
$EYES_ABORT_BODY" \
        >/dev/null 2>&1 || true
}
trap 'finalize_run; cleanup_eyes' EXIT

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

# PR_DATA + BASE_REF + PR_AUTHOR were resolved before the placeholder
# post above so a `gh pr view` failure aborts cleanly without leaving
# a placeholder. They flow through here to the canonical fetch + the
# downstream env-mirror trust gate / AUTHOR_INTENT staging unchanged.

# Fetch latest refs into the canonical clone. We fetch the PR head via
# `refs/pull/N/head` rather than by branch name, so fork PRs work
# uniformly with same-repo PRs (fork PRs' heads live on the fork, not
# on the base repo, so `origin/$PR_BRANCH` doesn't exist there — but
# GitHub mirrors every open PR's head at `refs/pull/N/head` on the base
# repo regardless of source). We still alias it into `refs/heads/
# $PR_BRANCH` so downstream code (per-PR workdir checkout, diff, log
# messages) can use the human-readable branch name.
#
# The base branch is fetched as `origin/$BASE_REF` so the per-PR clone
# can diff against it locally. --depth=500 covers ~all PRs (deepening
# logic could be added if a deep PR's merge-base falls outside that
# window).
if ! git -C "$CANONICAL_DIR" fetch origin "$BASE_REF" --depth=500 --quiet; then
    log "$PR_ID: canonical fetch of $BASE_REF failed — aborting"
    exit 1
fi
# Collision guard: a PR head named the same as the base branch
# (fork PR from the fork's main → upstream's main) would otherwise
# get fetched into refs/heads/$BASE_REF, then overwritten by the
# subsequent update-ref alignment. Operator-fixable (rename the
# fork branch); fail loud.
if [ "$PR_BRANCH" = "$BASE_REF" ]; then
    log "$PR_ID: PR head branch '$PR_BRANCH' collides with base '$BASE_REF' — refusing to fetch into refs/heads/$BASE_REF (would corrupt canonical's base ref)"
    exit 1
fi
if ! fetch_err=$(git -C "$CANONICAL_DIR" fetch origin "+refs/pull/$PR_NUM/head:$PR_BRANCH" --depth=500 --quiet 2>&1); then
    log "$PR_ID: refs/pull/$PR_NUM/head fetch failed (${fetch_err:0:200}) — skipping"
    exit 0
fi

# --- worker-level dedup gate -------------------------------------------------
# Mirrors the dispatcher's gate at review.sh:217 (PR_SHA == KNOWN_SHA &&
# !FORCE_WHOLE_PR → skip), but uses the FETCHED head SHA — the truth as
# of this worker's point in time — not the dispatcher's stale enumeration.
# The dispatcher reads meta.json BEFORE an in-flight worker's finalize_run
# has committed the new SHA back, so two ticks targeting the same trigger
# can both pass the gate. By this point (post per-PR flock + canonical
# fetch), any prior holder's meta.json write is durable AND we have the
# actual head we'd be reviewing. Without this re-check the second worker
# posts a placeholder and immediately PATCHes it to "review aborted" via
# the empty-diff path at line ~626 — noisy on the PR for no useful signal.
if [ "$FORCE_WHOLE_PR" != "true" ]; then
    FETCHED_HEAD_SHA=$(git -C "$CANONICAL_DIR" rev-parse "refs/heads/$PR_BRANCH" 2>/dev/null)
    KNOWN_SHA_GATE=$(latest_author_visible_review_sha "$STATE_DIR" "${REPO//\//_}" "$PR_NUM" "")
    if [ -n "$FETCHED_HEAD_SHA" ] && [ "$FETCHED_HEAD_SHA" = "$KNOWN_SHA_GATE" ]; then
        log "$PR_ID: fetched head $FETCHED_HEAD_SHA already reviewed by concurrent worker — skipping cleanly"
        exit 0
    fi
fi

# Post the "reviewing" placeholder NOW that the canonical fetch confirmed
# the PR head is reachable. The full run (`just test` up to 30m + 6
# specialists + critic + aggregator) can take many minutes; the
# placeholder gives the author immediate feedback that the bot picked up
# the work. Posting AFTER the fetch (instead of before clone+fetch as the
# previous structure did) makes the canonical fetch the single readiness
# gate — when GitHub hasn't yet published refs/pull/N/head for a freshly-
# opened PR, the worker exits silently above with no GitHub side-effects,
# and the orchestrator's 2-min re-dispatch retries until the ref
# propagates.
#
# We post the review as a NEW comment (not by editing this placeholder)
# because GitHub does not fire notifications on comment edits — authors
# would see "👀 reviewing" silently transform 14 minutes later and never
# know the review was ready, leading to "@srosro review please" pings even
# though the review was already up. On any abort path past this point, the
# EXIT trap edits the placeholder to "aborted" instead so it doesn't read
# as "still reviewing" forever.
#
# The leading HTML comment is invisible in rendered Markdown but lets the
# orchestrator's jq filter recognize this as one of our auto-posts so we
# don't self-trigger on the next tick.
EYES_COMMENT_ID=$(gh api "repos/$REPO/issues/$PR_NUM/comments" \
    --method POST \
    -f body="$BOT_AUTO_POST_MARKER
$BOT_AI_AUTHOR_MARKER
👀 reviewing — [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)" \
    --jq '.id' 2>/dev/null) || EYES_COMMENT_ID=""

if [ -n "$EYES_COMMENT_ID" ]; then
    log "$PR_ID: posted reviewing placeholder (comment id=$EYES_COMMENT_ID)"
else
    log "$PR_ID: failed to post reviewing placeholder (continuing)"
fi

# Align canonical's `refs/heads/$BASE_REF` with the just-fetched
# `refs/remotes/origin/$BASE_REF` BEFORE the `git clone --shared`.
# This is load-bearing for two coupled reasons:
#
# 1. The clone's `refs/remotes/origin/*` mirrors canonical's
#    `refs/heads/*`, NOT canonical's `refs/remotes/origin/*`. So if
#    canonical's `refs/heads/$BASE_REF` is stale (the typical state —
#    `git fetch origin BASE_REF` only updates the remote-tracking
#    ref, never the local head), the workdir's `origin/$BASE_REF`
#    points at a stale SHA that doesn't include the latest base
#    commits.
#
# 2. For SHALLOW canonical clones (cncorp/plow uses --depth=500),
#    `git clone --shared` from a shallow source does NOT set up
#    `objects/info/alternates` in the new clone. So the workdir has
#    ONLY the objects reachable from refs propagated by the clone
#    (canonical's `refs/heads/*` → workdir's `refs/remotes/origin/*`).
#    If BASE_REF_SHA is canonical's `refs/remotes/origin/$BASE_REF`
#    but `refs/heads/$BASE_REF` is stale, that SHA is not in the
#    workdir's reachable object set — and `git diff $BASE_REF_SHA...
#    $REVIEWED_SHA` errors with "Invalid symmetric difference" but
#    bash captures the empty stdout and the bot reads it as an
#    empty diff, then aborts with `local git diff origin/<base>...
#    <reviewed-sha> returned empty — aborting`.
#
# Both fail-modes were observed on cncorp/plow#568 after PR #36
# deployed: every cncorp/plow review aborted at the diff stage
# because the shallow canonical's `refs/heads/main` was at an old
# SHA while `refs/remotes/origin/main` had been advanced by recent
# fetches. The `update-ref` here makes both refs point at the same
# SHA so the workdir gets a usable base via either path.
#
# Safe to run unconditionally: canonical's HEAD is on a per-PR
# `pr-N` branch from a previous review, not on `$BASE_REF`, so
# updating `refs/heads/$BASE_REF` doesn't move HEAD or touch the
# working tree. The .env-mirror step that reads `$CANONICAL_DIR`'s
# working tree is unaffected (working tree files persist across
# ref updates).
if ! git -C "$CANONICAL_DIR" update-ref "refs/heads/$BASE_REF" "refs/remotes/origin/$BASE_REF"; then
    log "$PR_ID: failed to align refs/heads/$BASE_REF with refs/remotes/origin/$BASE_REF in canonical — aborting"
    exit 1
fi
BASE_REF_SHA=$(git -C "$CANONICAL_DIR" rev-parse --verify --quiet "refs/heads/$BASE_REF")
if [ -z "$BASE_REF_SHA" ]; then
    log "$PR_ID: refs/heads/$BASE_REF missing after canonical fetch + update-ref — aborting"
    exit 1
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
# reviewed (PR #35 round-1 finding); using PR_SHA in meta.json's
# reviewed_sha (stamped just below) would also record a SHA that may no
# longer be on the branch (force-push eviction) so the next tick can't
# anchor an incremental diff. REVIEWED_SHA is the source of truth for
# "what this run evaluated"; the stale-head disclosure later compares
# it against the PR's CURRENT_HEAD via gh API to catch movement that
# happens AFTER this point but before posting.
REVIEWED_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
if [ -z "$REVIEWED_SHA" ]; then
    log "$PR_ID: rev-parse HEAD returned empty after checkout — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
if [ "$REVIEWED_SHA" != "$PR_SHA" ]; then
    log "$PR_ID: orchestrator enumerated ${PR_SHA:0:7}, worker checked out ${REVIEWED_SHA:0:7} — using checked-out SHA for header + state + meta"
fi

# Redirect-safe staging — a PR checkout could commit .codex-scratch as a
# symlink to a writable service path (e.g. ~/.pr-reviewer/runs/...) so that
# write_scratch + the per-specialist symlinks would redirect critic /
# momentum / dead-code outputs into our own state dir. Wipe + recreate
# unconditionally before any write so the worker owns the directory.
# Mirrors lib/sibling-symlinks.sh's .siblings/ wipe-then-recreate pattern.
rm -rf "$REPO_DIR/.codex-scratch"
mkdir -p "$REPO_DIR/.codex-scratch"

# meta.json — minimal post-mortem header. Written here (after checkout)
# rather than at run-dir allocation so `sha` records what was actually
# reviewed (REVIEWED_SHA) instead of the orchestrator's enumeration SHA
# (PR_SHA). Worker abort paths between RUN_DIR allocation and this point
# leave no meta.json; finalize_meta_json's missing-file path is tolerant.
#
# Two distinct timestamps (see the REVIEW_START_TS/SLASH_CUTOFF_ISO block
# upstream for the rationale): started_at is the round's lifecycle clock
# (worker process-entry time, distinct per round so author_visible_rounds'
# LoC-table render shows one row per round), slash_cutoff_at is the
# comment-cutoff watermark for review.sh's next-tick filter (sourced from
# SLASH_CUTOFF_AT, only advanced when a slash trigger was consumed).
# Title is JSON-escaped via jq so titles with quotes / newlines don't
# break the file.
if ! jq -n \
        --arg repo "$REPO" \
        --arg pr_id "$PR_ID" \
        --argjson pr_num "$PR_NUM" \
        --arg sha "$REVIEWED_SHA" \
        --arg branch "$PR_BRANCH" \
        --arg base_ref "$BASE_REF" \
        --arg title "$PR_TITLE" \
        --arg force_whole_pr "$FORCE_WHOLE_PR" \
        --arg workdir "$WORKDIRS_DIR/${REPO_SLUG_FOR_RUN}__${PR_NUM}" \
        --arg started_at "$REVIEW_START_ISO" \
        --arg slash_cutoff_at "$SLASH_CUTOFF_ISO" \
        '{repo: $repo, pr_id: $pr_id, pr_num: $pr_num, sha: $sha, branch: $branch, base_ref: $base_ref, title: $title, force_whole_pr: ($force_whole_pr == "true"), workdir: $workdir, started_at: $started_at, slash_cutoff_at: $slash_cutoff_at}' \
        > "$RUN_DIR/meta.json"; then
    log "$PR_ID: failed to write $RUN_DIR/meta.json — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# PR_DATA + BASE_REF + PR_AUTHOR were resolved up front (before the
# canonical fetch), so AUTHOR_INTENT / commits / linked-issue context
# pull from the same blob without a second gh round-trip.

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

# FULL_PR_DIFF is built locally from the just-checked-out worktree:
# `git diff origin/<base>...<reviewed-sha>` — three-dot semantics match
# GitHub's "Files changed" view. Reading from the local snapshot
# instead of `gh pr diff` eliminates a class of races where the live
# GitHub call could serve a different head than REVIEWED_SHA (the BCR
# class flagged across PR #31 and PR #35 reviews — single source of
# truth: the worktree). Also collapses the prior cap-exceeded fallback
# into the primary path, since `git diff` has no server-side file cap.
FULL_PR_DIFF=$(git -C "$REPO_DIR" diff "$BASE_REF_SHA...$REVIEWED_SHA")
if [ -z "$FULL_PR_DIFF" ]; then
    log "$PR_ID: local git diff origin/${BASE_REF}...${REVIEWED_SHA:0:7} returned empty — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
log "$PR_ID: full PR diff size = ${#FULL_PR_DIFF} bytes"
KID_INPUT_DIFF="$FULL_PR_DIFF"

# All four "what did the author see last?" values (body, sha, approved,
# started_at) source from runs/ via the latest_author_visible_review_*
# helpers — the single source of truth for prior-author-visible-round
# state. The orchestrator's KNOWN_SHA gate, the slash-command cutoff,
# prior-reviews.md, and the LOC-trend table all consume the same
# author_visible_runs_iter selection, so body/sha/approved/started_at
# can't pick different rounds.
#
# state.json (state_get / state_set) was retired entirely with this
# refactor — every runtime-decision seam now reads runs/, and the worker
# no longer writes state.json. meta.json is stamped at run init and again
# at finalize_run, both BEFORE the worker can crash mid-write, so the
# "gh post succeeded but state_set failed" race that drove rounds 7-12
# can no longer happen: there is no state_set to fail.
#
# Returns empty on first review (no prior author-visible run); empty
# PREV_BODY then drives previous-review.md to be empty, which the
# momentum gate uses as its "first review, skip momentum" signal.
PREV_BODY=$(latest_author_visible_review "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
KNOWN_SHA=$(latest_author_visible_review_sha "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
PREV_APPROVED=$(latest_author_visible_review_approved "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
[ "$FORCE_WHOLE_PR" = "true" ] && PREV_BODY=""

# Optimization: use a local incremental diff for KID_INPUT_DIFF ONLY
# when (a) the prior reviewed SHA is still on the branch's history AND
# (b) no merge commits exist in the incremental range. Any other
# condition (rebase/force-push, OR branch merged main between then and
# now) would leak merge-from-main content or misframe an off-branch
# SHA — leave KID_INPUT_DIFF as the full PR diff and let
# `prepend_review_header` emit a `fallback:<sha>` scope disclosure at
# the top of the review (via REVIEW_SCOPE).
if [ -n "$KNOWN_SHA" ] && [ "$FORCE_WHOLE_PR" != "true" ]; then
    if is_clean_incremental_available "$REPO_DIR" "$KNOWN_SHA"; then
        KID_INPUT_DIFF=$(git -C "$REPO_DIR" diff "$KNOWN_SHA..$REVIEWED_SHA")
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
        REVIEW_TASK="Whole-PR re-review (requested via /${BOT_CMD_PREFIX}-review). Review the full PR diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md. Any prior review is intentionally NOT provided — evaluate this PR from scratch."
        ;;
    first)
        REVIEW_TASK="Review the diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md."
        ;;
    incremental:*)
        REVIEW_TASK="Re-review: the author has pushed new commits since your previous review (at ${KNOWN_SHA:0:7}, approved=$PREV_APPROVED). Your prior review is in .codex-scratch/previous-review.md. The incremental diff since that review is in .codex-scratch/diff.patch; the full PR diff is in .codex-scratch/full-diff.patch (consult it when verifying whether prior findings are addressed). Assess whether the new commits address your prior concerns, then produce an updated review."
        ;;
    fallback:*)
        REVIEW_TASK="Re-review (clean incremental unavailable for ${KNOWN_SHA:0:7} — either rebase/force-push evicted it from the branch's history, or the branch merged origin/${BASE_REF} between then and now). Your prior review is in .codex-scratch/previous-review.md. Because the incremental view is unavailable, .codex-scratch/diff.patch contains the FULL PR diff (identical to .codex-scratch/full-diff.patch) — evaluate accordingly. Assess whether the current state addresses your prior concerns, then produce an updated review."
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

# BASE_REF_SHA was captured from canonical right after the fetch (well
# before the per-PR clone, the env-mirror, and `just test` — all of
# which run PR-controlled code that could rewrite local refs). The
# downstream `.knightwatch/<file>` reads consume the immutable SHA
# (not the symbolic ref), so a PR that runs
# `git update-ref refs/remotes/origin/main HEAD` during `just test`
# can't redirect the next config read to PR-head policy.

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
    # Scrub LOG_FILE from the test subprocess's env. Otherwise this repo's
    # own lib/tests/test_pipeline.py — which calls pipeline.run_pipeline()
    # via the unittest discover — picks up our LOG_FILE through inheritance
    # and pipeline.log() tees test-fixture chatter ('r#1: launching ...')
    # into the production orchestrator log alongside the real review trace.
    # Cosmetic only (review correctness was unaffected) but makes
    # post-mortem grepping clean.
    timeout "$TEST_TIMEOUT" env -u LOG_FILE just --justfile "$JUST_FILE" --working-directory "$REPO_DIR" test > "$TEST_LOG" 2>&1
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
# (the dead-code-search LLM pre-pass). Command source is the per-repo
# .knightwatch/dead-code.sh file (read below).
#
# Exit-code policy: keep stdout regardless of exit. Some tools (vulture)
# exit 1 *because* findings exist. Treat empty-stdout-AND-non-zero-exit
# as the only degrade signal; non-empty stdout is data.
DEAD_CODE_STATIC=""
# Dead-code static-analysis command from .knightwatch/dead-code.sh
# (per-repo, committed to the base branch). PRESENT-empty and ABSENT
# both mean "no static dead-code check for this repo" — the LLM grep
# pre-pass still runs from the diff alone.
DEAD_CODE_CMD=""
DEAD_CODE_CMD=$(read_knightwatch_file "$REPO_DIR" "$BASE_REF_SHA" "dead-code.sh")
case $? in
    0|1) : ;;  # PRESENT or ABSENT: use as-is (empty / unset = no check)
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

# REVIEWER_LIB_DIR is referenced by the per-repo cmds in
# .knightwatch/strict-typing.sh (which call
# $REVIEWER_LIB_DIR/checks/<lang>-strict-typing.sh). Export so it
# propagates into the `bash -c "$cmd"` subshells below.
export REVIEWER_LIB_DIR="$_LIB_DIR"

# Strict-typing pre-check. Per-repo cmd from .knightwatch/strict-typing.sh
# delegates to lib/checks/<lang>-strict-typing.sh. Helper contract is tri-state:
#   exit 0 — strict mode enforced.
#   exit 1 — gap (stdout has verbose detail → logged).
#   exit 2 — checker error (stderr has details → logged loud, no note).
# The tri-state is load-bearing: collapsing checker errors into "gap"
# silently publishes wrong review text on broken inputs (bad PROJECT_DIR,
# malformed config file, refused symlink). Fail-loud here keeps the
# deterministic section honest.
STRICT_TYPING_NOTE=""
# Strict-typing pre-check command from .knightwatch/strict-typing.sh
# (per-repo, committed to the base branch). PRESENT-empty and ABSENT
# both mean "no strict-typing check for this repo" (e.g. bash repos).
STRICT_TYPING_CMD=""
STRICT_TYPING_CMD=$(read_knightwatch_file "$REPO_DIR" "$BASE_REF_SHA" "strict-typing.sh")
case $? in
    0|1) : ;;  # PRESENT or ABSENT: use as-is (empty / unset = no check)
    *) log "$PR_ID: knightwatch-config error reading strict-typing.sh — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
if [ -n "$STRICT_TYPING_CMD" ]; then
    STRICT_STDERR=$(mktemp)
    STRICT_GAP=$(cd "$REPO_DIR" && bash -c "$STRICT_TYPING_CMD" 2>"$STRICT_STDERR")
    STRICT_RC=$?
    case $STRICT_RC in
        0) STRICT_TYPING_NOTE="✅ Strict typing enforced" ;;
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
if ! SEARCH_ROOTS=$(stage_search_roots "$REPO" "$REPO_DIR" "$BASE_REF_SHA"); then
    log "$PR_ID: stage_search_roots failed (knightwatch-config error) — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi

# Materialize sibling-repo content under .siblings/<owner>/<repo>, but
# ONLY for siblings stage_search_roots above just classified as
# `included` (whitelisted in SOURCE_PATHS AND checkout present on disk
# AND a git repo). Running before stage_search_roots would copy content
# from siblings whose checkouts are absent. If materialization fails
# (corrupt git objects, source disappeared after classification,
# disk full, permission), abort the review — better to fail loud
# than serve specialists partial sibling content while claiming
# `included` coverage. Materializer details (HEAD-snapshot pinning,
# blob reads via `git show`, mode filtering) live in
# lib/sibling-symlinks.sh and shouldn't be duplicated here.
INCLUDED_SLUGS=()
while IFS= read -r line; do
    case "$line" in
        *' included '*) INCLUDED_SLUGS+=("${line%% included *}") ;;
    esac
done <<< "$SEARCH_ROOTS"
if ! materialize_sibling_symlinks "$REPO_DIR" SOURCE_PATHS "${INCLUDED_SLUGS[@]}"; then
    log "$PR_ID: materialize_sibling_symlinks failed — aborting (would otherwise serve partial sibling content while claiming full coverage)"
    rm -rf "$REPO_DIR"
    exit 1
fi

# ---- write scratch files ----
write_scratch "$REPO_DIR" "diff.patch"         "$KID_INPUT_DIFF"
write_scratch "$REPO_DIR" "previous-review.md" "$PREV_BODY"
write_scratch "$REPO_DIR" "test-results.md"    "$TEST_RESULTS"
write_scratch "$REPO_DIR" "prior-art.md"       "${PRIOR_ART:-}"
write_scratch "$REPO_DIR" "dead-code-static.md" "${DEAD_CODE_STATIC:-}"
write_scratch "$REPO_DIR" "search-roots.md"    "${SEARCH_ROOTS:-}"
write_scratch "$REPO_DIR" "standards.md"       "$STANDARDS"

# ---- probe schema ----
# probe-schema.md ships in prompts/ and is symlinked into ~/.pr-reviewer/prompts
# at install time. Specialists + per-angle critics + aggregator (Phases 2+)
# reference .codex-scratch/probe-schema.md as the canonical contract. Missing
# on disk is fail-fast — same shape as the prompt loader in lib/pipeline.py;
# a missing prompt means an incomplete deploy, not "operator opted out."
PROBE_SCHEMA_PATH="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/probe-schema.md"
if [ ! -f "$PROBE_SCHEMA_PATH" ]; then
    log "$PR_ID: probe-schema.md missing at $PROBE_SCHEMA_PATH — incomplete install — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
write_scratch "$REPO_DIR" "probe-schema.md" "$(cat "$PROBE_SCHEMA_PATH")"

[ -n "${FULL_PR_DIFF:-}" ] && \
    write_scratch "$REPO_DIR" "full-diff.patch" "$FULL_PR_DIFF"
[ -n "$TRIGGER_COMMENT_BODY" ] && \
    write_scratch "$REPO_DIR" "trigger-comment.md" "$TRIGGER_COMMENT_BODY"

# Stage prior aggregator outputs for this PR (every preserved run dir
# except the current one) so the aggregator's carry-forward rule (step 38)
# can check whether prior probes' cited shapes still exist at HEAD. Uses
# the per-run layout from PR #11; before that layout only the most recent
# scratch was kept. Empty / absent on the first review of a PR. Logic lives in
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
        log "$PR_ID: staging $PRIOR_COUNT prior review(s) for carry-forward"
        write_scratch "$REPO_DIR" "prior-reviews.md" "$PRIOR_REVIEWS"
    fi
fi

# Product context from .knightwatch/product-context.md (per-repo,
# committed to the base branch). PRESENT-empty and ABSENT both mean
# "no per-repo product context"; the worker substitutes an explicit
# placeholder below so prompts don't see a blank input.
PRODUCT_CONTEXT=""
PRODUCT_CONTEXT=$(read_knightwatch_file "$REPO_DIR" "$BASE_REF_SHA" "product-context.md")
case $? in
    0|1) : ;;  # PRESENT or ABSENT: use as-is (placeholder substituted below if empty)
    *) log "$PR_ID: knightwatch-config error reading product-context.md — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
[ -z "$PRODUCT_CONTEXT" ] && PRODUCT_CONTEXT="(no product context configured for $REPO)"
write_scratch "$REPO_DIR" "product-context.md" "$PRODUCT_CONTEXT"

# review-priority.md — per-repo operating point + voice posture
# (Broken-Glass Test in standards.md cites this file by name).
# Tri-state: PRESENT use file; ABSENT use embedded default; ERROR abort.
REVIEW_PRIORITY=""
REVIEW_PRIORITY=$(read_knightwatch_file "$REPO_DIR" "$BASE_REF_SHA" "review-priority.md")
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
        log "$PR_ID: review-priority.md ABSENT in $BASE_REF_SHA — using default content"
        ;;
    *) log "$PR_ID: knightwatch-config error reading review-priority.md — aborting"; rm -rf "$REPO_DIR"; exit 1 ;;
esac
write_scratch "$REPO_DIR" "review-priority.md" "$REVIEW_PRIORITY"

# loc-trend.md — per-round LOC trajectory for the momentum specialist
# and aggregator's loop-breaker mode (see § Broken-Glass Test).
LOC_TREND=$(compute_loc_trend "$REPO" "$PR_NUM" "$REPO_DIR" "$BASE_REF_SHA" "$STATE_DIR" "$RUN_DIR" "$REVIEWED_SHA")
write_scratch "$REPO_DIR" "loc-trend.md" "$LOC_TREND"

# decline-history.md — operator declines from prior review comments,
# so the critic can drop or footnote findings the operator has already
# pushed back on. Empty/absent on first reviews and on PRs with no
# operator pushback. Fail-soft on gh-failure (helper emits a sentinel;
# critic falls back to existing behavior).
#
# Skipped on:
#   - FORCE_WHOLE_PR=true (i.e. /srosro-review) — the trigger text on that
#     path commits to "Any prior review is intentionally NOT provided —
#     evaluate this PR from scratch." Staging decline history anyway
#     would silently break that contract.
#   - First reviews (no PRIOR_REVIEWS) — operator declines on bot reviews
#     can't exist before there has been a bot review. Pre-existing operator
#     comments on the PR (review-author conversation, etc.) are not bot-
#     finding declines. Staging them would let the critic suppress finding
#     classes the bot has never raised — a class-of-finding ban with no
#     class-of-finding actually flagged, which is wrong.
# Mirrors the existing prior-reviews.md skip semantics above.
if [ "$FORCE_WHOLE_PR" = "true" ]; then
    log "$PR_ID: FORCE_WHOLE_PR=true — staging decline-history.md sentinel (whole-PR re-review evaluates from scratch)"
    # Sentinel keeps the prompt-input contract intact for critic.md /
    # aggregator.md, which list .codex-scratch/decline-history.md
    # as a required input. Empty/absent file would tempt those agents to
    # explore the filesystem; the sentinel makes the "from scratch"
    # decision explicit.
    write_scratch "$REPO_DIR" "decline-history.md" "(decline history intentionally not staged on /${BOT_CMD_PREFIX}-review path — this is a from-scratch whole-PR re-review)"
elif [ -z "${PRIOR_REVIEWS:-}" ]; then
    log "$PR_ID: first review (no prior bot reviews) — staging decline-history.md sentinel"
    write_scratch "$REPO_DIR" "decline-history.md" "(decline history intentionally not staged — first review on this PR; no prior bot findings exist for the operator to have declined)"
else
    DECLINE_HISTORY=$(fetch_decline_history "$REPO" "$PR_NUM")
    write_scratch "$REPO_DIR" "decline-history.md" "$DECLINE_HISTORY"
fi

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
    # Data-minimization: stage ONLY title + URL, never body. Linked-issue
    # bodies may be private to consumers other than the public PR (the
    # bot's GitHub identity has read access the PR author may not). A
    # specialist or critic that quoted/paraphrased a private body would
    # leak it into the public PR comment via the aggregator render path.
    # Title + repo+number is metadata the PR author can already see; the
    # body is fetched and discarded. Replaces R8/R9's instruction-based
    # privacy guard with a hard data-minimization fix at the source.
    # R10 F#3: drop title too — titles can leak from private repos /
    # private issues whose titles the public PR audience cannot read.
    # Stage only owner/repo#num + URL, which is metadata GitHub already
    # exposes via `closingIssuesReferences` to anyone who can see the PR.
    [ "$ISSUE_COUNT" -eq 0 ] && AUTHOR_INTENT+=$'\n## Linked issues (this PR closes)\n\n'
    AUTHOR_INTENT+="- $IS_OWNER/$IS_NAME#$IS_NUM (https://github.com/$IS_OWNER/$IS_NAME/issues/$IS_NUM)
"
    ISSUE_COUNT=$((ISSUE_COUNT+1))
done < <(printf '%s' "$PR_DATA" | jq -r '.closingIssuesReferences[]? | [.owner.login, .repo.name, (.number|tostring)] | @tsv' 2>/dev/null)
write_scratch "$REPO_DIR" "author-intent.md" "$AUTHOR_INTENT"

# Commits narrative for AUTHOR_INTENT — sourced from the local
# checkout (BASE_REF_SHA..REVIEWED_SHA) rather than PR_DATA.commits.
# PR_DATA was captured before the canonical fetch + checkout, so a
# push that landed in the race window between `gh pr view` and the
# `refs/pull/N/head` fetch would leave PR_DATA's commit list one
# behind REVIEWED_SHA — and specialists would see a commit narrative
# that doesn't match diff.patch / full-diff.patch (round-2 finding
# on PR #36 — same source-of-truth class as the diff itself).
COMMITS=$(git -C "$REPO_DIR" log --pretty=format:'%h %s' "$BASE_REF_SHA..$REVIEWED_SHA")
if [ -z "$COMMITS" ]; then
    log "$PR_ID: git log $BASE_REF_SHA..$REVIEWED_SHA returned no commits — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
write_scratch "$REPO_DIR" "commits.md" "$COMMITS"

# Run the LLM review pipeline (intent → dead-code → 8 angles parallel →
# momentum (re-reviews only) → aggregator). Implementation in lib/pipeline.py.
# Per-angle critics run inline within each angle pipeline; no central
# critic, no splitter. Aggregator output written to a deterministic path
# we read after.
PR_ID="$PR_ID" \
PR_TITLE="$PR_TITLE" \
PR_URL="$PR_URL" \
PR_AUTHOR="$PR_AUTHOR" \
PROMPTS_DIR="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}" \
LOG_FILE="$LOG_FILE" \
OPERATOR_NAME="${OPERATOR_NAME:-Sam}" \
    python3 "$_LIB_DIR/pipeline.py" "$REPO_DIR" "$RUN_DIR"
PIPELINE_EXIT=$?
AGG_OUT="$RUN_DIR/agents/aggregator/output.md"

# Aggregator output is what gets posted to GitHub — abort on any pipeline
# error even if a partial output happens to be non-empty, so a truncated
# review never ships. pipeline.py rm -rf's REPO_DIR on its own abort path;
# the safety-net check below handles any race or unexpected exit.
if [ "$PIPELINE_EXIT" -ne 0 ] || [ ! -s "$AGG_OUT" ]; then
    log "$PR_ID: pipeline failed (exit=$PIPELINE_EXIT, agg empty=$([ ! -s "$AGG_OUT" ] && echo true || echo false)) — aborting"
    # Wave B specialist timeout: pipeline.py wrote a sentinel naming the
    # hung specialists. Hand a specific abort body to cleanup_eyes so the
    # EXIT trap PATCHes the placeholder with the names rather than the
    # generic abort message — single PATCH lifecycle, same trap.
    TIMEOUTS_SENTINEL="$RUN_DIR/_wave_b_timeouts.txt"
    if [ -s "$TIMEOUTS_SENTINEL" ]; then
        TIMED_OUT=$(paste -sd, "$TIMEOUTS_SENTINEL")
        EYES_ABORT_BODY="❌ Review aborted — specialist(s) timed out (\`$TIMED_OUT\`). See knightwatch-reviewer logs; will retry on the next tick."
        log "$PR_ID: handing timeouts-error to cleanup_eyes (specialists=$TIMED_OUT)"
    fi
    [ -d "$REPO_DIR" ] && rm -rf "$REPO_DIR"
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
# The bakeoff marker captures which specialists were invoked on this
# review so lib/bakeoff-store.sh can establish per-review denominators.
# Single source of truth: derive from lib/pipeline.py::SPECIALISTS so adding
# a specialist there also flows into the bakeoff roster automatically.
# aggregator is appended because it can attribute its own cross-angle probes.
# Fail-fast — no fallback. If pipeline.py is broken, we want the review to
# fail loudly here, not silently post with a stale roster.
BAKEOFF_SPECIALISTS=$(python3 -c "import sys; sys.path.insert(0, '$_LIB_DIR/..'); from lib.pipeline import SPECIALISTS; print(','.join(list(SPECIALISTS) + ['aggregator']))")
COMMENT_BODY="$BOT_AUTO_POST_MARKER
$BOT_AI_AUTHOR_MARKER
<!-- knightwatch-bakeoff: specialists=$BAKEOFF_SPECIALISTS -->
$COMMENT_BODY

---

_How to use: auto-reviews every new PR and re-reviews after an hour of inactivity. Trigger an incremental re-review with \`/${BOT_CMD_PREFIX}-update-review\`, or a whole-PR re-review with \`/${BOT_CMD_PREFIX}-review\`._

**For humans only:** push-access collaborators can post:
- \`/${BOT_CMD_PREFIX}-approve\` — APPROVE the PR.
- \`/${BOT_CMD_PREFIX}-props [from: <specialist>]\` — +1 a specialist's contribution (persisted to the bake-off DB and surfaced in the snapshot footer total).
- \`/${BOT_CMD_PREFIX}-critique [from: <specialist>]\` — flag a specialist's contribution as a misread (persisted to the bake-off DB and surfaced in the snapshot footer total).
- \`/${BOT_CMD_PREFIX}-memorize <feedback>\` — teach a calibration lesson (\`learn-from-replies\` updates \`COMMENT_REVIEW_MISTAKES.md\` from your body, sentiment-aware via LLM). Quoting \`[from: <specialist>]\` in the body also credits the bake-off DB for back-compat.

> Props: \`/${BOT_CMD_PREFIX}-props [from: shape] caught a real layering bug we'd have shipped.\`
> Critique: \`/${BOT_CMD_PREFIX}-critique [from: simplification] DRY suggestion misread distinct seams.\`
> Calibration: \`/${BOT_CMD_PREFIX}-memorize the simplification DRY finding was a misread; those helpers serve different contracts.\`

AI agents must not use \`/${BOT_CMD_PREFIX}-memorize\`, \`/${BOT_CMD_PREFIX}-props\`, or \`/${BOT_CMD_PREFIX}-critique\` — those signals tune shared global state.

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
# Symmetric pre-check disclosure: every pre-check emits one fragment
# describing its outcome (pass/fail/skip), not just on miss. Old asym-
# metric pattern collapsed clean-PR headers to scope-only and left
# readers guessing whether tests/KID/typing actually ran. Fail-fast on
# bogus inputs runs through the explicit `if ! ...; then ... exit 1`
# guards below (worker is `set -u` only, no `-e`) — silent header
# omission is the BCR class these guards exist to fence.
if ! TESTS_NOTE=$(format_tests_note "$TESTS_RAN" "$TEST_SUMMARY"); then
    log "$PR_ID: format_tests_note failed (ran='$TESTS_RAN', summary='$TEST_SUMMARY') — internal invariant violated, aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW_NOTES+=("$TESTS_NOTE")
if ! KID_NOTE=$(format_kid_note "$KID_RAN"); then
    log "$PR_ID: format_kid_note failed (ran='$KID_RAN') — internal invariant violated, aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
REVIEW_NOTES+=("$KID_NOTE")
# Strict typing stays guarded: empty STRICT_TYPING_NOTE means the repo
# either has no strict-typing check configured (per-repo strict-typing.sh
# absent + no STRICT_TYPING_CMDS entry) or the checker errored (logged
# loud above). Both cases are correctly silent in the header.
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

if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    # PR_AUTHOR was fetched at line ~305 — pass it through so submit_approval
    # doesn't re-query GitHub for a value the worker already has.
    submit_approval "$REPO" "$PR_NUM" "$BOT_USER" "$PR_AUTHOR" "$APPROVE_BODY" || true
else
    log "Commented on $PR_ID (no approval)"
fi

# state.json retired: every runtime-decision seam reads runs/ now (KNOWN_SHA
# at the orchestrator gate, slash_cutoff_at, worker's PREV_BODY /
# KNOWN_SHA / PREV_APPROVED). The four pieces of round state the legacy
# state_set call used to persist are already on disk in runs/ at this point:
#   - body       → agents/aggregator/output.md (already written above)
#   - reviewed_sha → meta.json.reviewed_sha (stamped post-checkout)
#   - approved   → derived from output.md's `VERDICT: APPROVE` line by
#                  latest_author_visible_review_approved
#   - started_at → meta.json.started_at (stamped at run init)
#   - posted_at  → finalize_run stamps it from the EXIT trap after gh pr
#                  comment succeeded (GH_POSTED=true above)
#
# Nothing left to write here. The previous state_set call duplicated all of
# the above into ~/.pr-reviewer/state.json; since no reader consults that
# file anymore, the duplicate is dead weight and a second write that could
# fail (round-11 BCR class). Deleting it closes that race entirely.
rm -rf "$REPO_DIR"
# Mark the run completed; the EXIT trap stamps meta.json on the way out.
RUN_STATUS="completed"
log "Done with $PR_ID"
exit 0
