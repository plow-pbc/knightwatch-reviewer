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

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
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
    if grep -qF "attributed \`[from: aggregator]\`" "$prompt"; then
        echo "FAIL: $prompt regressed to the legacy 'attributed [from: aggregator]' default — cross-angle attribution should be the most load-bearing specialist; aggregator-attribution is the fallback for genuinely emergent patterns"
        exit 1
    fi
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
if grep -nF 'gh issue view' lib/review-one-pr.sh; then
    echo "FAIL: lib/review-one-pr.sh calls 'gh issue view' — linked-issue privacy regressed"
    exit 1
fi

echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference loc-trend.md trigger" \
    "loc-trend.md" prompts/aggregator.md
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
    specialist-bakeoff.sh
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

echo "  PASS"
