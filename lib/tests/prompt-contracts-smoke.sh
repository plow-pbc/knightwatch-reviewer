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
# "clean up"; the K-decay paired tokens, the negative fences, and the
# specialist-registration tokens are all load-bearing and were each
# written in response to a specific regression. See PR #25, PR #38,
# PR #42, PR #45, PR #47 review history if uncertain about a fence.
#
# Deliberately NOT a content-pinning test. Rule 8 (Remedy-cost framing)
# itself forbids tests that calcify prompt prose; what we fence here is
# contract integrity (token presence, branch-negative alternative still
# allowed), not literal wording.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

# ====================================================================
# Section 1: prompt-contract sync (formerly anti-bloat-contract-smoke.sh)
# ====================================================================

echo "  asserting Rule 8 (Remedy-cost framing) in common-header.md..."
assert_grep "Rule 8 missing from prompts/common-header.md" \
    "Remedy-cost framing" prompts/common-header.md

echo "  asserting voice-posture pointer in common-header.md..."
assert_grep "common-header.md should reference Broken-Glass Test" \
    "Broken-Glass Test" prompts/common-header.md
assert_grep "common-header.md should mandate cost-naming" \
    "adds complexity and makes PMF iteration harder" prompts/common-header.md
assert_grep "common-header.md should reference review-priority.md scratch input" \
    "review-priority.md" prompts/common-header.md

echo "  asserting Bug 1+2 prompt contracts in common-header.md + critic.md..."
assert_grep "common-header.md should fence Q-field shape rule" \
    "Q-field shape" prompts/common-header.md
assert_grep "common-header.md should anchor Q-shape rule on additive scale (~20 LOC)" \
    "20 LOC" prompts/common-header.md
assert_grep "common-header.md should fence Broken-Glass-is-pro-simplification rule" \
    "Broken-Glass is pro-simplification" prompts/common-header.md
assert_grep "critic.md should fence security-controls exception in the Pre-PMF lens" \
    "security or data-integrity controls" prompts/critic.md

echo "  asserting probe-resolver job description in critic.md..."
assert_grep "critic.md should describe probe resolution job" \
    "probe resolution" prompts/critic.md

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

echo "  asserting voice-posture pointer in critic.md..."
assert_grep "critic.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/critic.md

echo "  asserting Pre-PMF lens reference in critic.md..."
assert_grep "critic.md should reference loc-trend.md (Pre-PMF lens)" \
    "loc-trend.md" prompts/critic.md

echo "  asserting decline-history input in critic.md..."
assert_grep "critic.md should reference decline-history.md" \
    "decline-history.md" prompts/critic.md

echo "  asserting decline-history input in aggregator.md..."
assert_grep "aggregator.md should reference decline-history.md" \
    "decline-history.md" prompts/aggregator.md

echo "  asserting layered-file note in aggregator.md..."
assert_grep "aggregator.md should describe layered specialist files" \
    "layered specialist files" prompts/aggregator.md

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

# Probe-as-unit shape — the unified Probes section, AI-author callout,
# Q: question template, and per-line specialist attribution are the
# core surface contract.
echo "  asserting Open Questions Q: format in aggregator.md..."
assert_grep "aggregator.md should describe Q: question template" \
    "**Q:" prompts/aggregator.md
echo "  asserting [from: <specialist>] attribution token in aggregator.md..."
assert_grep "aggregator.md should describe per-line specialist attribution" \
    "[from: <specialist>]" prompts/aggregator.md
echo "  asserting unified Probes section in aggregator.md..."
assert_grep "aggregator.md should have **Probes** unified section" \
    "**Probes**" prompts/aggregator.md
echo "  asserting AI-author callout in aggregator.md..."
assert_grep "aggregator.md should have **For AI authors** callout" \
    "**For AI authors**" prompts/aggregator.md
echo "  asserting unified-probes section ordering instructions..."
assert_grep "aggregator.md should fence Answer: yes ordering" \
    "Answer: yes" prompts/aggregator.md

for specialist in shape simplification architecture consumers tests performance security data-integrity; do
    echo "  asserting simplification probe class in ${specialist}.md..."
    # After collapsing DRY + dead-code + complexity-cost → simplification,
    # every specialist must register simplification as one of its emitted
    # classes (it's the universal removal-shaped class).
    assert_grep "${specialist}.md should list simplification as a probe class" \
        "simplification" "prompts/${specialist}.md"
done

# Privacy: linked-issue staging must NOT fetch issue body or title from
# `gh issue view` — they may be private and would leak into the public PR
# comment via author-intent.md → specialists. Keep only owner/repo#num +
# URL. Fixed-string match catches any executable form (regex variants
# missed lowercase assignments + interpolated `$(...)` quoting).
echo "  asserting linked-issue staging does NOT call 'gh issue view'..."
if grep -nF 'gh issue view' lib/review-one-pr.sh; then
    echo "FAIL: lib/review-one-pr.sh calls 'gh issue view' — linked-issue privacy regressed"
    exit 1
fi

echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference loc-trend.md trigger" \
    "loc-trend.md" prompts/aggregator.md
assert_grep "aggregator.md should reference momentum specialist output" \
    "momentum.md" prompts/aggregator.md

# Path 2 trigger — fence the trigger SHAPE (threshold + prior-rounds-only),
# not just file references. Momentum runs before the critic, so this-round
# signals aren't visible to it yet — the trigger must be prior-rounds-only.
echo "  asserting Path 2 trigger phrases in aggregator.md..."
assert_grep "aggregator.md should fence the 1.5× LOC threshold" \
    "1.5×" prompts/aggregator.md
assert_grep "aggregator.md should fence the 2+ prior rounds threshold" \
    "2+ prior rounds" prompts/aggregator.md
assert_grep "aggregator.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/aggregator.md

echo "  asserting aggregator.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/aggregator.md; then
    echo "FAIL: aggregator.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

echo "  asserting Pre-PMF lens (always-on) in critic.md..."
assert_grep "critic.md should fence Pre-PMF lens (always-on)" \
    "Pre-PMF lens (always-on)" prompts/critic.md

# Probe-as-unit polarity contract (R23 F#2): simplification is
# removal-shaped per probe-schema.md § Class options; Pre-PMF lens
# defaults to Answer: yes (apply the removal) at this scale.
echo "  asserting Pre-PMF removal-default for simplification in critic.md..."
assert_grep "critic.md should mark simplification as removal-shaped" \
    "removal-shaped" prompts/critic.md
assert_grep "critic.md should default simplification probes to Answer: yes at pre-PMF" \
    'default to `Answer: yes`' prompts/critic.md

echo "  asserting K-decay thresholds in critic.md..."
# Probe-resolver model: "K ≥ 3 with no engagement and Class ≠ bug" /
# "K ≥ 5 with no engagement and Class ≠ bug" — pair threshold with Class
# guard so the severe-bug carve-out remains keyed on the bug class.
assert_grep "critic.md should fence K >= 3 decay rule with Class guard" \
    "K ≥ 3 with no engagement" prompts/critic.md
assert_grep "critic.md should fence K >= 5 decay rule with Class guard" \
    "K ≥ 5 with no engagement" prompts/critic.md

echo "  asserting severe-bug carve-out in critic.md..."
assert_grep "critic.md should carve severe-bug probes out of decay/Pre-PMF" \
    "Severe-bug carve-out" prompts/critic.md
# Non-security severe-bug token — guards against a regression that
# narrows the carve-out back to security-only by dropping data-loss
# class words from the prompt prose.
assert_grep "critic.md severe-bug carve-out should cover data-loss class" \
    "data loss" prompts/critic.md

# Union-verdict rule must hold across current + carried-forward probes.
# Per-angle critics now write back into each layered specialist file;
# the central specialists/critic.md sink is gone.
echo "  asserting aggregator fences the union-of-current-and-carried-forward verdict rule..."
assert_grep "aggregator.md should fence the union-of-current-and-carried-forward verdict rule" \
    "union of current and carried-forward" prompts/aggregator.md

# ====================================================================
# Section 1.5: systemd-chain shebang security
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
# Environment=PATH ordering + .npm-global precedence). Each fence's
# security rationale is in the per-FAIL message; the section comment
# above this block carries the overarching "why absolute shebang +
# system-PATH-first + .local-not-writable" attack-class context.
echo "  asserting systemd-chain scripts: absolute /bin/bash shebang + no writable-PATH prepend..."
SYSTEMD_CHAIN_SCRIPTS=(
    review.sh
    learn-from-replies.sh
    approve-from-replies.sh
    plow-kid-refresh.sh
    re-request-poller.sh
    lib/review-one-pr.sh
)
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
# /usr/... so writable user dirs trail. .npm-global must precede .local for
# units that run codex; kid-refresh doesn't run codex and is exempt from the
# .npm-global ordering check (still subject to the other two).
echo "  asserting systemd units: ReadWritePaths + Environment=PATH ordering + .npm-global precedence..."
for unit in systemd/*.service; do
    rw_line=$(grep -E '^ReadWritePaths=' "$unit")
    path_line=$(grep -E '^Environment=PATH=' "$unit")

    rhs="${rw_line#ReadWritePaths=}"
    for tok in $rhs; do
        # Strip systemd's optional path-prefix syntax (- = ignore-if-missing,
        # + = mount-namespace-aware) so denylist matching is on the bare path.
        case "${tok#[+-]}" in
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
            *.npm-global/bin*.local/bin*) ;;
            *.local/bin*)
                echo "FAIL: $unit PATH has .local/bin without .npm-global/bin preceding it — PR-controlled just test could plant ~/.local/bin/codex shadowing the real codex install"
                echo "  got: $path_line"
                exit 1 ;;
        esac
    fi
done

# ====================================================================
# Section 2: pipeline.py wiring (formerly orchestrate.sh + momentum-wire)
# ====================================================================

PIPELINE=lib/pipeline.py

echo "  asserting momentum specialist invocation in pipeline.py..."
assert_grep "pipeline.py missing momentum reference" \
    "momentum" "$PIPELINE"

echo "  asserting momentum gate on previous-review.md..."
# Fence the EXACT guard expression, not the bare substring "previous-review.md"
# (which appears in unrelated write_scratch calls + comments and would PASS
# even if the re-review-only gate around the momentum specialist disappeared).
assert_grep "pipeline.py missing momentum gate (prev_review.exists() and size > 0)" \
    'prev_review.exists() and prev_review.stat().st_size > 0' "$PIPELINE"

echo "  asserting momentum is dispatched via run_codex..."
assert_grep "pipeline.py missing run_codex(\"momentum\", ...) call" \
    'run_codex("momentum"' "$PIPELINE"

echo "  asserting momentum output symlink to .codex-scratch/momentum.md..."
assert_grep "pipeline.py missing symlink target .codex-scratch/momentum.md" \
    'momentum.md' "$PIPELINE"

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

# ====================================================================
# Section: subtractive-priority tokens (added 2026-05-04)
# ====================================================================
# Pins the subtractive-by-default tightening in this repo's
# .knightwatch/review-priority.md and the canonical worked example in
# the consumed standards. If these tokens drift away, every specialist
# loses the operating-point signal that drives PR#47-style structural
# loops to surface the substrate-replacement move.

echo "  asserting subtractive-priority tokens in .knightwatch/review-priority.md..."
assert_grep "review-priority.md should name SIMPLIFY at all costs" \
    "SIMPLIFY at all costs" .knightwatch/review-priority.md
assert_grep "review-priority.md should cite cumulative additive LOC" \
    "Cumulative additive LOC" .knightwatch/review-priority.md
assert_grep "review-priority.md should cite the canonical Broken-Glass section" \
    "Broken-Glass Test" .knightwatch/review-priority.md

echo "  asserting simplification.md anchors on inferred-intent for refactor PRs..."
# Specialist-prompt fences: presence + file-path reference (the contract
# surface — wording itself is checked at the row level below, not pinned here).
assert_grep "simplification.md should grade diff against stated intent" \
    "grade the diff against stated intent" prompts/simplification.md
assert_grep "simplification.md should anchor on the inferred-intent scratch artifact" \
    ".codex-scratch/inferred-intent.md" prompts/simplification.md

# Schema-row fence: the simplification class row in probe-schema.md owns the
# severity contract. Verify the row exists AND contains the canonical
# `net-additive refactor` blocking-case token on the same line — drift in
# either direction (row removal or token migration into a different class)
# trips this assertion.
schema_row=$(grep -E '^- \*\*`simplification`\*\*' prompts/probe-schema.md || true)
[[ -n "$schema_row" && "$schema_row" == *"net-additive refactor"* ]] || {
    echo "FAIL: prompts/probe-schema.md simplification row missing or no longer contains 'net-additive refactor' blocking-case token"
    echo "  got: $schema_row"
    exit 1
}

echo "  PASS"
