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
# Normalize control bytes (U+0000-001F, U+007F) in PR_TITLE at the
# worker boundary — GitHub allows them via the REST API, jq -r outputs
# the literal bytes, and PR_TITLE flows into both prompts/common-header.md
# ({{PR_TITLE}}) and meta.json.title. Newlines in the title would inject
# prompt content past the read-only fence; control chars in JSON could
# break downstream consumers. Replace-with-space is non-destructive
# (preserves visible structure) and avoids the empty-field hazard.
PR_TITLE=$(printf '%s' "$5" | tr '\000-\037\177' ' ')
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

# REVIEW_START_TS (epoch) drives internal elapsed-time accounting on the
# worker clock. REVIEW_START_ISO drives meta.json.started_at, which
# review.sh's NEXT tick uses as the slash-command cutoff. Prefer the
# dispatcher's tick-fetch time (DISPATCHER_TICK_AT env var, captured by
# review.sh at the top of each per-PR loop iteration) so a comment
# posted in the gap between dispatcher and worker init isn't silently
# dropped by the next tick's "created_at > started_at" filter. Fall
# back to worker-entry time for direct invocations (tests, manual runs).
REVIEW_START_TS=$(date +%s)
# Portable epoch→ISO conversion — `date -u -d "@<epoch>"` is GNU-only and
# breaks on macOS BSD date. Use python3 (already a project dep) for both
# platforms. Same fix as lib/tests/divergent-clock-smoke.sh.
REVIEW_START_ISO="${DISPATCHER_TICK_AT:-$(python3 -c "import datetime; print(datetime.datetime.fromtimestamp(int('$REVIEW_START_TS'), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")}"

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
# LOCAL_STATE_DIR is per-container — sharing it would serialize per-container
# clones/fetches across reviewers. Contents contract (what lives where) is
# enumerated once at the acquire_just_test_lock call below. Defaults to
# STATE_DIR so single-host (non-container) behavior is unchanged.
LOCAL_STATE_DIR="${LOCAL_STATE_DIR:-$STATE_DIR}"
_LIB_DIR_EARLY="${REVIEWER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
. "$_LIB_DIR_EARLY/locking.sh"
if ! acquire_pr_lock "$STATE_DIR" "$(pr_lock_slug "$REPO" "$PR_NUM")"; then
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
# write_scratch lives in lib/scratch.sh so lib/replay.sh can stage scratch
# with the same shape (real files under .codex-scratch/, archived to
# $RUN_DIR/inputs/) without reimplementing the contract. Sourced EARLY —
# it also owns AUTHOR_INTENT_FIELDS, which the pre-setup metadata fetch
# below needs, and `set -u` makes a late source a hard abort. Defines a
# function and a constant only; nothing here depends on the run dir.
. "$_LIB_DIR_EARLY/scratch.sh"
BOT_USER="${BOT_USER:-srosro}"
BOT_CMD_PREFIX="${BOT_CMD_PREFIX:-srosro}"
BOT_AUTO_POST_MARKER="${BOT_AUTO_POST_MARKER:-<!-- knightwatch-reviewer:auto-post -->}"
# Tags the transient "👀 reviewing" placeholder (and its abort/paused edits)
# so a later tick can recognize an unresolved placeholder from a prior tick
# and reuse it instead of stacking a new one. Real reviews never carry it,
# so the reuse check below only ever recycles a placeholder, never a review.
BOT_PLACEHOLDER_MARKER="${BOT_PLACEHOLDER_MARKER:-<!-- knightwatch-reviewer:placeholder -->}"
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
. "$_LIB_DIR/conventions.sh"

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

# --- gh-comments (fetch_issue_comments) — paginated issue-comment reader,
# the shared seam every comment scanner uses. Consumed here by the
# placeholder-reuse lookup below; sourced explicitly (not via a transitive
# import) so the dependency is visible at the call site.
. "$_LIB_DIR/gh-comments.sh"

# --- pr-comments (fetch_pr_comments) — the PR's human comment thread;
# consumed by every specialist (so a specialist sees replies to its own
# prior probes), the critic, and the aggregator. One trusted PR-thread
# channel; decline arbitration over those replies is aggregator-owned.
# (Also sources gh-comments.sh; multi-source is idempotent.)
. "$_LIB_DIR/pr-comments.sh"

# --- author trust + container-mode gate (BEFORE the per-run dir) ---------
# This must run before allocate_run_dir: a skipped/deferred review that
# allocated a run dir first would leak runs/<id>/ on every ~30s poll of a
# permanently-untrusted PR (issue #189). Resolving metadata + trust here and
# gating before allocation means the skip/defer exits land on the
# orchestrator-log fallback (LOG_FILE default above) and create nothing —
# the same shape as the pre-run-dir per-PR lock-contention skip near the top.
# Resolve PR metadata BEFORE the placeholder post: if `gh pr view` fails
# (e.g. closingIssuesReferences-bearing gh that the host can't speak),
# abort cleanly without leaving a "👀 reviewing" placeholder + abort-PATCH
# pair on every tick. Metadata is consumed downstream for BASE_REF (canonical
# fetch), PR_AUTHOR (env-mirror trust gate), title/body/linked-issues
# (AUTHOR_INTENT) — single gh call covers all.
PR_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json "baseRefName,author,$AUTHOR_INTENT_FIELDS" 2>/dev/null)
BASE_REF=$(printf '%s' "$PR_DATA" | jq -r '.baseRefName // empty')
PR_AUTHOR=$(printf '%s' "$PR_DATA" | jq -r '.author.login // empty')
if [ -z "$BASE_REF" ] || [ -z "$PR_AUTHOR" ]; then
    log "$PR_ID: gh pr view returned no baseRefName / author (PR_DATA=${PR_DATA:0:80}) — aborting before placeholder post"
    exit 1
fi

# Author trust — computed once, before any placeholder/clone/codex. Container-
# mode review gate: codex agents run sandbox-bypassed and share the privileged
# dind daemon's netns, so reviewing an UNTRUSTED-author PR risks prompt-injection
# → daemon → host root. Skip untrusted authors entirely here (no placeholder, no
# pipeline) so untrusted content never reaches codex. Trusted (push-access)
# authors review normally; the host (non-container) path is unaffected. Lifts
# when the daemon is unprivileged. Reused below for the .env-mirror/just-test gate.
# Tri-state trust (lib/auth.sh): 0=trusted, 1=definitively untrusted,
# 2=indeterminate (403 rate-limit / 5xx / network — couldn't verify). An
# indeterminate result must NEVER fall through to untrusted-and-skip: a
# throttled lookup of a genuinely-trusted author (e.g. repo owner) would
# silently drop their PR. Defer instead (exit 1, like the gh pr view guard
# above) so the next tick re-checks once the throttle clears.
is_trusted_repo_author "$REPO" "$PR_AUTHOR"; TRUST_RC=$?
case "$TRUST_RC" in
    0) IS_TRUSTED_AUTHOR=true ;;
    *) IS_TRUSTED_AUTHOR=false ;;
esac
# The defer/skip is CONTAINER-MODE ONLY — that's the path where untrusted code
# must never run (codex↔privileged-dind). On the host path an untrusted author
# is reviewed anyway (just without the .env-mirror / just-test, gated on
# IS_TRUSTED_AUTHOR below), so an indeterminate result there needs no defer —
# scoping it here keeps host behavior unchanged.
if [ -n "${REVIEWER_CONTAINER_MODE:-}" ] && [ "$IS_TRUSTED_AUTHOR" != true ]; then
    if [ "$TRUST_RC" -eq 2 ]; then
        # Indeterminate → defer (exit 1, like the gh pr view guard above)
        # so the next tick re-checks once the throttle clears.
        log "$PR_ID: trust check deferred — API error ($PR_AUTHOR); retrying next tick"
        exit 1
    fi
    # Silent skip: no per-tick log line. This exit is now above the per-run
    # run.log, so the only place a line could land is the shared, 5 MB-rotated
    # orchestrator.log — and a permanently-untrusted PR re-fires every ~30s, so
    # logging here (deduped or not) is the wrong layer: it either floods the
    # operator log or needs a per-PR marker that reintroduces the same
    # unbounded-per-PR-artifact shape this branch just removed. An untrusted skip
    # is stable POLICY, not a failure, and was already effectively invisible
    # pre-change (buried in the leaked run.log). The operator-facing "why is this
    # PR unreviewed?" signal belongs at the dispatcher, logged once when it
    # decides coverage — tracked as the dispatcher-side gate follow-up on #189.
    # (The indeterminate DEFER above still logs: it's transient and low-volume.)
    exit 0
fi

# Repo visibility (public|private|internal), lowercased — feeds the security
# threat model and portability bar into the specialist prompts. `gh repo view`
# reports visibility UPPERCASE; the prompts branch on the lowercase string.
# Fail loud on an empty result — same contract as the BASE_REF/PR_AUTHOR guard
# above: a metadata-lookup break must not silently downgrade a public repo to
# the quieter private posture (under-calibrated security + portability review).
# Resolved AFTER the container-mode gate on purpose: an untrusted-author skip
# re-fires every ~30s per PR, so a `gh repo view` above the gate would burn an
# API call per skip tick for a review that never runs. Only reviews that get
# past the gate (and thus reach the prompt build that consumes it) pay for it.
REPO_VISIBILITY=$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null | tr '[:upper:]' '[:lower:]')
if [ -z "$REPO_VISIBILITY" ]; then
    log "$PR_ID: gh repo view returned no visibility — aborting before placeholder post (refusing to review under an assumed posture)"
    exit 1
fi

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
    # The EXIT trap fires on every exit, including the pre-checkout clean
    # skips (concurrent-dedup gate, refs/pull not-yet-published) that never
    # started a real run. No meta.json means no run to finalize — a benign
    # no-op, the finalize-side mirror of cleanup_eyes's EYES_COMMENT_ID guard.
    # Past checkout meta.json always exists, so finalize_meta_json staying
    # fail-loud below catches a genuinely un-stamped real run.
    [ -f "$RUN_DIR/meta.json" ] || return 0
    if ! finalize_meta_json "$RUN_DIR/meta.json" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_STATUS" "$GH_POSTED"; then
        log "$PR_ID: finalize_run failed — meta.json left un-stamped"
    fi
}

log "Reviewing $PR_ID (force_whole_pr=$FORCE_WHOLE_PR)"

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
# The placeholder's leading marker block — written verbatim on every POST and
# PATCH below, and the exact prefix the reuse lookup matches with `startswith`.
# Defined once so all three sites stay byte-identical: reuse depends on it, so
# any drift between writer and matcher would silently break placeholder
# recycling and bring back the per-tick spam. Trailing newline included so a
# body is just "$PLACEHOLDER_HEADER<message>".
PLACEHOLDER_HEADER="$BOT_AUTO_POST_MARKER
$BOT_AI_AUTHOR_MARKER
$BOT_PLACEHOLDER_MARKER
"
# Default placeholder body for any abort path; specific aborts (e.g. the
# Wave B timeout branch in the pipeline block below) override this with
# a more informative message before the EXIT trap fires. Single PATCH
# lifecycle — cleanup_eyes is the only writer of the abort placeholder.
EYES_ABORT_BODY="review aborted before completion — see knightwatch-reviewer logs; will retry on the next tick if the PR head hasn't moved."
cleanup_eyes() {
    if [ "$EYES_RESOLVED" = "true" ] || [ -z "$EYES_COMMENT_ID" ]; then
        return 0
    fi
    # Full retry budget: this PATCH is addressed by $EYES_COMMENT_ID and writes a
    # fixed body, so a retry after a blip the server already applied just rewrites
    # the same comment. Only the POST that CREATES a placeholder is
    # non-idempotent, and that one alone caps retries.
    gh api "repos/$REPO/issues/comments/$EYES_COMMENT_ID" --method PATCH \
        -f body="${PLACEHOLDER_HEADER}${EYES_ABORT_BODY}" \
        >/dev/null 2>&1 || true
}
trap 'finalize_run; cleanup_eyes' EXIT
# SIGTERM (from the dispatcher's `timeout` ceiling) and SIGINT must run the
# EXIT trap too — bare bash exits on an untrapped SIGTERM WITHOUT firing the
# EXIT trap, which would leave the 👀 placeholder dangling on a timeout-kill.
# Re-raising via `exit` triggers EXIT (143=128+SIGTERM, 130=128+SIGINT). The
# dispatcher's `timeout -k` grace window gives this cleanup time to finish
# before the hard SIGKILL lands.
trap 'exit 143' TERM
trap 'exit 130' INT

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

CANONICAL_LOCK_DIR="$LOCAL_STATE_DIR/canonical-locks"
mkdir -p "$CANONICAL_LOCK_DIR"
CANONICAL_LOCK_FILE="$CANONICAL_LOCK_DIR/$REPO_SLUG"
exec {CANONICAL_LOCK_FD}> "$CANONICAL_LOCK_FILE"
flock "$CANONICAL_LOCK_FD" || { log "$PR_ID: canonical flock failed — aborting"; exit 1; }

if [ ! -d "$CANONICAL_DIR/.git" ]; then
    log "Cloning canonical $REPO..."
    if ! gh repo clone "$REPO" "$CANONICAL_DIR" -- --no-single-branch; then
        log "$PR_ID: canonical clone failed — aborting"
        exit 1
    fi
fi

# One-time self-heal: canonicals cloned --depth=500 (before issue #170's
# fix) are still shallow, and a plain fetch never deepens them — so any
# PR whose merge base predates the shallow window keeps failing with
# "no merge base". Convert in place; a no-op forever after.
if [ "$(git -C "$CANONICAL_DIR" rev-parse --is-shallow-repository)" = "true" ]; then
    log "$PR_ID: canonical is shallow — fetching full history (one-time --unshallow)"
    if ! git -C "$CANONICAL_DIR" fetch --unshallow --quiet; then
        log "$PR_ID: canonical --unshallow fetch failed — aborting"
        exit 1
    fi
fi

# PR_DATA + BASE_REF + PR_AUTHOR were resolved in the pre-run-dir trust
# gate block above (before allocate_run_dir) so a `gh pr view` failure
# aborts cleanly without leaving a placeholder. They flow through here to
# the canonical fetch + the downstream env-mirror trust gate /
# AUTHOR_INTENT staging unchanged.

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
# can diff against it locally. Fetches are full-history: a shallow
# window (--depth=500 until issue #170) silently dropped any PR whose
# merge base fell outside it.
if ! git -C "$CANONICAL_DIR" fetch origin "$BASE_REF" --quiet; then
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
if ! fetch_err=$(git -C "$CANONICAL_DIR" fetch origin "+refs/pull/$PR_NUM/head:$PR_BRANCH" --quiet 2>&1); then
    # Clean skip, nothing produced: discard the run dir this worker allocated
    # instead of abandoning one per tick for the whole /head publish window
    # (17+ min observed on plow-pbc/watchmepivot#20) — issue #189's residual
    # half. The `&&` is load-bearing: only a SUCCESSFUL discard repoints the
    # log, so on the rmdir-refused path the dir survives and the line below
    # still lands in its run.log. Volume here is bounded per PR, so the shared
    # orchestrator.log is the right home for the skip line (unlike the per-tick
    # untrusted-author skip, which is why THAT one is silent).
    discard_empty_run_dir "$RUN_DIR" && LOG_FILE="$STATE_DIR/orchestrator.log"
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
        # Same clean-skip discard as the fetch-failure branch above.
        discard_empty_run_dir "$RUN_DIR" && LOG_FILE="$STATE_DIR/orchestrator.log"
        log "$PR_ID: fetched head $FETCHED_HEAD_SHA already reviewed by concurrent worker — skipping cleanly"
        exit 0
    fi
fi

# Seed operator-provided per-repo secret env files into the canonical clone so
# the trusted-author .env mirror (further below) copies them into the per-PR test
# dir. Source is a read-only, /root-only (0700) mount of host secrets — e.g.
# plow's api/.env.test-live (live test-scenario creds CI has but a fresh container
# lacks; without them test-scenarios fails the ANTHROPIC_API_KEY gate). NEVER
# committed (docker/secrets/ is gitignored). Seed the CANONICAL clone, not
# REPO_DIR directly: `git clone --shared` carries only tracked content, and the
# mirror that copies these untracked files into a workdir is push-access-gated —
# so untrusted authors never receive them. Absent dir = clean no-op (most repos
# need no live creds). Runs after the KNOWN_SHA skip so a deduped review doesn't
# seed pointlessly.
repo_env_src="${REPO_ENV_DIR:-/root/.kwr/repo-env}/$REPO_SLUG"
if [ -d "$repo_env_src" ]; then
    repo_env_seeded=0
    while IFS= read -r -d '' env_file; do
        env_rel="${env_file#"$repo_env_src"/}"
        # Fail loud: review-one-pr.sh runs without `set -e`, so an unchecked
        # mkdir/cp failure would count as seeded and let the test run with missing
        # or stale live creds (an opaque downstream ${VAR:?} / scenario failure).
        if ! mkdir -p "$CANONICAL_DIR/$(dirname "$env_rel")" \
           || ! cp "$env_file" "$CANONICAL_DIR/$env_rel"; then
            log "$PR_ID: FATAL — repo-env seed of '$env_rel' failed; aborting before the test runs with missing/stale creds"
            exit 1
        fi
        repo_env_seeded=$((repo_env_seeded + 1))
    done < <(find "$repo_env_src" -type f -print0)
    [ "$repo_env_seeded" -gt 0 ] && log "$PR_ID: seeded $repo_env_seeded operator repo-env file(s) into canonical"
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
# Reuse a prior tick's unresolved placeholder instead of posting a new one.
# During a transient outage (codex quota exhausted, specialist timeout) every
# 2-min tick aborts at the same point and the EXIT trap leaves a paused/aborted
# placeholder behind. Without reuse, each tick POSTs a brand-new placeholder —
# one fresh comment per tracked PR every 2 minutes until the outage clears
# (observed: 39 "codex quota" comments on a single PR). Recycling the existing
# placeholder means the EXIT trap re-PATCHes the SAME comment (a silent edit,
# no notification), so an outage leaves exactly one self-updating marker per
# PR. A real review (or a new PR head) deletes the placeholder on the success
# path, so the next tick genuinely posts fresh.
#
# The leading HTML comment is invisible in rendered Markdown but lets the
# orchestrator's jq filter recognize this as one of our auto-posts so we
# don't self-trigger on the next tick.
#
# Lookup goes through the shared fetch_issue_comments seam (paginated, so a
# placeholder on page 2 of a long thread is still found, and a non-placeholder
# auto-post like a learn-from-replies ACK doesn't hide it). A prior comment is
# accepted as a reusable placeholder ONLY when it is unmistakably ours: authored
# by BOT_USER, and its body starts with the exact auto-post/ai-author/placeholder
# marker header that POST/PATCH below write. A real review — or a third-party
# comment that merely quotes the placeholder marker — therefore can't be adopted
# as EYES_COMMENT_ID and later PATCHed/DELETEd under the bot token. If the fetch
# itself fails we skip placeholder posting for this tick rather than POSTing
# blind: a blind POST on a missed-lookup is exactly the per-tick spam this fixes.
# PLACEHOLDER_HEADER (defined with cleanup_eyes above) is both the matched
# prefix here and the leading block of the POST body below.
EYES_COMMENT_ID=""
if ALL_ISSUE_COMMENTS=$(fetch_issue_comments "$REPO" "$PR_NUM"); then
    EYES_COMMENT_ID=$(printf '%s' "$ALL_ISSUE_COMMENTS" | jq -r \
        --arg bot_user "$BOT_USER" --arg header "$PLACEHOLDER_HEADER" \
        '[ .[] | select(.user.login == $bot_user)
               | select(.body | startswith($header)) ] | last | .id // empty')
    if [ -n "$EYES_COMMENT_ID" ]; then
        log "$PR_ID: reusing prior placeholder (comment id=$EYES_COMMENT_ID) — not stacking a new one"
    else
        # Creates a comment — gh_retry's create guard refuses the retry (see there).
        EYES_COMMENT_ID=$(gh api "repos/$REPO/issues/$PR_NUM/comments" \
            --method POST \
            -f body="${PLACEHOLDER_HEADER}👀 reviewing — [sam's ai review bot](https://github.com/srosro/knightwatch-reviewer)" \
            --jq '.id' 2>/dev/null) || EYES_COMMENT_ID=""
        if [ -n "$EYES_COMMENT_ID" ]; then
            log "$PR_ID: posted reviewing placeholder (comment id=$EYES_COMMENT_ID)"
        else
            log "$PR_ID: failed to post reviewing placeholder (continuing)"
        fi
    fi
else
    log "$PR_ID: could not fetch comments to check for a prior placeholder — skipping placeholder this tick (continuing)"
fi

# Align canonical's local base ref BEFORE the `git clone --shared`.
# The clone maps the source's refs/heads/* into its origin/* refs; it
# does not copy the source's refs/remotes/origin/*. Fetch advances
# only the latter, so update the local head first or the workdir
# diffs against a stale base (observed on cncorp/plow#568). Safe to
# run unconditionally: canonical's HEAD stays on a per-PR branch, so
# this moves neither HEAD nor the working tree.
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

# meta.json — minimal post-mortem header. Written here (after checkout)
# rather than at run-dir allocation so `sha` records what was actually
# reviewed (REVIEWED_SHA) instead of the orchestrator's enumeration SHA
# (PR_SHA). Worker abort paths between RUN_DIR allocation and this point
# leave no meta.json; finalize_run no-ops via its `[ -f "$RUN_DIR/meta.json" ]`
# guard, so the strict finalize_meta_json never sees the missing file.
# started_at uses REVIEW_START_ISO (captured at script entry,
# single-clock-read alongside REVIEW_START_TS) so review.sh's "comments
# newer than this review" cutoff doesn't drift past comments posted
# during the worker's setup window. Title is JSON-escaped via jq so
# titles with quotes / newlines don't break the file.
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
        '{repo: $repo, pr_id: $pr_id, pr_num: $pr_num, sha: $sha, branch: $branch, base_ref: $base_ref, title: $title, force_whole_pr: ($force_whole_pr == "true"), workdir: $workdir, started_at: $started_at}' \
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
# exfiltrate live API keys before the eager-delete runs.
# IS_TRUSTED_AUTHOR was computed once right after PR_AUTHOR resolved (above),
# where it also gates the container-mode review skip. Reused here for the .env
# mirror + just-test skip gate (just_test_skip_reason, lib/auth.sh).
COPIED_ENV_FILES=()
if [ "$IS_TRUSTED_AUTHOR" = true ]; then
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
    log "$PR_ID: skipping .env mirror — PR_AUTHOR=$PR_AUTHOR has no push access"
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
# Check the exit code, not just stdout: a git failure (e.g. "no merge
# base") writes to stderr and leaves stdout empty, which the -z branch
# below would misread as "PR has no changes" — the silent-drop bug of
# issue #170. Failure path re-runs the diff to capture stderr; cheap,
# since a failing diff fails fast.
if ! FULL_PR_DIFF=$(git -C "$REPO_DIR" diff "$BASE_REF_SHA...$REVIEWED_SHA" 2>/dev/null); then
    diff_err=$(git -C "$REPO_DIR" diff "$BASE_REF_SHA...$REVIEWED_SHA" 2>&1 >/dev/null | head -c 300)
    log "$PR_ID: FATAL — git diff ${BASE_REF_SHA:0:7}...${REVIEWED_SHA:0:7} failed: ${diff_err}"
    rm -rf "$REPO_DIR"
    exit 1
fi
if [ -z "$FULL_PR_DIFF" ]; then
    log "$PR_ID: local git diff origin/${BASE_REF}...${REVIEWED_SHA:0:7} returned empty — aborting"
    rm -rf "$REPO_DIR"
    exit 1
fi
# Changed-line count (added + deleted) via structured --numstat, the same
# LOC shape lib/loc-trend.sh uses — exact, and immune to the +/- content-line
# miscount a unified-diff regex parse would introduce. pipeline.py scales
# codex reasoning effort down to medium for PRs under its SMALL_PR_LOC
# threshold, where high reasoning isn't worth the quota. (Binary files report
# `-`/`-`, which awk sums as 0 — correct, they have no line count.)
PR_DIFF_LOC=$(git -C "$REPO_DIR" diff --numstat "$BASE_REF_SHA...$REVIEWED_SHA" 2>/dev/null \
    | awk '{a += $1; d += $2} END {print a + d + 0}')
log "$PR_ID: full PR diff size = ${#FULL_PR_DIFF} bytes, ${PR_DIFF_LOC} changed lines"
KID_INPUT_DIFF="$FULL_PR_DIFF"

# All four "what did the author see last?" values (body, sha, approved,
# started_at) source from runs/ via the latest_author_visible_review_*
# helpers — the single source of truth for prior-author-visible-round
# state. The orchestrator's KNOWN_SHA gate, the slash-command cutoff,
# prior-reviews.md, and the LOC-trend table all consume the same
# author_visible_runs_iter selection, so body/sha/approved/started_at
# can't pick different rounds.
#
# Returns empty on first review (no prior author-visible run); empty
# PREV_BODY then drives previous-review.md to be empty, which the
# momentum gate uses as its "first review, skip momentum" signal.
PREV_BODY=$(latest_author_visible_review "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
KNOWN_SHA=$(latest_author_visible_review_sha "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
PREV_APPROVED=$(latest_author_visible_review_approved "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")

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
        REVIEW_TASK="Whole-PR re-review (requested via /${BOT_CMD_PREFIX}-review). Review the FULL PR diff at .codex-scratch/diff.patch against the standards in .codex-scratch/standards.md — evaluate the entire diff afresh, not just whether prior findings were addressed. Your prior review is in .codex-scratch/previous-review.md, older rounds in .codex-scratch/prior-reviews.md, and the operator thread in .codex-scratch/pr-comments.md — use them for carry-forward, argue-once, and operator-decline arbitration."
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
# Test log lives in reviewer-controlled run state, NOT under $REPO_DIR (the
# PR checkout). A PR author could commit `.test-output.log` as a symlink into
# the unit's writable paths (ReadWritePaths=/home/odio/.pr-reviewer), and the
# truncate/redirect writes below would follow it — a write-through out of the
# sandbox. $RUN_DIR is allocated by the reviewer (line ~160), not the PR.
TEST_LOG="$RUN_DIR/test-output.log"
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

# Convention DETECTION (lib/conventions.sh) — operator-defined via the kwr-config
# repo, read from the trusted BASE_REF_SHA, never PR head (a PR adding a marker on
# its head must not flip detection). A convention repo may declare its own test
# gate (e.g. a SEED's `## Verification`/`ref/verify.sh`) instead of a root justfile,
# so the "no justfile" note below branches on a match. Same predicate in
# lib/replay.sh. NOTE: detection here, but the convention.md WRITE is deferred to
# the write_scratch block below — staging it now would be wiped by the redirect-safe
# .codex-scratch reset that runs after PR-controlled code (so specialists, which
# read the symlink, would never see it).
CONVENTION_DOC=""
CONVENTION_TEST_NOTE=""
CONVENTION_TEST_HEADER=""
CONVENTION_BODY=""
CONVENTION_DOC=$(resolve_binding "$REPO" "$REPO_DIR" "$BASE_REF_SHA"); _conv_rc=$?
case $_conv_rc in
    0)  # Read the body NOW, in the same moment as the frontmatter — the kwr-config
        # cache is mutable (org-sync git-pulls it), so reading body + note/header
        # together avoids staging a body from a different convention revision than
        # the test note/header. The stored body is written after the scratch reset.
        CONVENTION_TEST_NOTE=$(convention_frontmatter "$CONVENTION_DOC" "test-note")
        CONVENTION_TEST_HEADER=$(convention_frontmatter "$CONVENTION_DOC" "test-header")
        CONVENTION_BODY=$(convention_body "$CONVENTION_DOC")
        log "$PR_ID: convention repo — will stage convention.md from $CONVENTION_DOC (review by its grammar)" ;;
    1)  : ;;  # no convention applies — review as a general repo
    2)  log "$PR_ID: kwr-config active but broken (or a matched binding's doc missing) — failing loud, aborting"
        rm -rf "$REPO_DIR"; exit 1 ;;
esac

# Read standards HERE too, in the same early moment as the convention body/note —
# both come from the mutable kwr-config cache (org-sync git-pulls it), so reading
# them together avoids staging convention docs and standards/*.md from different
# revisions if a pull lands mid-review. resolve_standards (lib/conventions.sh):
# kwr-config standards/*.md when active, else the ~/.claude bundle.
STANDARDS=$(resolve_standards)

# `just test` runs PR-controlled code. Skip it when there's no justfile, or when
# the author is untrusted (no push access) — on EVERY path. Untrusted test code
# would otherwise run with the reviewer's home-dir read access (~/.ssh, the gh
# PAT) + network (host path), or drive the privileged dind daemon (container
# path). just_test_skip_reason (lib/auth.sh) is the single source of truth.
JUST_TEST_SKIP_REASON=$(just_test_skip_reason "$JUST_FILE" "$IS_TRUSTED_AUTHOR")
if [ -n "$JUST_TEST_SKIP_REASON" ]; then
    log "$PR_ID: skipping \`just test\` — $JUST_TEST_SKIP_REASON (author $PR_AUTHOR)"
    TESTS_RAN=false
    # For a convention repo whose convention declares a test-gate (test-note) and
    # that has no justfile, "not run (no justfile)" is the EXPECTED shape, not a
    # coverage gap — the gate is the convention's own (e.g. a SEED's
    # `## Verification`/ref/verify.sh). Surface the convention's note so the tests
    # specialist doesn't read a missing justfile as a missing harness. (Only the
    # no-justfile skip; an untrusted-author skip still reports its security reason.)
    if [ -n "$CONVENTION_TEST_NOTE" ] && [ -z "$JUST_FILE" ]; then
        TEST_SUMMARY="$CONVENTION_TEST_NOTE"
    else
        TEST_SUMMARY="not run ($JUST_TEST_SKIP_REASON)"
    fi
    : > "$TEST_LOG"
else
    # Global concurrency cap on `just test` (MAX_CONCURRENT_TESTS slots,
    # default 3). Each `just test` brings up a docker compose stack, so we
    # ration how many run at once to stay under the unit's MemoryHigh —
    # this is a memory bound, NOT correctness. plow's test-scenarios
    # namespaces its compose project name + host ports per checkout dir,
    # so concurrent same-repo and cross-repo runs no longer collide on
    # shared host state (the hardcoded chat-postgres-1 stack that forced
    # the old per-repo mutex was removed from `just test` 2026-05-15; #638
    # deletes it). See lib/locking.sh::acquire_just_test_lock.
    JUST_TEST_LOCK_WAIT_START=$(date +%s)
    # #100's global N-slot semaphore, with slots in the SHARED STATE_DIR so the
    # MAX_CONCURRENT_TESTS cap on concurrent `just test` holds ACROSS reviewer
    # containers — protecting the host's memory. (This subsumes the per-container
    # just-test lock; LOCAL_STATE_DIR scopes the canonical clone lock + ephemeral
    # KID query copies — per-account stop-state lives in $STATE_DIR/pool/,
    # see lib/state-io.sh.)
    acquire_just_test_lock "$STATE_DIR"
    JUST_TEST_LOCK_WAIT=$(( $(date +%s) - JUST_TEST_LOCK_WAIT_START ))
    if [ "$JUST_TEST_LOCK_WAIT" -ge 5 ]; then
        log "$PR_ID: just-test slot acquired after ${JUST_TEST_LOCK_WAIT}s queue"
    fi
    # Cap the inner test window to the outer worker budget left (the dispatcher
    # stamps WORKER_DEADLINE_EPOCH; unset on a direct/smoke invocation → full
    # window). This keeps the inner `timeout -k` firing before the outer worker
    # timeout, so a wedged test is reaped by the inner -k (which reaches its
    # process group) rather than orphaned by the outer kill while this lock is
    # released — see cap_test_timeout. Reserve 35s = the 30s inner kill-after
    # (below) + a 5s scheduling buffer, so the inner SIGKILL lands strictly
    # before the outer SIGTERM instead of racing it on the same second.
    if [ -n "${WORKER_DEADLINE_EPOCH:-}" ]; then
        TEST_WINDOW=$(cap_test_timeout "$WORKER_DEADLINE_EPOCH" "$(date +%s)" 35 "$TEST_TIMEOUT")
    else
        TEST_WINDOW="$TEST_TIMEOUT"
    fi
    if [ -z "$TEST_WINDOW" ]; then
        log "$PR_ID: worker budget exhausted by ${JUST_TEST_LOCK_WAIT}s just-test queue — skipping \`just test\`"
        release_just_test_lock
        TESTS_RAN=false
        TEST_SUMMARY="not run (worker timeout budget exhausted by queue wait)"
        : > "$TEST_LOG"
    else
        log "$PR_ID: running \`just --justfile $JUST_FILE test\` (timeout ${TEST_WINDOW})..."
        # 30s kill-after: `just test` runs in its own process group (run_just_test's
        # inner `timeout` creates it), so the dispatcher's outer `timeout -k` can't
        # reach a SIGTERM-ignoring pytest tree — only this inner -k can. The subtree
        # shares the inner group, so the SIGKILL reaps it wholesale.
        run_just_test "$JUST_FILE" "$REPO_DIR" "$TEST_LOG" "$TEST_WINDOW" 30s
        TEST_EXIT=$?
        release_just_test_lock
        IFS=$'\t' read -r TESTS_RAN TEST_SUMMARY < <(classify_just_test_outcome "$TEST_EXIT" "$TEST_LOG" "$TEST_WINDOW")
    fi
fi
TEST_LOG_TAIL=$(tail -n 500 "$TEST_LOG")
# The header only uses the 500-line tail; drop the full log now that it's been
# read + classified. It lives in reviewer-owned $RUN_DIR (persists after the
# workdir is wiped), and trusted-author `just test` output can carry creds/PII
# beyond the tail — don't retain the unbounded artifact.
rm -f "$TEST_LOG"

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
# $STANDARDS was captured in the early convention-read section above (alongside the
# convention body/note) so a mid-review org-sync pull can't split it from the
# convention docs across revisions.

# ---- kid prior-art ----
PRIOR_ART=""
KID_FLAG="$STATE_DIR/kid-last-failure"
# KID_RAN tracks whether the prior-art lookup actually executed and
# returned. Flipped false on any "didn't run" path so the disclosure
# header (built below) can warn the reader that the architecture-refined
# specialist's cross-repo DRY signal is missing for this run.
KID_RAN=false
# Per-repo kid index path. KID_PATHS was loaded at file scope via the
# tracked-repos.sh loader (Bash arrays don't survive the process
# boundary between review.sh and this worker; the loader pre-declares
# KID_PATHS empty so the lookup is safe under `set -u` even if
# repos.conf is absent in a test sandbox).
KID_PROJECT_PATH="${KID_PATHS[$REPO]:-}"
if [ -n "$KID_PROJECT_PATH" ] && [ -d "$KID_PROJECT_PATH/.keepitdry" ] && [ -n "$KID_INPUT_DIFF" ] && [ -f "${KWR_CLONE_ROOT:-}/knightwatch-kid/scripts/kid_dry_check.py" ]; then
    # The index is mounted read-only (host kid-refresh owns it), but ChromaDB's
    # sqlite needs write access even for a query (WAL). Query a throwaway copy in
    # a per-container writable dir: cp is cheap (~0.2s, page-cached), keeps each
    # review on the freshest host-refreshed index, and isolates the query from
    # the shared index entirely. Falls back to the path itself if the copy fails.
    KID_QUERY_DIR="$LOCAL_STATE_DIR/kid-query/${PR_ID//[^a-zA-Z0-9]/_}"
    if rm -rf "$KID_QUERY_DIR" && mkdir -p "$KID_QUERY_DIR" \
       && cp -r "$KID_PROJECT_PATH/.keepitdry" "$KID_QUERY_DIR/.keepitdry"; then
        export KID_PROJECT="$KID_QUERY_DIR"
    else
        log "$PR_ID: kid index copy failed — querying source path directly"
        export KID_PROJECT="$KID_PROJECT_PATH"
    fi
    KID_STDERR=$(mktemp)
    PRIOR_ART=$(printf '%s' "$KID_INPUT_DIFF" | python3 "$KWR_CLONE_ROOT/knightwatch-kid/scripts/kid_dry_check.py" 2>"$KID_STDERR")
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
    rm -rf "$KID_QUERY_DIR"
elif [ -z "$KID_PROJECT_PATH" ]; then
    log "$PR_ID: no KID_PATHS entry for $REPO — skipping prior-art lookup"
# Test the kid ENTRYPOINT's reachability, not `-z KWR_CLONE_ROOT`: tracked-repos.sh
# defaults KWR_CLONE_ROOT unconditionally, so an unset test can never fire and this
# misconfig used to fall through to the "index not yet built" message below —
# indistinguishable from the legitimate pre-index state. With KID_ROOT unset in
# config.env the fleet renders no /kwr mount at all, so the entrypoint is simply absent.
elif [ ! -f "${KWR_CLONE_ROOT:-}/knightwatch-kid/scripts/kid_dry_check.py" ]; then
    log "$PR_ID: no kid_dry_check.py under KWR_CLONE_ROOT=${KWR_CLONE_ROOT:-} — skipping prior-art lookup (KID_ROOT unset in config.env, or 'just fleet' not re-run?)"
elif [ -n "$KID_INPUT_DIFF" ]; then
    log "$PR_ID: kid index not yet built at $KID_PROJECT_PATH — skipping prior-art lookup (an index outside KID_ROOT also needs its host path listed in KID_EXTRA_MOUNTS in config.env)"
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
# Redirect-safe staging — wipe + recreate .codex-scratch HERE, immediately before
# the first write and AFTER all PR-controlled execution (`just test`, canonical
# fetch). A PR checkout could commit .codex-scratch as a symlink to a writable
# service path, OR a trusted-author `just test` could replace it with one mid-run;
# either would make the root-owned write_scratch + per-specialist writes below
# redirect critic/momentum/dead-code outputs (and prompt files) into that target.
# Wiping after the untrusted code runs closes both. Mirrors lib/sibling-symlinks.sh.
rm -rf "$REPO_DIR/.codex-scratch"
mkdir -p "$REPO_DIR/.codex-scratch"
write_scratch "$REPO_DIR" "diff.patch"         "$KID_INPUT_DIFF"
write_scratch "$REPO_DIR" "previous-review.md" "$PREV_BODY"
write_scratch "$REPO_DIR" "test-results.md"    "$TEST_RESULTS"
write_scratch "$REPO_DIR" "prior-art.md"       "${PRIOR_ART:-}"
write_scratch "$REPO_DIR" "dead-code-static.md" "${DEAD_CODE_STATIC:-}"
write_scratch "$REPO_DIR" "search-roots.md"    "${SEARCH_ROOTS:-}"
write_scratch "$REPO_DIR" "standards.md"       "$STANDARDS"
# convention.md — staged HERE (after the redirect-safe reset above), not at
# detection time, so the .codex-scratch entry survives for the specialists.
# Write the BODY READ AT DETECTION (CONVENTION_BODY), not a fresh read of the
# mutable cache, so the staged body matches the test note/header read earlier
# (org-sync may have git-pulled the cache to a new revision in between).
[ -n "$CONVENTION_DOC" ] && write_scratch "$REPO_DIR" "convention.md" "$CONVENTION_BODY"

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
# review-task.md is the authoritative per-run task/scope statement
# common-header.md points agents at — without it the static
# "re-review diffs are normally incremental" default misreads
# whole-PR and fallback runs (their diff.patch is the FULL PR diff).
write_scratch "$REPO_DIR" "review-task.md" "$REVIEW_TASK"

# Stage prior aggregator outputs for this PR (every preserved run dir
# except the current one) so the aggregator's carry-forward rule (Re-review handling)
# can check whether prior probes' cited shapes still exist at HEAD. Empty /
# absent on the first review of a PR. Logic lives in
# lib/run-dir.sh::stage_prior_reviews so the smoke test exercises the same
# function the worker calls.
PRIOR_REVIEWS=$(stage_prior_reviews "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR")
if [ -n "$PRIOR_REVIEWS" ]; then
    PRIOR_COUNT=$(printf '%s' "$PRIOR_REVIEWS" | grep -c '^--- review at ')
    log "$PR_ID: staging $PRIOR_COUNT prior review(s) for carry-forward"
    write_scratch "$REPO_DIR" "prior-reviews.md" "$PRIOR_REVIEWS"
fi

# Reviewer policy from REVIEW.md at the repo root (per-repo, committed to
# the base branch — PR-head edits don't take effect until merged). It carries
# the operating point and any repo-specific calibration, and nothing else:
# universal review policy (voice posture, decline rules, review-loop rules) is
# prepended to every agent from prompts/policy.md by lib/pipeline.py's
# build_prompt, so no repo carries it. The .knightwatch/ prose files are gone.
# PRESENT-empty and ABSENT both mean "no per-repo policy", in which case
# resolve_review_md injects the org default (pre-PMF, handful of users)
# rather than silently reviewing for scale — the recurring over-engineering
# failure.
# resolve_review_md (lib/knightwatch-config.sh) is the shared
# read+classify+default seam — same one lib/replay.sh uses, so the two
# staging paths can't drift. rc=2 (git/ref error) → abort with our own
# cleanup; PRESENT/ABSENT both yield usable content.
REVIEW_MD=$(resolve_review_md "$REPO_DIR" "$BASE_REF_SHA") && REVIEW_MD_RC=0 || REVIEW_MD_RC=$?
[ "$REVIEW_MD_RC" = 2 ] \
    && { log "$PR_ID: knightwatch-config error reading REVIEW.md — aborting"; rm -rf "$REPO_DIR"; exit 1; }
write_scratch "$REPO_DIR" "review.md" "$REVIEW_MD"
# rc=1 → org default substituted. Disclosed in REVIEW_NOTES below, because the
# posted review's AI-author footer points readers at "the repo's REVIEW.md" and
# there isn't one; silently reviewing at an unstated operating point is the
# thing the note exists to prevent.
[ "$REVIEW_MD_RC" = 1 ] && log "$PR_ID: no REVIEW.md in $BASE_REF_SHA — using org default"

# convention.md (if any) was detected + staged earlier from the trusted
# BASE_REF_SHA (see the convention-detection block above), alongside the
# TEST_SUMMARY / test-header it drives.

# loc-trend.md — per-round LOC trajectory for the momentum specialist
# and aggregator's loop-breaker mode (see § Broken-Glass Test).
LOC_TREND=$(compute_loc_trend "$REPO" "$PR_NUM" "$REPO_DIR" "$BASE_REF_SHA" "$STATE_DIR" "$RUN_DIR" "$REVIEWED_SHA")
write_scratch "$REPO_DIR" "loc-trend.md" "$LOC_TREND"

# reeval-status.md — the durable architecture-shape re-evaluation note.
# Folds two deterministic triggers into one file every specialist + the
# momentum standalone + the aggregator read:
#   - T1 (LOC growth): computed in loc-trend.sh; read this round's flag
#     line straight out of $LOC_TREND (single owner of the LOC math).
#   - already-fired flags: whether the per-trigger banner marker is
#     present in any prior posted review ($PRIOR_REVIEWS) — so each
#     banner fires at most once per PR, and a fired trigger stays a
#     durable note for every *later* round's specialists even after the
#     banner itself is gone. T2 (blocker-stall) is computed by the
#     aggregator post-resolution, so only its *prior* firing is knowable
#     here; the aggregator owns deciding whether T2 fires this round.
REEVAL_LOC_LINE=$(printf '%s\n' "$LOC_TREND" | grep -E '^REEVAL-LOC-TRIGGER:' | head -n1)
[ -z "$REEVAL_LOC_LINE" ] && REEVAL_LOC_LINE="REEVAL-LOC-TRIGGER: unknown (no flag emitted)"
REEVAL_SIZE_LINE=$(printf '%s\n' "$LOC_TREND" | grep -E '^REEVAL-SIZE-TRIGGER:' | head -n1)
[ -z "$REEVAL_SIZE_LINE" ] && REEVAL_SIZE_LINE="REEVAL-SIZE-TRIGGER: unknown (no flag emitted)"
# Re-eval markers are standalone lines the aggregator emits at the top of a
# review body (right after the italicized intent line). reeval_marker_fired
# (lib/run-dir.sh) reads each prior author-visible run's aggregator output
# directly and inspects only its leading 8 lines — no in-band separator
# parsing over $PRIOR_REVIEWS, so a marker string (or a fake separator)
# rendered inside a Sketch fence deep in the body can never spoof the fired
# flag.
REEVAL_LOC_FIRED=no
REEVAL_STALL_FIRED=no
if reeval_marker_fired '<!-- knightwatch-reviewer:reeval-loc -->' "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR"; then
    REEVAL_LOC_FIRED=yes
fi
if reeval_marker_fired '<!-- knightwatch-reviewer:reeval-stall -->' "$STATE_DIR" "$REPO_SLUG_FOR_RUN" "$PR_NUM" "$RUN_DIR"; then
    REEVAL_STALL_FIRED=yes
fi
write_scratch "$REPO_DIR" "reeval-status.md" "$(cat <<REEVAL_EOF
# Re-eval trigger status

This PR can be flagged for a one-time **architecture-shape re-evaluation** when its
trajectory shows scope creep / wrong shape against the inferred intent. Two
deterministic triggers; each fires its banner at most once per PR.

## This round
$REEVAL_LOC_LINE
$REEVAL_SIZE_LINE

## Already fired in a prior round (durable — do NOT re-fire these)
REEVAL-LOC-FIRED: $REEVAL_LOC_FIRED
REEVAL-STALL-FIRED: $REEVAL_STALL_FIRED
REEVAL_EOF
)"

# pr-comments.md — the PR's human comment thread, so every specialist sees
# replies to its own prior probes and the aggregator can arbitrate operator
# declines. Fail-soft on gh-failure. Skipped on first reviews (no
# PRIOR_REVIEWS): no prior bot probes exist for a reply to address, and
# staging pre-review chatter would let a finding class be suppressed before
# the bot has ever raised it. The sentinel (vs an empty/absent file) keeps
# the prompt-input contract intact for consumers that require pr-comments.md.
if [ -z "${PRIOR_REVIEWS:-}" ]; then
    log "$PR_ID: first review (no prior bot reviews) — staging pr-comments.md sentinel"
    write_scratch "$REPO_DIR" "pr-comments.md" "(PR comments intentionally not staged — first review on this PR; no prior bot probes exist for a reply to address)"
else
    PR_COMMENTS=$(fetch_pr_comments "$REPO" "$PR_NUM")
    write_scratch "$REPO_DIR" "pr-comments.md" "$PR_COMMENTS"
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

# PR_DATA was fetched before setup so the trust gate could see the author;
# setup (clone, canonical fetch, tests) can run for tens of minutes, and an
# author editing the title or description in that window would otherwise be
# graded against the pre-setup snapshot. Refresh the author-facing fields —
# they now anchor the intent pre-pass — and re-point PR_TITLE at the same
# snapshot so the prompt header and author-intent.md can't disagree. Falls
# back to the original PR_DATA if the refetch fails (transient gh error);
# stale rationale beats an aborted review.
# Bind a SEPARATE variable rather than rebinding PR_DATA: the refetch asks for
# a narrower field set (no baseRefName/author), so overwriting PR_DATA would
# leave a blob that no longer matches its declaration at the top of this file
# and would silently break any future consumer that reads those fields here.
PR_INTENT_DATA=$(gh pr view "$PR_NUM" --repo "$REPO" --json "$AUTHOR_INTENT_FIELDS" 2>/dev/null)
PR_TITLE_FRESH=$(printf '%s' "$PR_INTENT_DATA" | jq -r '.title // empty' 2>/dev/null | tr '\000-\037\177' ' ')
if [ -n "$PR_TITLE_FRESH" ]; then
    PR_TITLE="$PR_TITLE_FRESH"
else
    # Transient gh failure — fall back to the pre-setup snapshot rather than
    # blanking the rationale this refresh exists to keep current.
    PR_INTENT_DATA="$PR_DATA"
fi
write_scratch "$REPO_DIR" "author-intent.md" "$(build_author_intent "$PR_INTENT_DATA")"

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

# Pre-spend stale-head gate: the last cheap moment to cancel before the
# LLM fan-out. A push that landed during setup (checkout → just test →
# kid → scratch staging — routinely 20-40 min) means this run's snapshot
# is already superseded; posting it anyway is what stacked 61 stale
# reviews across the last 60 plow PRs. Movement DURING the specialists is
# still disclosed post-hoc via the existing ⚠️ Stale header — completed
# reviews are paid for, so they post. Best-effort fetch, fail-open on gh
# failure (empty PRE_SPEND_HEAD → proceed), same shape as the post-run
# CURRENT_HEAD check below. exit 1 rides the normal abort convention:
# the EXIT trap PATCHes the placeholder with EYES_ABORT_BODY and stamps
# meta.json aborted, which keeps this run OUT of the KNOWN_SHA dedup —
# the next orchestrator tick sees the new head as unreviewed and runs it.
PRE_SPEND_HEAD=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "")
if [ -n "$PRE_SPEND_HEAD" ] && [ "$PRE_SPEND_HEAD" != "$REVIEWED_SHA" ]; then
    log "$PR_ID: head moved before specialist kickoff (reviewed=${REVIEWED_SHA:0:7}, now=${PRE_SPEND_HEAD:0:7}) — aborting pre-spend"
    EYES_ABORT_BODY="⏭ review superseded — head moved from \`${REVIEWED_SHA:0:7}\` to \`${PRE_SPEND_HEAD:0:7}\` before the LLM specialists started; aborted pre-spend. The next tick reviews the new head."
    rm -rf "$REPO_DIR"
    exit 1
fi

# Run the LLM review pipeline (intent → dead-code → 8 angles parallel →
# momentum (re-reviews only) → aggregator). Implementation in lib/pipeline.py.
# Per-angle critics run inline within each angle pipeline; no central
# critic, no splitter. Aggregator output written to a deterministic path
# we read after.
PR_ID="$PR_ID" \
PR_TITLE="$PR_TITLE" \
PR_URL="$PR_URL" \
PR_AUTHOR="$PR_AUTHOR" \
REPO_VISIBILITY="$REPO_VISIBILITY" \
PR_DIFF_LOC="$PR_DIFF_LOC" \
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
    # pipeline.py may write the quota sentinel naming the reset time. Hand the
    # most informative abort body we have to cleanup_eyes so the EXIT trap
    # PATCHes the placeholder accordingly — single PATCH lifecycle, same trap.
    # (Specialist timeouts no longer reach this abort path: pipeline.py
    # completes the review and the ⏱️ warning is rendered in REVIEW_NOTES.)
    QUOTA_SENTINEL="$RUN_DIR/_codex_quota.txt"
    if [ -s "$QUOTA_SENTINEL" ]; then
        RESET_AT=$(head -n 1 "$QUOTA_SENTINEL")
        log "$PR_ID: handing codex-quota-error to cleanup_eyes (resets=${RESET_AT})"
        # Pause THIS container until the quota window resets — review-loop.sh's
        # quota_active() reads the same quota-pause file (lib/state-io.sh) and
        # stops claiming PRs until then, so a capped account doesn't keep claiming.
        QUOTA_UNTIL=""
        # Weekly caps carry a date → parse absolute. Short rolling-window resets are
        # a bare time in the ACCOUNT's tz, which container-local `date -d` can
        # misread and resume EARLY — for those, pause a conservative 1h and re-check
        # (re-pauses if still capped) rather than trust the parse.
        if printf '%s' "$RESET_AT" | grep -qE '[0-9]{4}|Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec'; then
            QUOTA_UNTIL=$(date -d "$(printf '%s' "$RESET_AT" | sed -E 's/([0-9])(st|nd|rd|th)/\1/g')" +%s 2>/dev/null)
        fi
        if [ -z "$QUOTA_UNTIL" ] || [ "$QUOTA_UNTIL" -le "$(date +%s)" ]; then
            QUOTA_UNTIL=$(( $(date +%s) + 3600 ))
        fi
        printf '%s\n' "$QUOTA_UNTIL" > "$(quota_pause_file)"
        log "$PR_ID: quota-paused this worker until epoch ${QUOTA_UNTIL} (reset=${RESET_AT})"
        # Body composed AFTER the pause file lands so pool_status reflects this
        # account's fresh pause. The pause is per-account: the PR stays queued
        # and any active account claims it on an upcoming tick — say so, and
        # show the whole pool so the author can see the real wait.
        EYES_ABORT_BODY="⏸ knightwatch paused — reviewer account ${WORKER_ID} hit its codex quota (resets at ${RESET_AT}). This PR stays queued; any active account picks it up on an upcoming tick. If no other account is available, this account retries after its reset. Pool: $(pool_status)"
    fi
    # pipeline.py writes this on a transient codex 429 (it exhausted its own
    # retries against a rate limit) — not a usage cap, so no reset time. Back
    # this worker off for one rate window instead of immediately retrying and
    # re-saturating the account (the 2026-06-03 post-restart 429 storm). Reuses
    # the quota-pause file review-loop.sh already honors; only fires when neither
    # the usage-cap nor the fatal-auth sentinel is present — both are more
    # specific signals whose own handling owns the worker's stop-state (a usage
    # cap has its own reset timer; fatal-auth takes the worker fully offline), so
    # a transient 429 alongside either must not also stamp a 120s pause file.
    RATE_LIMIT_SENTINEL="$RUN_DIR/_codex_rate_limit.txt"
    # pipeline.py writes this when codex's token is FATALLY invalid (reused/
    # rotated refresh token or revoked session) — not a usage cap, so there's no
    # reset time. Take the worker OFFLINE until re-login instead of spin-aborting
    # + commenting on every PR (the shared-login 401 storm of 2026-05-30).
    AUTH_FATAL_SENTINEL="$RUN_DIR/_codex_auth_fatal.txt"
    if [ ! -s "$QUOTA_SENTINEL" ] && [ ! -s "$AUTH_FATAL_SENTINEL" ] && [ -s "$RATE_LIMIT_SENTINEL" ]; then
        BACKOFF_SECS=120
        BACKOFF_UNTIL=$(( $(date +%s) + BACKOFF_SECS ))
        EYES_ABORT_BODY="⏸ knightwatch paused — reviewer account ${WORKER_ID} hit a codex rate limit (429), backing off ~${BACKOFF_SECS}s. This PR stays queued and will be retried on an upcoming tick."
        printf '%s\n' "$BACKOFF_UNTIL" > "$(quota_pause_file)"
        log "$PR_ID: codex 429 rate-limit — backing off this worker ${BACKOFF_SECS}s (until epoch ${BACKOFF_UNTIL})"
    fi
    if [ -s "$AUTH_FATAL_SENTINEL" ]; then
        # Record the live auth.json mtime; review-loop.sh (auth_offline_active,
        # lib/state-io.sh) keeps this worker offline until a NEWER mtime — i.e.
        # an operator re-login — auto-clears it. A cheap stat, no reset timer.
        # Marker first so pool_status in the body reflects this account.
        mark_auth_offline
        EYES_ABORT_BODY="⏸ knightwatch offline — codex auth for reviewer account ${WORKER_ID} is invalid (token reused/revoked, not a usage cap). This PR stays queued; any active account picks it up on an upcoming tick. This account resumes automatically once the operator re-authenticates it. Pool: $(pool_status)"
        log "$PR_ID: codex auth invalid — worker OFFLINE until re-login (auth-offline marker @ mtime=$(head -n1 "$(auth_offline_file)" 2>/dev/null))"
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

_How to use: auto-reviews every new PR and re-reviews after a period of inactivity. Trigger an incremental re-review with \`/${BOT_CMD_PREFIX}-update-review\`, or a whole-PR re-review with \`/${BOT_CMD_PREFIX}-review\`._

**For humans only:** push-access collaborators can post:
- \`/${BOT_CMD_PREFIX}-approve\` — APPROVE the PR.
- \`/${BOT_CMD_PREFIX}-props [from: <specialist>]\` — give props to a specialist's contribution.
- \`/${BOT_CMD_PREFIX}-critique [from: <specialist>]\` — flag a specialist's contribution as a misread.
- \`/${BOT_CMD_PREFIX}-memorize <feedback>\` — teach a calibration lesson (\`learn-from-replies\` updates \`COMMENT_REVIEW_MISTAKES.md\` from your body, sentiment-aware via LLM).

> Props: \`/${BOT_CMD_PREFIX}-props [from: shape] caught a real layering bug we'd have shipped.\`
> Critique: \`/${BOT_CMD_PREFIX}-critique [from: architecture-refined] DRY suggestion misread distinct seams.\`
> Calibration: \`/${BOT_CMD_PREFIX}-memorize the architecture-refined DRY finding was a misread; those helpers serve different contracts.\`

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
[ "$REVIEW_MD_RC" = 1 ] && REVIEW_NOTES+=("⚙️ No REVIEW.md (review using org defaults)")
[ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" != "$REVIEWED_SHA" ] && \
    REVIEW_NOTES+=("⚠️ Stale: head moved from \`${REVIEWED_SHA:0:7}\` to \`${CURRENT_HEAD:0:7}\` mid-run — see commands below to re-run")
# Specialist timeouts and per-call model-capacity bounces no longer abort —
# pipeline.py completes the review with the surviving angles and names the
# skipped ones in _wave_b_timeouts.txt (one shared soft-degrade sentinel for
# both). Disclose them as a header warning rather than silently shipping
# reduced coverage (shared adapter — replay.sh uses the same helper).
TIMEOUT_NOTE=$(timeout_note_for_run "$RUN_DIR")
[ -n "$TIMEOUT_NOTE" ] && REVIEW_NOTES+=("$TIMEOUT_NOTE")
# Symmetric pre-check disclosure: every pre-check emits one fragment
# describing its outcome (pass/fail/skip), not just on miss. Old asym-
# metric pattern collapsed clean-PR headers to scope-only and left
# readers guessing whether tests/KID/typing actually ran. Fail-fast on
# bogus inputs runs through the explicit `if ! ...; then ... exit 1`
# guards below (worker is `set -u` only, no `-e`) — silent header
# omission is the BCR class these guards exist to fence.
# A convention's test-header replaces the generic "Tests not run" fragment only
# when there's no justfile (the convention gate stands in for the absent one); a
# convention repo that DOES have a justfile gets normal test handling.
_CONV_HEADER=""
[ -z "$JUST_FILE" ] && _CONV_HEADER="$CONVENTION_TEST_HEADER"
if ! TESTS_NOTE=$(format_tests_note "$TESTS_RAN" "$TEST_SUMMARY" "$_CONV_HEADER"); then
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

# The fleet's heaviest WRITE, and GitHub's secondary limits are driven mainly by
# content creation — so it is the call most likely to 403. As a bare `gh` it was
# the one call that could not stamp the pause, and a throttled post meant the next
# tick re-ran the entire review (full LLM spend) to POST into the same throttle.
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
    # Full retry budget: DELETE of a specific comment id is idempotent, and a
    # blip stranding the 👀 placeholder on the PR is the worse outcome.
    if gh api "repos/$REPO/issues/comments/$EYES_COMMENT_ID" --method DELETE \
            >/dev/null 2>&1; then
        log "Posted review on $PR_ID (deleted placeholder id=$EYES_COMMENT_ID)"
    else
        log "Posted review on $PR_ID (placeholder id=$EYES_COMMENT_ID delete failed; leaving in place)"
    fi
else
    log "Posted review on $PR_ID (no placeholder was posted)"
fi

if review_is_approval "$VERDICT" "$RUN_DIR"; then
    # review_is_approval (lib/run-dir.sh) is the single owner of the approval
    # rule — APPROVE verdict AND full coverage. A partial review (a specialist,
    # possibly security, timed out) falls through to the no-approval else: it's
    # posted (the ⏱️ header discloses the gap) but never auto-APPROVEd, and the
    # carried-forward `approved` projection reads the same decision next round.
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
# at the orchestrator gate, slash-cutoff started_at, worker's PREV_BODY /
# KNOWN_SHA / PREV_APPROVED). The four pieces of round state the legacy
# state_set call used to persist are already on disk in runs/ at this point:
#   - body       → agents/aggregator/output.md (already written above)
#   - reviewed_sha → meta.json.reviewed_sha (stamped post-checkout)
#   - approved   → derived from output.md's verdict + coverage by
#                  latest_author_visible_review_approved (via review_is_approval)
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
