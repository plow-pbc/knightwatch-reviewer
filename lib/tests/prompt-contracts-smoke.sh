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
# Deliberately NOT a content-pinning test. policy.md's Don't-propose list
# itself forbids CI/test fences that calcify the current contract; what we fence here is
# contract integrity (token presence, branch-negative alternative still
# allowed), not literal wording. One carve-out: a short rewording-stable
# fragment of a rule may be pinned to prove the rule itself still exists —
# a `kwr-test-fence:` marker alone goes green over a deleted rule, and an
# unmarked rule has nothing else to anchor on. Aim such a pin at the clause
# that encodes the contract, not at the sentence framing it, and keep it free
# of step ordinals, which renumber on unrelated edits.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

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

# Prompt-composition behavior — including that policy.md reaches every kind
# and never widens the intent pre-pass's envelope — is asserted against the
# ASSEMBLED prompts in lib/tests/test_pipeline.py's TestRealPromptsCompose.
# It lived here as an embedded python3 heredoc for a while, which made two
# owners of one behavior in two languages; the Python suite already composed
# the real prompts/ tree, so that is where it belongs.

# Negative fence: the operating point belongs to the repo's REVIEW.md, staged
# as .codex-scratch/review.md. A prompt that hardcodes the stage silently
# overrides any repo that states a different one — the drift PR #201 left
# behind when it moved the operating point to REVIEW.md without updating the
# layer that acts on it.
echo "  asserting no prompt hardcodes the operating point..."
if grep -rniE "pre-pmf" prompts/; then
    echo "FAIL: a prompt hardcodes the pre-PMF operating point — read it from .codex-scratch/review.md instead"
    exit 1
fi

# Negative fence: the legacy critic opening said "Eight specialists have
# surfaced findings" — that wording predates the probe-as-unit refactor
# and primes the model to emit Findings instead of resolving probes.
echo "  asserting critic.md has no 'have surfaced findings' regression..."
if grep -qF "have surfaced findings" prompts/critic.md; then
    echo "FAIL: critic.md regressed to legacy 'have surfaced findings' wording — probe-as-unit opening was rolled back"
    exit 1
fi

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

echo "  asserting pr-comments input in critic.md..."
assert_grep "critic.md should reference pr-comments.md" \
    "pr-comments.md" prompts/critic.md

echo "  asserting pr-comments input in aggregator.md..."
assert_grep "aggregator.md should reference pr-comments.md" \
    "pr-comments.md" prompts/aggregator.md

echo "  asserting pr-comments input in common-header.md (fed to every specialist)..."
assert_grep "common-header.md should reference pr-comments.md so specialists see replies to their probes" \
    "pr-comments.md" prompts/common-header.md

# Decline arbitration lives in ONE place now (the aggregator). The
# <!-- decline:class=X --> marker channel was deleted (never authored by
# humans; coarse Class-level suppression). These fences pin: (a) no prompt
# or the comment-staging lib references the dead marker channel; (b) the
# critic no longer arbitrates declines; (c) the aggregator carries the
# argue-once / quote-the-operator / re-litigate contract; (d) argue-once is
# anchored on the cited-shape identity (NOT prose) — the load-bearing fence
# that stops a revert to prose-matching, which is what re-opens the #784
# oscillation.
echo "  asserting decline-marker channel is fully deleted..."
for f in prompts/critic.md prompts/aggregator.md prompts/common-header.md lib/pr-comments.sh; do
    if grep -qF 'decline:class' "$f"; then
        echo "FAIL: $f still references the deleted <!-- decline:class=X --> marker channel"
        exit 1
    fi
    if grep -qF 'Operator decline markers' "$f"; then
        echo "FAIL: $f still references the deleted '## Operator decline markers' section"
        exit 1
    fi
done

echo "  asserting critic.md no longer arbitrates declines..."
if grep -qF 'Decline-history channel' prompts/critic.md; then
    echo "FAIL: critic.md still carries a Decline-history channel — decline arbitration moved to the aggregator"
    exit 1
fi

echo "  asserting aggregator carries the decline-arbitration contract..."
assert_grep "aggregator.md should match declines by specific finding, not Class" \
    "specific finding" prompts/aggregator.md
assert_grep "aggregator.md should carry the argue-once-then-defer convergence rule" \
    "Argue once, then defer" prompts/aggregator.md
assert_grep "aggregator.md should carry the deferred-to-operator drop footnote" \
    "deferred to operator after counter-argument" prompts/aggregator.md
assert_grep "aggregator.md must anchor argue-once on the cited-shape identity (not prose) — a revert to prose-matching re-opens the #784 oscillation" \
    "cited-shape identity" prompts/aggregator.md
# That identity is cited Files: shape ALONE — the same key the persistence test
# uses, NOT shape+Class (a conjunction is narrower and would re-open #784 on a
# Class-drifting probe, e.g. the run(_:) add→delete flip). That shape-alone
# invariant lives in the prompt + spec prose and is exercised by the replay
# harness; we deliberately don't add a "+ Class" / "no Class term" wording-pin
# here — it's brittle to benign rephrasing and would contradict this file's
# "NOT a content-pinning test" contract above (lines 23-26).

echo "  asserting layered-file note in aggregator.md..."
assert_grep "aggregator.md should describe layered specialist files" \
    "layered file" prompts/aggregator.md

# Specialist + scratch wiring — every specialist must be referenced by
# the critic + aggregator read lists, and common-header must document
# any per-specialist scratch input. Catches the "added a prompt file
# but forgot to register it" omission class.
#
# Derive the roster contract from lib.pipeline.SPECIALISTS (the single
# source of truth the runtime launches) rather than asserting per-name:
# adding or renaming a specialist then can't pass tests while leaving the
# aggregator's read list stale — the omission class that let this PR ship
# a nine-specialist roster with stale "eight" prose.
echo "  asserting every SPECIALISTS entry is registered in aggregator.md..."
for _spec in $(python3 -c "import sys; sys.path.insert(0,'.'); from lib.pipeline import SPECIALISTS; print('\n'.join(SPECIALISTS))"); do
    assert_grep "aggregator.md should register specialist '$_spec' (derived from lib.pipeline.SPECIALISTS)" \
        "specialists/${_spec}.md" prompts/aggregator.md
done

echo "  asserting common-header documents dead-code.md scratch..."
assert_grep "common-header.md should document dead-code.md" \
    "dead-code.md" prompts/common-header.md

echo "  asserting common-header carries Scope-justification contract..."
assert_grep "common-header.md should mandate Scope-justification probes when added scope exceeds intent" \
    "Scope-justification" prompts/common-header.md

echo "  asserting common-header pins Scope-justification Q polarity (prevents inverted-advice regression)..."
assert_grep "common-header.md must pin cut-positive Q polarity — without it a need-positive Q + 'cut X' edit re-inverts the rendered advice" \
    "cut-positive" prompts/common-header.md

# Cross-file marker: any consumer parsing the rendered Probes section
# by `[from: <specialist>]` depends on aggregator.md owning the token format.
echo "  asserting [from: <specialist>] attribution token in aggregator.md..."
assert_grep "aggregator.md should describe per-line specialist attribution" \
    "[from: <specialist>]" prompts/aggregator.md

# The rendering contract is UNCONDITIONAL — Path 1 (redirect) and Path 2
# (re-eval banner) change the Overview framing, the probe count, and the
# verdict floor, never how a probe renders. Path 1 used to strip the
# `[severity]` / `[from:]` markers, which silently killed the props/critique
# calibration loop (nothing to attribute), contradicted the "For AI authors"
# footer's `[open]` vocabulary, and zeroed the T2 blocker-stall count series
# for a round. Three rules are fenced below, per the header's pin carve-out:
# the two global statements are marker-anchored, so each gets a marker
# assertion plus a token proving the rule under it still exists; Path 1 c is
# unmarked and pinned by token alone.
echo "  asserting unconditional-rendering + verdict-floor contract markers..."
assert_grep "aggregator.md must carry the unconditional-probe-rendering contract marker" \
    "<!-- kwr-test-fence:unconditional-probe-rendering -->" prompts/aggregator.md
assert_grep "the unconditional-rendering statement must survive under its marker" \
    "never change how a probe is rendered" prompts/aggregator.md
assert_grep "aggregator.md must carry the verdict-floor contract marker — without it a born-large redirect carrying 3 \`low\` probes reads APPROVE" \
    "<!-- kwr-test-fence:verdict-floor -->" prompts/aggregator.md
assert_grep "the verdict-floor override must survive under its marker" \
    "regardless of probe severity" prompts/aggregator.md
assert_grep "Path 1 c must route its 3 structural probes through the shared rendering format" \
    "like any other probe" prompts/aggregator.md
# Negative fence stays: the floor belongs to step 9 alone, so a per-path
# restatement is the regression, not a missing pointer.
assert_no_grep "the verdict floor must not be re-stated per-path — step 9 is the single statement" \
    "Verdict stays \`COMMENT\`" prompts/aggregator.md

# Negative fence: the old default ("attributed [from: aggregator]") was
# replaced with specialist attribution as the default for cross-angle
# probes. A regression that re-introduces the legacy default token in
# either source-of-truth file would re-create the bake-off measurement
# bug (cross-angle synthesis credits the orchestrator instead of the
# specialist whose lens caught the pattern).
echo "  asserting legacy [from: aggregator] default token is gone..."
for prompt in prompts/aggregator.md prompts/probe-schema.md; do
    if grep -qF "attributed \`[from: aggregator]\`" "$prompt"; then
        echo "FAIL: $prompt regressed to the legacy 'attributed [from: aggregator]' default — cross-angle attribution should be the most load-bearing specialist; aggregator-attribution is the fallback for genuinely emergent patterns"
        exit 1
    fi
done

for specialist in shape architecture-refined consumers tests security data-integrity; do
    echo "  asserting simplification probe class in ${specialist}.md..."
    # simplification (DRY + dead-code + complexity-cost) is the universal
    # removal-shaped class; most specialists must register it as one of their
    # emitted classes. architecture-refined owns it as a primary catch after
    # the architecture+simplification consolidation. contract-drift is the
    # exception by design — its narrow remit (cross-file contract drift)
    # explicitly bans simplification; see the contract-drift assertions below.
    assert_grep "${specialist}.md should list simplification as a probe class" \
        "simplification" "prompts/specialists/${specialist}.md"
done

# Privacy: linked-issue staging must NOT fetch issue body or title from
# `gh issue view` — they may be private and would leak into the public PR
# comment via author-intent.md → specialists. Keep only owner/repo#num.
# Fixed-string match catches any executable form (regex variants
# missed lowercase assignments + interpolated `$(...)` quoting).
echo "  asserting linked-issue staging does NOT call 'gh issue view'..."
# Checks every staging site: the builder in scratch.sh plus both callers.
# build_author_intent moved out of review-one-pr.sh, so guarding that file
# alone would leave the fence pointing at code that is no longer there.
for f in lib/scratch.sh lib/review-one-pr.sh lib/replay.sh; do
    if grep -nF 'gh issue view' "$f"; then
        echo "FAIL: $f calls 'gh issue view' — linked-issue privacy regressed"
        exit 1
    fi
done

echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference momentum specialist output" \
    "momentum.md" prompts/aggregator.md

# Token fence: the Hypothetical-future-regression decline rule in
# critic.md is what stops the bot from shipping medium-severity probes
# whose failing path is "a future commit could drift X without a red
# test" (Anti-Bloat: companion tests for unreachable scenarios). Pin
# the rule title as a structural token on both surfaces — critic.md
# owns the rule, aggregator.md inherits it via its existing critic.md
# cross-reference. Per this repo's `REVIEW.md` § Review priority, do not
# pin the rule's rationale prose — token-level fences only.
echo "  asserting Hypothetical-future-regression decline rule in critic.md..."
assert_grep "critic.md should carry the Hypothetical-future-regression decline rule" \
    "Hypothetical-future-regression decline" prompts/critic.md
assert_grep "aggregator.md should inherit the decline rule for cross-angle probes" \
    "Hypothetical-future-regression decline" prompts/aggregator.md

# Token fence: common-header.md must carry the Iteration-Q-shape
# trigger — the cut-positive escape hatch for fence concerns that ARE
# iteration-dependent (vs the flat-decline case the Don't-propose
# bullet above handles).
echo "  asserting Iteration-dependent fence Q-shape trigger in common-header.md..."
assert_grep "common-header.md should carry the Iteration-dependent fence Q-shape trigger" \
    "Iteration-dependent fence Q-shape" prompts/common-header.md

# Token fence: tests.md must carry the Anti-Bloat carve-out for hypothetical fences
# distinguishing observed-bug-needs-regression-test (legitimate blocking)
# from hypothetical-future-regression (Anti-Bloat / YAGNI, drop).
echo "  asserting Anti-Bloat carve-out in specialists/tests.md..."
assert_grep "specialists/tests.md should carry the Anti-Bloat carve-out for hypothetical fences" \
    "no bug shipped and no contract changed" prompts/specialists/tests.md

# Token fence: tests.md must carry the LOC-parity posture and the
# extension-first remedy convention; probe-schema.md's tests class
# mirrors the extend-before-new edit convention.
echo "  asserting Test-LOC parity posture in specialists/tests.md..."
assert_grep "specialists/tests.md should carry the Test-LOC parity posture" \
    "Test-LOC posture" prompts/specialists/tests.md
assert_grep "specialists/tests.md parity must measure the full PR diff, not the incremental re-review diff" \
    ".codex-scratch/full-diff.patch" prompts/specialists/tests.md
assert_grep "specialists/tests.md must route rewrite-shaped assertion findings to the tests class" \
    "rewrite-shaped" prompts/specialists/tests.md
echo "  asserting Extension-first remedy convention in specialists/tests.md..."
assert_grep "specialists/tests.md should carry the Extension-first remedy convention" \
    "Extension-first remedies" prompts/specialists/tests.md
echo "  asserting extend-before-new edit convention in probe-schema.md..."
assert_grep "probe-schema.md tests class should carry the extend-before-new edit convention" \
    "existing test or fixture to extend" prompts/probe-schema.md

# Token fence: contract-drift.md must carry the fence-narrower-than-
# prose carve-out — minimum-viable smoke coverage is NOT two-place
# drift even though it's structurally two-place.
echo "  asserting fence-narrower-than-prose carve-out in specialists/contract-drift.md..."
assert_grep "specialists/contract-drift.md should carry the fence-narrower-than-prose carve-out" \
    "minimum-viable coverage, not drift" prompts/specialists/contract-drift.md

# Token fence: aggregator.md must carry the Silence-is-golden
# anti-emission stance — counters the LLM default to surface more
# work to look thorough. Token-level pin only per `REVIEW.md` § Review priority
# (do not pin rationale prose).
echo "  asserting Silence-is-golden anti-emission stance in aggregator.md..."
assert_grep "aggregator.md should carry the Silence-is-golden anti-emission stance" \
    "Silence is golden" prompts/aggregator.md

# Token fence: org-sync auto-clones MUST live under $KWR_CLONE_ROOT
# (defaults to $HOME/services/kwr-repos/), defined as the single
# source of truth in lib/tracked-repos.sh. Hacking/ is the operator's
# dev workspace per CLAUDE.md; co-mingling auto-clones there caused a
# silent collision on PR #84's deploy when a tracked repo's org
# changed. The fences below pin the structural contract — one
# definition site, four derivation sites — so a one-side-only delete
# trips the smoke instead of producing a stale-path render at install
# time.
echo "  asserting KWR_CLONE_ROOT single source of truth..."
assert_grep "lib/tracked-repos.sh should define KWR_CLONE_ROOT" \
    'KWR_CLONE_ROOT=' lib/tracked-repos.sh
assert_grep "org-sync.sh should derive clone dest from KWR_CLONE_ROOT" \
    'dest="$KWR_CLONE_ROOT/$name"' org-sync.sh
assert_grep "install.sh should template @KWR_CLONE_ROOT@ into systemd units" \
    '@KWR_CLONE_ROOT@' install.sh
assert_grep "pr-reviewer-org-sync.service should template ReadWritePaths via @KWR_CLONE_ROOT@" \
    '@KWR_CLONE_ROOT@' systemd/pr-reviewer-org-sync.service
assert_grep 'review-one-pr.sh should invoke knightwatch-kid from $KWR_CLONE_ROOT' \
    '$KWR_CLONE_ROOT/knightwatch-kid/scripts/kid_dry_check.py' lib/review-one-pr.sh

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
    # Missing ReadWritePaths= stays FAIL-LOUD for host units: they run under
    # ProtectHome=read-only and need an explicit write grant, so a dropped
    # ReadWritePaths is a real regression (grep fails → set -e aborts). The lone
    # exception is the boot-managed fleet unit (knightwatch-reviewer.service),
    # which drives the docker socket and isn't ProtectHome-sandboxed, so it
    # legitimately carries no RW grant — exempt ONLY that one from the check.
    if [[ "$(basename "$unit")" == knightwatch-reviewer.service ]]; then
        rw_line=""
    else
        rw_line=$(grep -E '^ReadWritePaths=' "$unit")
    fi
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

# The fleet unit's lifecycle contract is load-bearing and fails silently if
# broken: RemainAfterExit=yes keeps the Type=oneshot unit "active" so ExecStop
# fires on shutdown/restart — drop it and `docker compose stop` never runs, so
# the fleet takes a SIGKILL (exit 137) on every reboot, the exact failure this
# unit was added to fix. Pin all four lines so a regression goes red instead of
# silently shipping a fleet that doesn't stop gracefully.
echo "  asserting knightwatch-reviewer.service lifecycle contract (oneshot + RemainAfterExit + up/stop Execs)..."
assert_grep 'fleet unit must be Type=oneshot' \
    'Type=oneshot' systemd/knightwatch-reviewer.service
assert_grep 'fleet unit must set RemainAfterExit=yes so ExecStop fires on shutdown/restart' \
    'RemainAfterExit=yes' systemd/knightwatch-reviewer.service
assert_grep 'fleet unit must bring the stack up via compose up -d' \
    'ExecStart=/usr/bin/docker compose up -d' systemd/knightwatch-reviewer.service
# One pin covers both halves: the graceful `compose stop` (not SIGKILL) AND the
# CHAINING in front of it. `;` there swallows a FATAL from the render and hands
# compose no file — the bug this line fixes — and the guard substring alone
# matches both forms, so a revert to `;` stayed green.
assert_grep 'fleet unit ExecStop must render docker-compose.yml if absent, then gracefully stop via compose stop ONLY if that render succeeded (self-healing across the migration window; there is no ExecStopPre)' \
    '[ -f docker-compose.yml ] || bash lib/render-compose.sh; } && exec /usr/bin/docker compose stop' systemd/knightwatch-reviewer.service
assert_grep 'fleet unit must render the compose file before up (it is generated, not committed)' \
    'ExecStartPre=/bin/bash lib/render-compose.sh' systemd/knightwatch-reviewer.service
# PartOf was the property misunderstood in review round 1 — `Requires=` alone does
# NOT re-run the unit on a `systemctl restart docker`, so without PartOf the fleet
# strands on a daemon restart. Pin it so a drop goes red, not silently broken.
assert_grep 'fleet unit must set PartOf=docker.service so a docker daemon restart re-runs its lifecycle' \
    'PartOf=docker.service' systemd/knightwatch-reviewer.service

# The learn-service guidance auto-commit is a two-file path contract: the
# script's commit target and the unit's ReadWritePaths grant must name the same
# live repo. A stale path here took the learner down for days — the unit aborted
# at namespace setup on the since-renamed vibe-engineering checkout, before the
# script ran. Pin both to the live code-config path and fence dead repo names so
# the dead-path class can't return without a red test.
echo "  asserting learn-service guidance path contract (script target == unit grant, no dead repo names)..."
assert_grep 'learn-from-replies.sh must commit guidance to $HOME/services/code-config' \
    'CODE_CONFIG_REPO="$HOME/services/code-config"' learn-from-replies.sh
assert_grep 'pr-reviewer-learn.service must grant write access to /home/odio/services/code-config' \
    '/home/odio/services/code-config' systemd/pr-reviewer-learn.service
assert_no_grep 'learn-from-replies.sh must not reference the renamed-away claude-config repo' \
    'services/claude-config' learn-from-replies.sh
assert_no_grep 'pr-reviewer-learn.service must not reference the renamed-away claude-config repo' \
    'services/claude-config' systemd/pr-reviewer-learn.service
assert_no_grep 'learn-from-replies.sh must not reference the renamed-away vibe-engineering repo' \
    'Hacking/vibe-engineering' learn-from-replies.sh
assert_no_grep 'pr-reviewer-learn.service must not reference the renamed-away vibe-engineering repo' \
    'Hacking/vibe-engineering' systemd/pr-reviewer-learn.service

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

# The intent pre-pass's staged-inputs-only fence is asserted against the
# ASSEMBLED prompt in test_pipeline.py's TestRealPromptsCompose, which
# strictly subsumes a source-level grep: standalone/intent is built from
# policy.md + intent.md and nothing else, so any deletion that would trip a
# grep here also trips the composed assertion. Keeping both made two owners
# of one contract — the defect this file's section-1 comment describes.

echo "  asserting the linked-issue privacy contract holds at source AND consumer..."
# Two halves, both load-bearing. Source: stage no clickable URL. Consumer:
# the bare `owner/repo#num` is itself sufficient to run `gh issue view`, so
# dropping the URL does NOT retire the prohibition — every prompt that can
# run tools must still be told never to resolve the reference. intent.md is
# excluded on purpose: its staged-inputs-only fence grants it no tools.
# One builder now stages author-intent.md for BOTH production and replay
# (build_author_intent in lib/scratch.sh), so the source-side fence has a
# single site to guard.
assert_no_grep "scratch.sh must not stage a clickable linked-issue URL" \
    'https://github.com/' lib/scratch.sh
for f in prompts/common-header.md prompts/critic.md prompts/aggregator.md; do
    # Emphasis markers deliberately absent from both the prompt text and the
    # pin: bolding is a pure reword that must not turn the suite red.
    assert_grep "$f should forbid resolving linked-issue references" \
        "Never resolve those references" "$f"
done

echo "  asserting architecture-refined.md anchors on inferred-intent scratch artifact..."
# Cross-file: architecture-refined.md must reference the scratch artifact
# `.codex-scratch/inferred-intent.md` so the inferred-intent staging
# (lib/pipeline.py) and the consuming specialist agree on the path.
assert_grep "architecture-refined.md should anchor on the inferred-intent scratch artifact" \
    ".codex-scratch/inferred-intent.md" prompts/specialists/architecture-refined.md

# ====================================================================
# Section 4: elegant-convergence rule fences (PR #70)
# ====================================================================
# Three competing "is this probe alive?" mechanisms (K-decay in critic,
# carry-forward in aggregator Re-review handling, BCR in aggregator step 4a) collapsed
# into ONE rule: a probe persists iff its cited shape is still present at
# HEAD. Two competing "is the PR converging?" signals (loc-trend trichotomy,
# BCR-fired-N-rounds counter) collapsed into ONE: when the carried-forward
# [blocking] set has not strictly decreased over the last 3 rounds, Path 2
# fires and reframes the Probes block through the stall lens. These token +
# negative fences catch accidental re-introduction of any of the deleted patterns.

echo "  asserting carry-forward rule cites Files: shape at HEAD in aggregator.md..."
# Positive token fences — the rule pivots on the cited Files: field and
# the HEAD comparison point. Either token going missing breaks the rule's
# mechanic without breaking grammar.
assert_grep "aggregator carry-forward should cite \`Files:\` field" \
    "\`Files:\` shape" prompts/aggregator.md
assert_grep "aggregator carry-forward should compare against HEAD" \
    "at HEAD" prompts/aggregator.md
# Negative fence: the legacy Re-review handling rule said "decide: still active given this
# round's diff" — implicit, deferred to LLM judgment. The new rule is a
# concrete cited-shape grep.
assert_no_grep "aggregator Re-review handling must not regress to 'decide: still active' wording — cited-shape-at-HEAD is the test, not implicit LLM judgment" \
    "decide: still active" prompts/aggregator.md

echo "  asserting Bug-Class-Recurrence is fully deleted from aggregator.md..."
# Negative fence: BCR fired [blocking] on raw class-occurrence counts ≥2
# across prior reviews, with no clearance path even when cited instances
# were remediated. PR #584 round 13 cited prior probes by run-id as
# evidence of recurrence while round 10's text acknowledged the original
# concerns were resolved.
assert_no_grep "aggregator must not re-introduce Bug-Class-Recurrence — carry-forward (Re-review handling) covers persistence without the counter" \
    "Bug-Class-Recurrence" prompts/aggregator.md

echo "  asserting Path 2 trigger uses HEAD-anchored strict-decrease + skips pause rounds..."
# Positive tokens for the trigger. count[N] < count[N-1] is the math;
# pause-round skip is what stops a Path-2-emitted "0 blockers" round
# from injecting a false strict-decrease into the next round's window.
assert_grep "Path 2 trigger should use the strict-decrease test" \
    "count[N] < count[N-1]" prompts/aggregator.md
assert_grep "Path 2 trigger should skip pause rounds when selecting the 3-round window" \
    "Skip legacy Path 2 pause rounds" prompts/aggregator.md
# Positive fences: without non-zero guards on BOTH endpoints, the
# strict-decrease test admits two false-positive shapes that would
# fire Path 2 and reframe the Probes block under the stall lens when the PR is actually healthy.
#   - count[N] > 0 closes the 0 → 0 → 0 hole (vacuous strict-decrease
#     on a healthy PR — observed regression: plow-pbc/seed-autoresearch
#     PR #3, 8 re-reviews at 0 blockers, "Why this PR isn't converging?"
#     callout shipped on round 3).
#   - count[N-2] > 0 closes the 0 → 0 → 5 hole (blockers just appeared
#     after a clean two-round history; Path 2 firing would reframe
#     the very probes the author needs to act on under the stall lens,
#     burying fresh blockers behind a "not converging" callout — caught
#     by knightwatch data-integrity specialist on PR #71).
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
assert_grep "Path 2 trigger fire condition must AND-join count[N-2] > 0 — a 0 → 0 → 5 series (blockers newly appeared) satisfies the strict-decrease test and would fire Path 2, reframing the Probes block under the stall lens when blockers just appeared after a clean history" \
    "AND \`count[N-2] > 0\`" prompts/aggregator.md

echo "  asserting Path 2 keeps the Probes block and frames it through the stall lens..."
# When Path 2 fires, the aggregator renders the FULL review (momentum callout
# banner + Overview + Strengths + Probes + Security + Test coverage + For AI
# authors), with the Overview classifying probes as structural-vs-leaf through
# the stall lens. The earlier contract suppressed the Probes block entirely —
# that suppression was reversed because authors got the structural callout but
# lost the leaf info they still needed to actually push fixes. Path 2's prose
# pin is gone under the marker collapse above; the negative fence on the old
# skip wording plus the stall-lens framing tokens stay.
assert_grep "Path 2 item a must keep the shape-lens framing of the rendered Probes block" \
    "through the shape lens" prompts/aggregator.md
# The shape-lens token pins the broad directive but not the Overview's
# specific job: distinguish the ONE structural-ask probe from the leaf-level
# patches. The two tokens below keep that vocabulary in the Path 2 block —
# without them, an aggregator could write a generic stall-lens Overview that
# lists probes without classifying them. Both tokens appear at more than one
# site, so these assert the vocabulary survives somewhere in the block, not
# that the Overview template specifically still carries it.
assert_grep "Path 2 block must keep the structural-ask vocabulary" \
    "structural ask" prompts/aggregator.md
assert_grep "Path 2 block must keep the leaf-level vocabulary" \
    "leaf-level" prompts/aggregator.md
# Negative fence: the prior contract (PR #66 and earlier) said "Skip the
# per-angle Probes block entirely this round." A regression to that wording
# would re-introduce the failure mode this PR is fixing (callout-only review
# leaves authors without the leaf info needed to converge).
assert_no_grep "Path 2 must not regress to 'Skip the per-angle Probes block' wording — the new contract renders the full body under the stall lens" \
    "Skip the per-angle Probes block" prompts/aggregator.md

echo "  asserting carry-forward source picks past Path 2 pause rounds..."
# Re-review handling must walk back to the most recent review WITH a Probes block
# when previous-review.md is itself a Path 2 pause round. Without this,
# the next round sees zero probes to carry forward and falsely signals
# convergence.
assert_grep "Re-review handling should walk back to the most recent review with a Probes block when previous-review.md is a Path 2 pause" \
    "most recent review that DID have a Probes block" prompts/aggregator.md

# momentum defers the fixed-vs-persisted classification to the aggregator by
# naming the owning section. That pointer was stale for two rounds — it named
# a step number the aggregator no longer had — because nothing pinned either
# end. Both ends now assert. The aggregator side pins the heading form, not
# the bare title: the title also appears at five incidental cross-references,
# so a heading-only retitle would otherwise pass green.
echo "  asserting momentum -> aggregator carry-forward ownership pointer..."
assert_grep "momentum.md must name the aggregator section that owns fixed-vs-persisted classification" \
    "Re-review handling" prompts/standalone/momentum.md
assert_grep "aggregator.md must still carry the Re-review handling section heading momentum points at" \
    "**Re-review handling — read this before" prompts/aggregator.md

# --- Re-eval banner: T1 (LOC) trigger + fire-once markers + durable note ---
# The architecture-shape re-eval banner fires on two deterministic triggers
# (T1 LOC-growth, T2 blocker-stall), each once per PR, and leaves a durable
# note (reeval-status.md) every specialist reads. These fences pin the
# cross-file wiring so a rename/drift can't silently sever it.
echo "  asserting reeval-status.md wired into common-header + momentum + aggregator..."
assert_grep "common-header.md should feed reeval-status.md to every specialist" \
    "reeval-status.md" prompts/common-header.md
assert_grep "momentum.md should read reeval-status.md for the live trigger reason" \
    "reeval-status.md" prompts/standalone/momentum.md
assert_grep "aggregator.md should read reeval-status.md to gate the re-eval banner" \
    "reeval-status.md" prompts/aggregator.md

echo "  asserting T1 LOC-growth trigger is referenced by both the producer and the consumer..."
assert_grep "loc-trend.sh should emit the deterministic REEVAL-LOC-TRIGGER flag" \
    "REEVAL-LOC-TRIGGER" lib/loc-trend.sh
assert_grep "aggregator.md should read the REEVAL-LOC-TRIGGER flag for T1" \
    "REEVAL-LOC-TRIGGER" prompts/aggregator.md
assert_grep "review-one-pr.sh should fold the LOC trigger into reeval-status.md" \
    "REEVAL-LOC-TRIGGER" lib/review-one-pr.sh

echo "  asserting T-SIZE born-large trigger is wired producer -> consumer..."
assert_grep "loc-trend.sh should emit the deterministic REEVAL-SIZE-TRIGGER flag" \
    "REEVAL-SIZE-TRIGGER" lib/loc-trend.sh
assert_grep "aggregator.md should read the REEVAL-SIZE-TRIGGER flag for the Path 1 size redirect" \
    "REEVAL-SIZE-TRIGGER" prompts/aggregator.md
assert_grep "review-one-pr.sh should fold REEVAL-SIZE-TRIGGER into reeval-status.md" \
    "REEVAL-SIZE-TRIGGER" lib/review-one-pr.sh

# Fire-once markers MUST be byte-identical between the emitter (aggregator.md
# stamps them into the posted body) and the detector (review-one-pr.sh greps
# them out of prior posted reviews). A drift on either side silently breaks
# fire-once: either the banner re-fires every round, or a stray marker
# suppresses a trigger forever. Same single-source-of-truth philosophy as
# the BOT_AUTO_POST_MARKER fence.
echo "  asserting reeval fire-once markers are consistent across emitter + detector..."
for marker in '<!-- knightwatch-reviewer:reeval-loc -->' '<!-- knightwatch-reviewer:reeval-stall -->'; do
    if ! grep -qF "$marker" prompts/aggregator.md; then
        echo "FAIL: aggregator.md must emit the fire-once marker '$marker' when its trigger fires"
        exit 1
    fi
    if ! grep -qF "$marker" lib/review-one-pr.sh; then
        echo "FAIL: review-one-pr.sh must grep prior reviews for '$marker' to enforce fire-once"
        exit 1
    fi
done

echo "  asserting K-decay is fully deleted from critic.md..."
# Negative fence: K-decay measured author engagement (commits/comments
# touching cited files) as a proxy for "is the probe still alive?". The
# aggregator's tightened carry-forward (Re-review handling) asks the question
# directly via cited shape at HEAD; K-decay's behavioral proxy is
# redundant.
assert_no_grep "critic.md must not re-introduce K-decay — engagement-as-resolution-proxy was deleted; cited-shape-at-HEAD (aggregator Re-review handling) is the single resolution rule" \
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
# Every agent reads PR-controlled inputs while codex runs with
# --dangerously-bypass-approvals-and-sandbox (lib/pipeline.py:69), so the
# data-not-instructions fence has to reach all of them — that reach is
# asserted against the built prompts in section 1. What is pinned here is the
# fence's ENUMERATION: test-results.md (PR-controlled `just test` output) is
# named explicitly so a refactor of the list can't silently drop it.
assert_grep "policy.md fence should pin test-results.md by name (PR-controlled just-test output)" \
    'test-results.md` — PR-controlled' prompts/policy.md

# Bake-off timer cadence + persistence are quota-control contracts: the ~45-repo
# walk is the heaviest single draw on the shared srosro GitHub budget, so it runs
# twice nightly (02:00 + 04:00 PT) with WINDOW_HOURS capping each run's forward
# watermark advance — splitting the day's per-PR fetches into two smaller off-hours
# bursts. WINDOW_HOURS=16 (> 12) gives 2×16=32h/day forward capacity vs 24h/day of
# real time, so a missed off-hours fire's lag burns down (~8h/day slack) rather
# than lagging forever under Persistent=false. Both fires are off-hours (the 19:00
# PT run was dropped for contending with interactive sessions and tripping the
# secondary rate limit). A regression to hourly OR Persistent=true silently
# re-introduces the rate-limit failure mode that motivated PR #78.
echo "  asserting pr-reviewer-bakeoff.timer quota-control contract..."
assert_grep "pr-reviewer-bakeoff.timer should fire twice nightly at 02:00 + 04:00 Pacific" \
    "OnCalendar=*-*-* 02,04:00:00 America/Los_Angeles" systemd/pr-reviewer-bakeoff.timer
assert_grep "pr-reviewer-bakeoff.service should cap each run's forward window with spare catch-up capacity (2x16 > 24h/day)" \
    "Environment=WINDOW_HOURS=16" systemd/pr-reviewer-bakeoff.service
assert_grep "pr-reviewer-bakeoff.service should rewalk a 12h window for edit refresh" \
    "Environment=REWALK_HOURS=12" systemd/pr-reviewer-bakeoff.service
assert_grep "pr-reviewer-bakeoff.timer should not be Persistent (matches repo timer shape)" \
    "Persistent=false" systemd/pr-reviewer-bakeoff.timer

# The live path must DISCLOSE an org-default fallback. Structural fence, because
# the omission it guards was real and silent: for the whole life of this repo the
# live path never emitted the note while replay did, and replay-smoke can't catch
# a regression here — it drives prepend_review_header with hand-built note arrays,
# so deleting the append below leaves every suite green.
echo "  asserting live path appends the no-REVIEW.md note on the org-default branch..."
assert_grep 'review-one-pr.sh should append the fallback note when resolve_review_md returns rc 1' \
    '[ "$REVIEW_MD_RC" = 1 ] && REVIEW_NOTES+=' lib/review-one-pr.sh

# (contract-drift's aggregator registration is now covered by the
# SPECIALISTS-derived roster check above — no per-name assert needed.)

echo "  PASS"
