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

echo "  asserting probe-resolver job description in critic.md..."
assert_grep "critic.md should describe probe resolution job" \
    "probe resolution" prompts/critic.md

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

echo "  asserting go-deep recommendation handlers in aggregator.md..."
assert_grep "aggregator.md should reference SIMPLIFY-WITH-PATTERN go-deep recommendation" \
    "SIMPLIFY-WITH-PATTERN" prompts/aggregator.md

echo "  asserting go-deep prompt exists with 20-LOC threshold reference..."
assert_grep "go-deep.md should fence the 20-LOC remedy threshold reference" \
    "20-LOC remedy threshold" prompts/go-deep.md
assert_grep "go-deep.md should fence the four recommendation tokens" \
    "KEEP | SIMPLIFY-WITH-PATTERN | DROP | REFRAME" prompts/go-deep.md

# Specialist + scratch wiring — every specialist must be referenced by
# the critic + aggregator read lists, and common-header must document
# any per-specialist scratch input. Catches the "added a prompt file
# but forgot to register it" omission class.
echo "  asserting performance specialist registered in critic.md..."
assert_grep "critic.md should reference performance specialist" \
    "specialists/performance.md" prompts/critic.md

echo "  asserting consumers specialist registered in critic.md..."
assert_grep "critic.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/critic.md

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
    echo "  asserting complexity-cost probe class in ${specialist}.md..."
    # Each specialist must register complexity-cost as one of its emitted
    # classes. After the Class-options hoist (probe-schema.md § Class
    # options), specialists list classes inline rather than per-class
    # blocks, so match the bare token instead of the old `Class: ...` form.
    assert_grep "${specialist}.md should list complexity-cost as a probe class" \
        "complexity-cost" "prompts/${specialist}.md"
done

echo "  asserting unified complexity-cost expectation in common-header.md..."
assert_grep "common-header.md should describe complexity-cost probe expectation" \
    "Complexity-cost probe expectation" prompts/common-header.md

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

echo "  asserting legacy finding-format carry-forward bucket in critic.md..."
assert_grep "critic.md should describe Legacy finding-format conversion path" \
    "Legacy finding-format" prompts/critic.md

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

echo "  asserting carry-forward stress-test pass in critic.md..."
assert_grep "critic.md should fence Carry-forward stress-test pass" \
    "Carry-forward stress-test" prompts/critic.md

# Probe-as-unit polarity contracts (R23 F#2, R23 F#6 / R24 F#4):
# - complexity-cost is deletion-oriented per probe-schema.md § Class
#   options; Pre-PMF lens defaults to Answer: yes (delete) at this scale.
# - Carry-forward probes preserve the original specialist's `From: <angle>`
#   attribution in `## Generated probes`; only critic-originated probes
#   use `From: critic`.
echo "  asserting complexity-cost deletion-oriented polarity in critic.md Pre-PMF lens..."
assert_grep "critic.md should mark complexity-cost as deletion-oriented" \
    "deletion-oriented" prompts/critic.md
assert_grep "critic.md should default complexity-cost to Answer: yes (delete) at pre-PMF" \
    "default \`complexity-cost\` probes to \`Answer: yes\` (delete)" prompts/critic.md

echo "  asserting carry-forward attribution preservation in critic.md..."
assert_grep "critic.md Generated probes block should distinguish critic-origin from carry-forward" \
    "carry-forward probes preserve their original \`From: <angle>\` attribution" prompts/critic.md

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

# Carry-forward must route through the specialists/critic.md sink (single
# channel, single render path); union-verdict rule must hold across
# current + carried-forward probes.
echo "  asserting aggregator reads carry-forward via specialists/critic.md sink..."
assert_grep "aggregator.md should reference specialists/critic.md as the carry-forward sink" \
    "specialists/critic.md" prompts/aggregator.md
assert_grep "aggregator.md should fence the union-of-current-and-carried-forward verdict rule" \
    "union of current and carried-forward" prompts/aggregator.md

# ====================================================================
# Section 1.5: systemd-chain shebang security
# ====================================================================
# Security fence: scripts launched directly by systemd ExecStart, or
# exec'd from those scripts, MUST use the absolute `#!/bin/bash`
# shebang — NOT `#!/usr/bin/env bash`. The reviewer service grants
# write access to /home/odio/.local and puts it first in PATH; an
# attacker-placed `~/.local/bin/bash` would be exec'd via env-bash
# resolution. Sourced helpers (lib/orchestrate.sh, lib/critic-splitter.sh,
# lib/run-dir.sh, etc.) have no exec-time shebang lookup, so their
# shebang is documentation only and not fenced here.
echo "  asserting systemd-chain scripts use absolute /bin/bash shebang..."
SYSTEMD_CHAIN_SCRIPTS=(
    review.sh
    learn-from-replies.sh
    approve-from-replies.sh
    plow-kid-refresh.sh
    re-request-poller.sh
    lib/review-one-pr.sh
    lib/run-specialist.sh
)
for script in "${SYSTEMD_CHAIN_SCRIPTS[@]}"; do
    first_line=$(head -1 "$script")
    if [ "$first_line" != "#!/bin/bash" ]; then
        echo "FAIL: $script has shebang '$first_line' — must be '#!/bin/bash' (env-bash on systemd-launched/exec'd scripts is a PATH-attack vector via writable ~/.local/bin)"
        exit 1
    fi
done

# ====================================================================
# Section 2: orchestrator wiring (formerly momentum-wire-smoke.sh)
# ====================================================================

ORCHESTRATE=lib/orchestrate.sh

echo "  asserting momentum.md invocation in orchestrate.sh..."
assert_grep "orchestrate.sh missing momentum.md reference" \
    "momentum.md" "$ORCHESTRATE"

echo "  asserting momentum gate on previous-review.md..."
# Fence the EXACT guard pattern, not the bare substring "previous-review.md"
# (which appears in unrelated write_scratch calls + comments and would PASS
# even if the re-review-only gate around the momentum specialist disappeared).
assert_grep "orchestrate.sh missing momentum gate (\$RUN_DIR/inputs/previous-review.md)" \
    'if [ -s "$RUN_DIR/inputs/previous-review.md" ]' "$ORCHESTRATE"

echo "  asserting momentum is dispatched..."
assert_grep "orchestrate.sh missing dispatch_agent momentum call" \
    'dispatch_agent momentum' "$ORCHESTRATE"

echo "  asserting momentum output symlink to .codex-scratch/momentum.md..."
assert_grep "orchestrate.sh missing symlink from RUN_DIR/agents/momentum/output.md to .codex-scratch/momentum.md" \
    ".codex-scratch/momentum.md" "$ORCHESTRATE"

echo "  asserting orchestrate.sh is sourced from review-one-pr.sh..."
assert_grep "review-one-pr.sh does not source lib/orchestrate.sh" \
    'orchestrate.sh' lib/review-one-pr.sh

echo "  PASS"
