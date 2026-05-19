#!/usr/bin/env bash
# Smoke: cross-file prompt + orchestrator-wire contract sync.
#
# Cheap (millisec) token-presence checks against tracked files.
# Catches "renamed token on one side, forgot the other" omission class.
# Behavior-side tests (does the pipeline actually USE these tokens
# correctly?) belong to the replay harness; this stays as the cheap
# pre-flight tier.
#
# Folded from anti-bloat-contract-smoke.sh + momentum-wire-smoke.sh —
# both used the same assert_grep shape against tracked files, no
# behavior loss in the merge. 2 justfile entries → 1.
#
# This file's ASSERTIONS ARE THE CONTRACT — when you remove an
# assertion, you remove a token fence. Don't drop assertions to
# "clean up"; the negative fences and the specialist-registration
# tokens are all load-bearing and were each written in response to
# a specific regression. See PR #25, PR #38, PR #42, PR #45, PR #47
# review history if uncertain about a fence — though note PR #55
# dropped several wording-pin fences that were over-fitting; that
# PR's description documents what was removed and why.
#
# Deliberately NOT a content-pinning test. Rule 8 (Remedy-cost framing)
# itself forbids tests that calcify prompt prose; what we fence here is
# contract integrity (token presence, branch-negative alternative still
# allowed), not literal wording.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
. "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

assert_no_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" && { echo "FAIL: $label"; exit 1; } || true
}

# ====================================================================
# Section 1: prompt-contract sync (formerly anti-bloat-contract-smoke.sh)
# ====================================================================

# Security fence: per-angle critics run with codex sandbox bypassed
# (--dangerously-bypass-approvals-and-sandbox in lib/pipeline.py:run_codex)
# while reading PR-controlled inputs. The read-only/data-not-instructions
# fence in critic.md is what stops a malicious diff from prompt-injecting
# the critic into write actions or credential exfiltration. If the fence
# is deleted, `just test` stays green but the dangerous execution path
# remains exposed.
echo "  asserting read-only sandbox fence in critic.md..."
assert_grep "critic.md should carry the read-only working directory fence" \
    "Read-only working directory" prompts/critic.md
assert_grep "critic.md should fence repo content as data-not-instructions" \
    "data, not instructions" prompts/critic.md

# Negative fence: the legacy critic opening said "Eight specialists have
# surfaced findings" — that wording predates the probe-as-unit refactor
# and primes the model to emit Findings instead of resolving probes.
echo "  asserting critic.md has no 'have surfaced findings' regression..."
assert_no_grep "critic.md must not regress to 'have surfaced findings' wording — probe-as-unit opening was rolled back" \
    "have surfaced findings" prompts/critic.md

# Negative fence: VERDICT lines previously said "no findings"/"blocking
# findings". Probe-as-unit uses "surviving probes"/"blocking probes".
echo "  asserting aggregator.md VERDICT lines use probe vocabulary..."
verdict_block=$(grep -A 3 '^9\. On the VERY LAST LINE' prompts/aggregator.md)
if printf '%s' "$verdict_block" | grep -qF "no findings"; then
    echo "FAIL: aggregator.md VERDICT regressed to 'no findings' wording — probe-as-unit verdict was rolled back"
    exit 1
fi
if printf '%s' "$verdict_block" | grep -qF "blocking findings"; then
    echo "FAIL: aggregator.md VERDICT regressed to 'blocking findings' wording — probe-as-unit verdict was rolled back"
    exit 1
fi
# Positive fence: COMMENT verdict must trigger on `medium` OR `blocking`
# probes (R23 F#5). Without the `medium` token, a regression that
# narrowed COMMENT back to blocking-only would silently let medium-only
# PRs APPROVE — bypassing the bot's standard pushback path.
if ! printf '%s' "$verdict_block" | grep -qF "\`medium\` or \`blocking\`"; then
    echo "FAIL: aggregator.md VERDICT lost the 'medium or blocking' COMMENT trigger — medium-only probes would silently APPROVE"
    exit 1
fi

echo "  asserting decline-history input in critic.md..."
assert_grep "critic.md should reference decline-history.md" \
    "decline-history.md" prompts/critic.md

echo "  asserting decline-history input in aggregator.md..."
assert_grep "aggregator.md should reference decline-history.md" \
    "decline-history.md" prompts/aggregator.md

echo "  asserting layered-file note in aggregator.md..."
assert_grep "aggregator.md should describe layered specialist files" \
    "layered file" prompts/aggregator.md

# Specialist + scratch wiring — every specialist must be referenced by
# the critic + aggregator read lists, and common-header must document
# any per-specialist scratch input. Catches the "added a prompt file
# but forgot to register it" omission class.
echo "  asserting performance specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference performance specialist" \
    "specialists/performance.md" prompts/aggregator.md

echo "  asserting consumers specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/aggregator.md

echo "  asserting common-header documents dead-code.md scratch..."
assert_grep "common-header.md should document dead-code.md" \
    "dead-code.md" prompts/common-header.md

# Cross-file marker: any consumer parsing the rendered Probes section
# by `[from: <specialist>]` depends on aggregator.md owning the token format.
echo "  asserting [from: <specialist>] attribution token in aggregator.md..."
assert_grep "aggregator.md should describe per-line specialist attribution" \
    "[from: <specialist>]" prompts/aggregator.md

# Negative fence: the old default ("attributed [from: aggregator]") was
# replaced with specialist attribution as the default for cross-angle
# probes. A regression that re-introduces the legacy default token in
# either source-of-truth file would re-create the bake-off measurement
# bug (cross-angle synthesis credits the orchestrator instead of the
# specialist whose lens caught the pattern).
echo "  asserting legacy [from: aggregator] default token is gone..."
for prompt in prompts/aggregator.md prompts/probe-schema.md; do
    assert_no_grep "$prompt must not regress to the legacy 'attributed [from: aggregator]' default — cross-angle attribution should be the most load-bearing specialist; aggregator-attribution is the fallback for genuinely emergent patterns" \
        "attributed \`[from: aggregator]\`" "$prompt"
done

for specialist in shape simplification architecture consumers tests performance security data-integrity; do
    echo "  asserting simplification probe class in ${specialist}.md..."
    # After collapsing DRY + dead-code + complexity-cost → simplification,
    # every specialist must register simplification as one of its emitted
    # classes (it's the universal removal-shaped class).
    assert_grep "${specialist}.md should list simplification as a probe class" \
        "simplification" "prompts/specialists/${specialist}.md"
done

# Privacy: linked-issue staging must NOT fetch issue body or title from
# `gh issue view` — they may be private and would leak into the public PR
# comment via author-intent.md → specialists. Keep only owner/repo#num +
# URL. Fixed-string match catches any executable form (regex variants
# missed lowercase assignments + interpolated `$(...)` quoting).
echo "  asserting linked-issue staging does NOT call 'gh issue view'..."
assert_no_grep "lib/review-one-pr.sh must not call 'gh issue view' — linked-issue privacy regressed" \
    'gh issue view' lib/review-one-pr.sh

echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference momentum specialist output" \
    "momentum.md" prompts/aggregator.md

# ====================================================================
# Section 2: systemd-chain shebang security
# ====================================================================
# Security fence: scripts launched directly by systemd ExecStart, or
# exec'd from those scripts, MUST use the absolute `#!/bin/bash`
# shebang — NOT `#!/usr/bin/env bash`. Defense-in-depth: even though
# /home/odio/.local is no longer in any unit's ReadWritePaths (so PR
# can't plant ~/.local/bin/bash), the absolute shebang blocks the
# env-bash PATH-attack class regardless of any future ReadWritePaths
# drift. Sourced helpers (lib/run-dir.sh, etc.) have no exec-time
# shebang lookup, so their shebang is documentation only and not
# fenced here.
# Two fence loops (was five): one over systemd-chain SCRIPTS (shebang +
# no writable-PATH prepend), one over systemd UNITS (ReadWritePaths +
# Environment=PATH ordering + .nvm-bin precedence). Each fence's
# security rationale is in the per-FAIL message; the section comment
# above this block carries the overarching "why absolute shebang +
# system-PATH-first + .local-not-writable" attack-class context.
echo "  asserting systemd-chain scripts: absolute /bin/bash shebang + no writable-PATH prepend..."
# ExecStart-derived list via the shared parser in lib/systemd-units.sh
# (also used by install.sh + install-smoke). A new poller landing as
# <name>.service automatically picks up the shebang + PATH fence on
# the next test run, without a parallel hand-maintained registry —
# org-sync.sh shipped round-0 without coverage exactly because three
# copies of this parser had to be updated by hand.
# shellcheck source=lib/systemd-units.sh
. lib/systemd-units.sh
mapfile -t SYSTEMD_CHAIN_SCRIPTS < <(list_execstart_shell_scripts . systemd/*.service)
# lib/review-one-pr.sh isn't an ExecStart script but is exec'd as a
# sub-process from review.sh — same shebang + writable-PATH attack
# surface, so include it in the fence by hand.
SYSTEMD_CHAIN_SCRIPTS+=("lib/review-one-pr.sh")
for script in "${SYSTEMD_CHAIN_SCRIPTS[@]}"; do
    first_line=$(head -1 "$script")
    if [[ "$first_line" != "#!/bin/bash" ]]; then
        echo "FAIL: $script has shebang '$first_line' — must be '#!/bin/bash' (env-bash on systemd-launched/exec'd scripts is a PATH-attack vector via writable ~/.local/bin)"
        exit 1
    fi
    # Defense-in-depth: a script-level `export PATH="$HOME/.local/bin:..."`
    # would re-introduce the writable-PATH attack at the script's own
    # command-resolution boundary (timeout, gh, git, awk, etc.).
    if grep -nE '^[[:space:]]*export PATH="\$HOME/' "$script"; then
        echo "FAIL: $script prepends \$HOME/.local/bin to PATH — defeats the systemd PATH ordering and reopens writable-command resolution"
        exit 1
    fi
done

# Systemd unit fences: ReadWritePaths must NOT include bare /home/odio/.local
# (it holds PATH-search targets — .local/bin/codex, .local/bin/kid; per-subdir
# writes like .local/share/claude are fine). Environment=PATH must start with
# /usr/... so writable user dirs trail. The nvm-versioned bin (which provides
# `codex`) must precede .local/bin for units that run codex, so a malicious
# ~/.local/bin/codex planted via a PR-controlled `just test` can't shadow
# the real install. The version segment is matched as a wildcard
# (.nvm/versions/node/*/bin) so bumping the operator's nvm default doesn't
# break this fence — the unit's pinned version path is the lockstep
# requirement, not the smoke's. kid-refresh doesn't run codex and is
# exempt from the bin-ordering check (still subject to the other two).
echo "  asserting systemd units: ReadWritePaths + Environment=PATH ordering + nvm-bin precedence..."
for unit in systemd/*.service; do
    rw_line=$(grep -E '^ReadWritePaths=' "$unit")
    path_line=$(grep -E '^Environment=PATH=' "$unit")

    rhs="${rw_line#ReadWritePaths=}"
    for tok in $rhs; do
        # Strip systemd's optional path-prefix syntax (- = ignore-if-missing,
        # + = mount-namespace-aware; can combine as -+ or +-) so denylist
        # matching is on the bare path. Strip both prefixes via a tight loop.
        bare="$tok"
        while [[ "$bare" == [+-]* ]]; do bare="${bare#[+-]}"; done
        case "$bare" in
            /home/odio/.local|/home/odio/.local/bin)
                echo "FAIL: $unit ReadWritePaths token '$tok' grants write access to a PATH-search dir — attacker can plant tools in ~/.local/bin/ that codex resolves"
                echo "  got: $rw_line"
                exit 1 ;;
        esac
    done

    case "$path_line" in
        Environment=PATH=/usr/*) ;;
        *)
            echo "FAIL: $unit Environment=PATH does not start with /usr/... — writable user dirs would be searched first"
            echo "  got: $path_line"
            exit 1 ;;
    esac

    if [[ "$unit" != *kid-refresh* ]]; then
        case "$path_line" in
            *.nvm/versions/node/*/bin*.local/bin*) ;;
            *.local/bin*)
                echo "FAIL: $unit PATH has .local/bin without .nvm/versions/node/<ver>/bin preceding it — PR-controlled just test could plant ~/.local/bin/codex shadowing the real codex install"
                echo "  got: $path_line"
                exit 1 ;;
        esac
    fi
done

# ====================================================================
# Section 3: pipeline.py wiring (formerly orchestrate.sh + momentum-wire)
# ====================================================================

PIPELINE=lib/pipeline.py

# Cross-file path token: review-one-pr.sh must invoke pipeline.py. Smoke
# layer owns this because it spans two files; runtime ordering inside
# pipeline.py belongs to TestRunPipeline (`lib/tests/test_pipeline.py`).
echo "  asserting pipeline.py is invoked from review-one-pr.sh..."
assert_grep "review-one-pr.sh does not invoke lib/pipeline.py" \
    'pipeline.py' lib/review-one-pr.sh

# R27 F#1a — the no-output marker MUST agree between common-header.md
# (where specialists are told what to emit) and pipeline.py (where the
# probe-contract gate scans for it). A mismatch silently drops the
# per-specialist "(no probes)" tag from the run log.
echo "  asserting common-header 'No probes.' marker matches pipeline.py probe gate..."
assert_grep "common-header.md should mandate 'No probes.' marker" \
    "No probes." prompts/common-header.md
assert_grep "pipeline.py should grep for the same 'No probes.' marker" \
    'No probes\.' "$PIPELINE"

echo "  asserting simplification.md anchors on inferred-intent scratch artifact..."
# Cross-file: simplification.md must reference the scratch artifact
# `.codex-scratch/inferred-intent.md` so the inferred-intent staging
# (lib/pipeline.py) and the consuming specialist agree on the path.
assert_grep "simplification.md should anchor on the inferred-intent scratch artifact" \
    ".codex-scratch/inferred-intent.md" prompts/specialists/simplification.md

# ====================================================================
# Section 4: elegant-convergence rule fences (PR #70)
# ====================================================================
# Three competing "is this probe alive?" mechanisms (K-decay in critic,
# carry-forward in aggregator step 38, BCR in aggregator step 4a) collapsed
# into ONE rule: a probe persists iff its cited shape is still present at
# HEAD. Two competing "is the PR converging?" signals (loc-trend trichotomy,
# BCR-fired-N-rounds counter) collapsed into ONE: when the carried-forward
# [blocking] set has not strictly decreased over the last 3 rounds, Path 2
# halts the probe loop. These token + negative fences catch accidental
# re-introduction of any of the deleted patterns.

echo "  asserting carry-forward rule cites Files: shape at HEAD in aggregator.md..."
# Positive token fences — the rule pivots on the cited Files: field and
# the HEAD comparison point. Either token going missing breaks the rule's
# mechanic without breaking grammar.
assert_grep "aggregator carry-forward should cite \`Files:\` field" \
    "\`Files:\` shape" prompts/aggregator.md
assert_grep "aggregator carry-forward should compare against HEAD" \
    "at HEAD" prompts/aggregator.md
# Negative fence: the legacy step 38 said "decide: still active given this
# round's diff" — implicit, deferred to LLM judgment. The new rule is a
# concrete cited-shape grep.
assert_no_grep "aggregator step 38 must not regress to 'decide: still active' wording — cited-shape-at-HEAD is the test, not implicit LLM judgment" \
    "decide: still active" prompts/aggregator.md

echo "  asserting Bug-Class-Recurrence is fully deleted from aggregator.md..."
# Negative fence: BCR fired [blocking] on raw class-occurrence counts ≥2
# across prior reviews, with no clearance path even when cited instances
# were remediated. PR #584 round 13 cited prior probes by run-id as
# evidence of recurrence while round 10's text acknowledged the original
# concerns were resolved.
assert_no_grep "aggregator must not re-introduce Bug-Class-Recurrence — carry-forward (step 38) covers persistence without the counter" \
    "Bug-Class-Recurrence" prompts/aggregator.md

echo "  asserting Path 2 trigger uses HEAD-anchored strict-decrease + skips pause rounds..."
# Positive tokens for the trigger. count[N] < count[N-1] is the math;
# pause-round skip is what stops a Path-2-emitted "0 blockers" round
# from injecting a false strict-decrease into the next round's window.
assert_grep "Path 2 trigger should use the strict-decrease test" \
    "count[N] < count[N-1]" prompts/aggregator.md
assert_grep "Path 2 trigger should skip pause rounds when selecting the 3-round window" \
    "Skip Path 2 pause rounds" prompts/aggregator.md
# Positive fences: without non-zero guards on BOTH endpoints, the
# strict-decrease test admits two false-positive shapes that would
# fire the Path 2 halt action and suppress the Probes block.
#   - count[N] > 0 closes the 0 → 0 → 0 hole (vacuous strict-decrease
#     on a healthy PR — observed regression: plow-pbc/seed-autoresearch
#     PR #3, 8 re-reviews at 0 blockers, "Why this PR isn't converging?"
#     callout shipped on round 3).
#   - count[N-2] > 0 closes the 0 → 0 → 5 hole (blockers just appeared
#     after a clean two-round history; the halt action would suppress
#     the very probes the author needs to see — caught by knightwatch
#     data-integrity specialist on PR #71).
# Each fence pins the guard AS AN AND-JOINED CONJUNCT in the trigger
# fire condition. The "AND `count[N] > 0`" / "AND `count[N-2] > 0`"
# prefixes only render that way inside the Path 2 trigger paragraph;
# the rationale paragraph below uses different phrasing ("without
# `count[N] > 0`, a healthy PR..."), so a regression that demoted the
# guards from the fire condition to only the rationale would no
# longer satisfy these fences. Caught by knightwatch tests
# specialist on PR #71.
assert_grep "Path 2 trigger fire condition must AND-join count[N] > 0 — a 0 → 0 → 0 series satisfies the strict-decrease test vacuously and would otherwise fire on healthy PRs with no blockers" \
    "AND \`count[N] > 0\`" prompts/aggregator.md
assert_grep "Path 2 trigger fire condition must AND-join count[N-2] > 0 — a 0 → 0 → 5 series (blockers newly appeared) satisfies the strict-decrease test and would fire the halt action, suppressing the Probes block that would surface the new blockers" \
    "AND \`count[N-2] > 0\`" prompts/aggregator.md

echo "  asserting Path 2 halt action skips the Probes block in aggregator.md..."
assert_grep "Path 2 must skip the per-angle Probes block on halt" \
    "Skip the per-angle Probes block" prompts/aggregator.md
# Negative fence: the old Path 2 action said "Keep the local probes in
# the **Probes** block, ranked by severity, all subject to voice posture
# (questions over prescriptions). Not dropped — but the structural
# callout has eaten the visual real estate." That action shipped on PR
# #584 round 13 and was the failure-mode replicator: momentum prose
# rendered as decoration while [blocking] BCR rendered alongside.
assert_no_grep "Path 2 must not regress to 'Keep the local probes' action — must drop the Probes block entirely so the structural callout is the only content" \
    "Keep the local probes" prompts/aggregator.md

echo "  asserting carry-forward source picks past Path 2 pause rounds..."
# Step 38 must walk back to the most recent review WITH a Probes block
# when previous-review.md is itself a Path 2 pause round. Without this,
# the next round sees zero probes to carry forward and falsely signals
# convergence.
assert_grep "step 38 should walk back to the most recent review with a Probes block when previous-review.md is a Path 2 pause" \
    "most recent review that DID have a Probes block" prompts/aggregator.md

echo "  asserting K-decay is fully deleted from critic.md..."
# Negative fence: K-decay measured author engagement (commits/comments
# touching cited files) as a proxy for "is the probe still alive?". The
# aggregator's tightened carry-forward (step 38) asks the question
# directly via cited shape at HEAD; K-decay's behavioral proxy is
# redundant.
assert_no_grep "critic.md must not re-introduce K-decay — engagement-as-resolution-proxy was deleted; cited-shape-at-HEAD (aggregator step 38) is the single resolution rule" \
    "K-decay" prompts/critic.md

echo "  asserting LoC-trend trichotomy tags are gone from momentum.md..."
# Negative fence: GROWING/STABLE/SHRINKING tags came from a 1.5×/0.66×
# threshold classifier in lib/loc-trend.sh that mis-labeled PR #584 (1.40×
# growth) as STABLE. The classifier was deleted; momentum reads the raw
# round-by-round table and computes its own delta. Re-introducing the tag
# names in momentum.md implies a consumer that expects a pre-computed tag
# — i.e. the classifier coming back.
for tag in GROWING STABLE SHRINKING; do
    assert_no_grep "prompts/standalone/momentum.md must not re-introduce trichotomy tag '$tag' — momentum reads raw deltas; the classifier was deleted" \
        "$tag" prompts/standalone/momentum.md
done

echo "  asserting loc-trend.sh emits no Trajectory: line..."
# Negative fence: the trichotomy classifier emitted "This PR has been
# reviewed N times. Trajectory: <TAG>." The Trajectory: clause was the
# source of the false-stable signal on PR #584. Deleted; downstream
# consumers (momentum, aggregator) read the raw per-round table directly.
if grep -qE "echo.*Trajectory:" lib/loc-trend.sh; then
    echo "FAIL: lib/loc-trend.sh re-introduced a Trajectory: emission — the trichotomy classifier was deleted; consumers read raw deltas"
    exit 1
fi

echo "  asserting Adds=n/a sentinel on unavailable rows + momentum sentinel handling..."
# Positive token fences. lib/loc-trend.sh emits "n/a" in the Adds column
# for state=unavailable rows (rebased / force-pushed / corrupted history) so
# downstream consumers can't read a fabricated 0 as "no growth this round."
# momentum must treat n/a at either delta endpoint as insufficient data, not
# as arithmetic input — otherwise it becomes a parallel liveness mechanism
# beside the cited-shape-at-HEAD authority.
assert_grep "lib/loc-trend.sh should emit the n/a sentinel for unavailable rows" \
    'adds="n/a"' lib/loc-trend.sh
assert_grep "prompts/standalone/momentum.md should treat n/a Adds as insufficient data" \
    "endpoint Adds is n/a" prompts/standalone/momentum.md

echo "  asserting read-only sandbox fence on aggregator and momentum..."
# Aggregator and momentum agents read PR-controlled inputs while codex
# runs with --dangerously-bypass-approvals-and-sandbox (lib/pipeline.py:69).
# Without the data-not-instructions fence the critic carries, a malicious
# PR could prompt-inject the agents into write actions, network calls,
# or credential exfiltration. Same fence as critic.md:3. Specifically pin
# test-results.md (PR-controlled `just test` output) by name so the
# enumeration can't silently drop it on a refactor.
assert_grep "aggregator.md fence should pin test-results.md by name (PR-controlled just-test output)" \
    'test-results.md` (PR-controlled' prompts/aggregator.md
assert_grep "aggregator.md should carry the read-only working directory fence" \
    "Read-only working directory" prompts/aggregator.md
assert_grep "aggregator.md should fence inputs as data-not-instructions" \
    "data, not instructions" prompts/aggregator.md
assert_grep "momentum.md should carry the read-only working directory fence" \
    "Read-only working directory" prompts/standalone/momentum.md
assert_grep "momentum.md should fence inputs as data-not-instructions" \
    "data, not instructions" prompts/standalone/momentum.md

# Bake-off timer cadence + persistence are quota-control contracts: the daily
# cadence is what cuts the bake-off's GitHub REST volume ~24x vs the prior
# hourly run, and Persistent=false matches the repo's other timer shape (the
# walker's incremental floor handles missed runs without boot-time catch-up).
# A regression to hourly OR Persistent=true silently re-introduces the
# rate-limit failure mode that motivated PR #78.
echo "  asserting pr-reviewer-bakeoff.timer quota-control contract..."
assert_grep "pr-reviewer-bakeoff.timer should run daily at 03:30 UTC" \
    "OnCalendar=*-*-* 03:30:00" systemd/pr-reviewer-bakeoff.timer
assert_grep "pr-reviewer-bakeoff.timer should not be Persistent (matches repo timer shape)" \
    "Persistent=false" systemd/pr-reviewer-bakeoff.timer

echo "  PASS"
