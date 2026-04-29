# Skip Self-PR Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the bot's auto-review verdict is APPROVE on a PR authored by the bot user itself, skip the `gh pr review --approve` API call (which GitHub rejects with `Can not approve your own pull request`) and don't lie about the resulting state.

**Architecture:** Pre-flight check the PR's author via `gh pr view --json author`. If `author.login == BOT_USER`, log a clean skip and leave `APPROVED=false`. If the author differs, attempt the approval as today; on a real API failure, log loud and STILL leave `APPROVED=false` (the existing code unconditionally set `APPROVED=true` after the `||`-suppressed call, so `state.json` lied whenever the call failed). The author check itself goes in `lib/auth.sh` as a small helper so it's testable in isolation, mirroring `is_trusted_repo_author`.

**Why this matters:** Today, when the bot reviews a PR srosro authored, the verdict-handler in `lib/review-one-pr.sh:730-744` calls `gh pr review --approve`, GitHub rejects it (`GraphQL: Review Can not approve your own pull request`), the error spills onto stderr → systemd journal, and `||` swallows the exit code. Then `APPROVED=true` runs unconditionally, `log "Approved $PR_ID"` lies, and `state_set` records `approved=true` despite no approval landing. Net effect: journal pollution + state-truth drift. Sample journal entries: `Apr 29 08:30:07 wakeup pr-reviewer[4135180]: failed to create review: GraphQL: Review Can not approve your own pull request`, repeated multiple times today.

**Tech Stack:** bash, `gh pr view --json`, jq, existing `lib/auth.sh` helper-function pattern.

**Files touched:**
- `lib/auth.sh` — new `is_pr_author()` helper
- `lib/review-one-pr.sh` — pre-flight author check + honest APPROVED state
- `lib/tests/auth-smoke.sh` — NEW smoke covering `is_trusted_repo_author` (existing, untested) AND the new `is_pr_author` helper
- `justfile` — wire the new smoke into `just test`

---

### Task 1: New `is_pr_author()` helper in `lib/auth.sh`

**Files:**
- Modify: `lib/auth.sh` — add `is_pr_author REPO PR_NUM USER` after the existing `is_trusted_repo_author`

**Why:** The author lookup is a small, pure-ish API call that's easy to test in isolation. Keeping it next to the existing trust gate also documents the broader "auth-related preflight" surface in one file.

- [ ] **Step 1: Read the current `lib/auth.sh`**

Run: `cat lib/auth.sh`

Expected: a small file with a header comment and the existing `is_trusted_repo_author` function.

- [ ] **Step 2: Append the new helper**

Find this exact line at end of file (the closing `}` of `is_trusted_repo_author`):
```bash
}
```

After it, append:
```bash

# is_pr_author REPO PR_NUM USER — true (exit 0) iff $USER is the GitHub
# account that opened PR_NUM in REPO. Used by lib/review-one-pr.sh's
# auto-approve gate to skip approving the bot's own PRs (GitHub rejects
# with "Can not approve your own pull request").
#
# A 404 / API error returns 1 (treat as "not the author" — the
# subsequent gh pr review call will then fail loud with a real diagnostic
# instead of silently degrading to "skip").
is_pr_author() {
    local repo="$1" pr_num="$2" user="$3"
    [ -z "$user" ] && return 1
    local author
    author=$(gh pr view "$pr_num" --repo "$repo" --json author --jq '.author.login' 2>/dev/null)
    [ "$author" = "$user" ]
}
```

- [ ] **Step 3: Verify the diff is exactly one logical change**

Run: `git diff lib/auth.sh`

Expected: only an addition at the bottom; no edits to the existing function.

- [ ] **Step 4: Sanity-check syntax**

Run: `bash -n lib/auth.sh && echo ok`

Expected: `ok`. Anything else means a typo in the helper.

---

### Task 2: Auth-helpers smoke test (`lib/tests/auth-smoke.sh`)

**Files:**
- Create: `lib/tests/auth-smoke.sh`

**Why:** `lib/auth.sh` has been untested up to now. The new helper needs coverage, and adding a tiny smoke for the existing `is_trusted_repo_author` at the same time is the boy-scout play — both helpers gate side-effecting code paths and a regression in either silently changes whether write actions land. Stubs `gh` via `$HOME/.local/bin/`, same pattern as the other smokes.

- [ ] **Step 1: Write the smoke file**

Create `lib/tests/auth-smoke.sh` with this content:
```bash
#!/bin/bash
# Smoke test for lib/auth.sh — covers both is_trusted_repo_author and
# is_pr_author. Stubs `gh` so the real GitHub API is never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t auth-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.local/bin"

# `gh` stub. Two endpoints we care about:
#   gh api repos/<repo>/collaborators/<user>/permission --jq .permission
#       → echoes $MOCK_TRUSTED_USERS membership
#   gh pr view <num> --repo <repo> --json author --jq .author.login
#       → echoes $MOCK_PR_AUTHOR
cat > "$HOME/.local/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "api" ]; then
    endpoint=""
    for arg in "$@"; do
        case "$arg" in repos/*) endpoint="$arg" ;; esac
    done
    if [[ "$endpoint" == */collaborators/*/permission ]]; then
        user="${endpoint##*/collaborators/}"
        user="${user%/permission}"
        for trusted in ${MOCK_TRUSTED_USERS:-}; do
            if [ "$user" = "$trusted" ]; then echo "write"; exit 0; fi
        done
        echo "none"
    else
        echo "{}"
    fi
elif [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    # MOCK_PR_AUTHOR_FAIL=1 simulates a non-existent PR / API outage.
    if [ -n "${MOCK_PR_AUTHOR_FAIL:-}" ]; then
        echo "gh: not found" >&2
        exit 1
    fi
    echo "${MOCK_PR_AUTHOR:-someuser}"
else
    echo "{}"
fi
STUB
chmod +x "$HOME/.local/bin/gh"

# Source the helpers under test.
. "$PROJECT_ROOT/lib/auth.sh"

# --- is_trusted_repo_author ---
echo "  scenario 1: is_trusted_repo_author returns true for a write-access user..."
MOCK_TRUSTED_USERS="srosro someuser" is_trusted_repo_author "cncorp/plow" "someuser" || { echo "FAIL scenario 1: expected trust"; exit 1; }

echo "  scenario 2: is_trusted_repo_author returns false for a non-collaborator..."
MOCK_TRUSTED_USERS="srosro" is_trusted_repo_author "cncorp/plow" "stranger" && { echo "FAIL scenario 2: expected no trust"; exit 1; } || true

echo "  scenario 3: is_trusted_repo_author returns false for empty user..."
is_trusted_repo_author "cncorp/plow" "" && { echo "FAIL scenario 3: empty user should not be trusted"; exit 1; } || true

# --- is_pr_author ---
echo "  scenario 4: is_pr_author returns true when login matches the PR author..."
MOCK_PR_AUTHOR="srosro" is_pr_author "cncorp/plow" "100" "srosro" || { echo "FAIL scenario 4: expected match"; exit 1; }

echo "  scenario 5: is_pr_author returns false when login differs..."
MOCK_PR_AUTHOR="srosro" is_pr_author "cncorp/plow" "100" "delattre1" && { echo "FAIL scenario 5: expected no match"; exit 1; } || true

echo "  scenario 6: is_pr_author returns false on empty user..."
is_pr_author "cncorp/plow" "100" "" && { echo "FAIL scenario 6: empty user should not be the author"; exit 1; } || true

echo "  scenario 7: is_pr_author returns false on gh API failure (defaults to 'not author')..."
MOCK_PR_AUTHOR_FAIL=1 is_pr_author "cncorp/plow" "100" "srosro" && { echo "FAIL scenario 7: API failure should not assert authorship"; exit 1; } || true

echo "  PASS (7 scenarios: trust-yes, trust-no, trust-empty, author-match, author-mismatch, author-empty, author-api-failure)"
```

- [ ] **Step 2: Make it executable + verify syntax**

```bash
chmod +x lib/tests/auth-smoke.sh
bash -n lib/tests/auth-smoke.sh && echo ok
```

Expected: `ok`.

- [ ] **Step 3: Run it — should PASS even before lib/review-one-pr.sh changes**

Run: `bash lib/tests/auth-smoke.sh`

Expected: all 7 scenarios pass. The helpers are pure (no side effects), so this stage is just locking the API.

- [ ] **Step 4: Wire it into `just test`**

Find this block in `justfile`:
```just
    echo ""
    echo "=== state-io smoke test ==="
    bash lib/tests/state-io-smoke.sh
```

Insert AFTER it:
```just

    echo ""
    echo "=== auth smoke test ==="
    bash lib/tests/auth-smoke.sh
```

- [ ] **Step 5: Run the full suite**

Run: `just test`

Expected: all smokes green, including the new `auth smoke test`.

- [ ] **Step 6: Commit just the helper + smoke**

```bash
git add lib/auth.sh lib/tests/auth-smoke.sh justfile
git commit -m "feat(auth): is_pr_author helper + smoke for the auth helpers

is_pr_author REPO PR_NUM USER returns true iff USER is the PR's
author per gh pr view. Used in the next commit to skip
self-approve attempts in lib/review-one-pr.sh, but added here as
its own commit so the helper + tests land cleanly before the
caller starts depending on them.

Also adds lib/tests/auth-smoke.sh (7 scenarios: trust + author +
empty + API-failure paths) — both helpers were previously
untested. Wired into \`just test\`."
```

---

### Task 3: Auto-approve preflight in `lib/review-one-pr.sh`

**Files:**
- Modify: `lib/review-one-pr.sh:730-744` — add author preflight; honor real API failures

**Why:** This is the actual fix. Today's code:
```bash
APPROVED=false
if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" 2>&1 \
        || log "Approve skipped (own PR or already approved)"
    APPROVED=true
    log "Approved $PR_ID ($APPROVE_BODY)"
else
    log "Commented on $PR_ID (no approval)"
fi
```

Two real bugs there:
1. The GraphQL "can not approve your own PR" error spills to stderr → journal every time the bot reviews its own PR.
2. `APPROVED=true` runs unconditionally after `||`, so `state.json` records `approved=true` even when the call failed.

- [ ] **Step 1: Confirm BOT_USER is in scope**

Run: `grep -n 'BOT_USER' lib/review-one-pr.sh | head -5`

Expected: `BOT_USER="${BOT_USER:-srosro}"` defined in the env-default block near the top of the file. If it's NOT in scope at line 730, escalate — the implementation below assumes it is.

- [ ] **Step 2: Replace the auto-approve block**

Find this exact block in `lib/review-one-pr.sh` (currently around lines 730-744):
```bash
APPROVED=false
if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" 2>&1 \
        || log "Approve skipped (own PR or already approved)"
    APPROVED=true
    log "Approved $PR_ID ($APPROVE_BODY)"
else
    log "Commented on $PR_ID (no approval)"
fi
```

Replace with:
```bash
APPROVED=false
if [[ "$VERDICT" == VERDICT:\ APPROVE* ]]; then
    if [[ "$VERDICT" == *"pending:"* ]]; then
        PENDING_NOTE=$(echo "$VERDICT" | sed 's/.*pending: *//')
        APPROVE_BODY="Approving — pending: $PENDING_NOTE"
    else
        APPROVE_BODY="Approving per automated review above."
    fi
    # Preflight: GitHub forbids self-approval. Skipping the API call
    # avoids a "GraphQL: Review Can not approve your own pull request"
    # error in the journal AND keeps state.json honest (the prior code
    # unconditionally set APPROVED=true even when the call failed).
    if is_pr_author "$REPO" "$PR_NUM" "$BOT_USER"; then
        log "Skipping approve on $PR_ID — PR authored by $BOT_USER (GitHub forbids self-approval)"
    elif gh pr review "$PR_NUM" --repo "$REPO" --approve --body "$APPROVE_BODY" 2>&1 >/dev/null; then
        APPROVED=true
        log "Approved $PR_ID ($APPROVE_BODY)"
    else
        # Most likely cause: a previous tick already approved at this SHA
        # (idempotent dupes are harmless but worth logging), or the API
        # is transiently down. Don't lie about state.
        log "$PR_ID: gh pr review --approve FAILED — see journal; not marking approved"
    fi
else
    log "Commented on $PR_ID (no approval)"
fi
```

Key behavioral changes:
- `is_pr_author` (from Task 1) is the preflight: it short-circuits with a clean log when the author is the bot user.
- The `gh pr review` call now sits inside the `elif` so its exit code drives `APPROVED`. Previously `APPROVED=true` was unconditional.
- On a non-self-author failure (transient API, already-approved, etc.), we log loud and leave `APPROVED=false` so `state.json` doesn't lie.

- [ ] **Step 3: Run the full suite**

Run: `just test`

Expected: all smokes green. No new test scenario specifically covers `lib/review-one-pr.sh`'s auto-approve (the file is integration-heavy and out of unit-test scope), but `auth-smoke.sh` from Task 2 already covers the helper this block now relies on.

- [ ] **Step 4: Commit the auto-approve fix**

```bash
git add lib/review-one-pr.sh
git commit -m "fix(orchestrator): skip auto-approve on bot-authored PRs + don't lie about APPROVED state

Two bugs in the verdict-handler's APPROVE branch:
  1. The bot tries to gh pr review --approve its own PRs; GitHub
     rejects with 'Can not approve your own pull request'. The
     resulting GraphQL error spills onto stderr → systemd journal
     every tick. Sample: 'Apr 29 08:30:07 wakeup pr-reviewer[...]:
     failed to create review: GraphQL: ...'. Preflight via
     is_pr_author (added in the previous commit) skips the API call
     entirely.
  2. APPROVED=true was set unconditionally after the gh call's || ,
     so state.json recorded approved=true even when the call had
     failed. state-io's approved field now reflects reality.

No new smoke for lib/review-one-pr.sh itself (file is too
integration-heavy for unit-style coverage in this repo). Behavior
of the helper it now depends on is locked by auth-smoke.sh."
```

---

### Task 4: Open the PR

- [ ] **Step 1: Push the branch**

Run: `git push -u origin <branch-name>`

- [ ] **Step 2: `gh pr create` with this body**

```markdown
## Summary
The bot's auto-approve path no longer attempts to approve PRs it authored itself, eliminating the "GraphQL: Review Can not approve your own pull request" errors that were spilling into the systemd journal every time we re-reviewed a self-PR. Also fixes a state-truth bug where `state.json` recorded `approved=true` even when the API call had failed.

## What changed
- **`lib/auth.sh`**: new `is_pr_author REPO PR_NUM USER` helper. Mirrors `is_trusted_repo_author`'s shape — small, pure, easy to test.
- **`lib/review-one-pr.sh:730-744`**: pre-flight via `is_pr_author "$REPO" "$PR_NUM" "$BOT_USER"`. Skip the API call entirely if the bot is the author. On a real (non-self-author) failure, log loud and leave `APPROVED=false`. The previous code set `APPROVED=true` unconditionally after `||`-ing the failure log.
- **`lib/tests/auth-smoke.sh`** (new): 7 scenarios covering both `is_trusted_repo_author` (previously untested) and the new `is_pr_author`, including the API-failure default-to-not-author behavior.
- **`justfile`**: wires `auth-smoke.sh` into `just test`.

## Test plan
- [x] `just test` — all smokes green, including the new auth smoke.
- [ ] After deploy, post a `/srosro-update-review` on a srosro-authored PR and confirm the journal shows `Skipping approve on ... — PR authored by srosro` instead of `failed to create review: GraphQL: ...`.
- [ ] Verify `state.json`'s `approved` field for that PR stays `false` even after the verdict handler runs APPROVE.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

- [ ] **Step 3: Babysit the PR through to merge**

Use the standard PR-comment-triage loop (poll knightwatch, reply, fix valid findings, repeat until findings: none, then merge).
