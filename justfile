# Pre-merge gate for knightwatch-reviewer.
#
# Run `just test` before merging any PR. The PR reviewer runs this same
# target automatically on every tracked PR, so "green locally" and "green
# in the reviewer's eyes" mean the same thing.

default: test

# Syntax-check tracked shell scripts + run the state-io concurrency smoke test.
test:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "=== bash -n (syntax check on tracked .sh files) ==="
    while IFS= read -r f; do
        bash -n "$f" && echo "  ok: $f"
    done < <(git ls-files '*.sh')

    echo ""
    echo "=== repos.conf smoke test ==="
    bash lib/tests/repos-conf-smoke.sh

    echo ""
    echo "=== divergent-clock smoke test ==="
    bash lib/tests/divergent-clock-smoke.sh

    echo ""
    echo "=== auth smoke test ==="
    bash lib/tests/auth-smoke.sh

    echo ""
    echo "=== gh-comments smoke test ==="
    bash lib/tests/gh-comments-smoke.sh

    echo ""
    echo "=== search-roots smoke test ==="
    bash lib/tests/search-roots-smoke.sh

    echo ""
    echo "=== diff-build smoke test ==="
    bash lib/tests/diff-build-smoke.sh

    echo ""
    echo "=== knightwatch-config smoke test ==="
    bash lib/tests/knightwatch-config-smoke.sh

    echo ""
    echo "=== sibling-symlinks smoke test ==="
    bash lib/tests/sibling-symlinks-smoke.sh

    echo ""
    echo "=== codex-scratch-redirect smoke test ==="
    bash lib/tests/codex-scratch-redirect-smoke.sh

    echo ""
    echo "=== path-scrub smoke test ==="
    bash lib/tests/path-scrub-smoke.sh

    echo ""
    echo "=== prompt-build smoke test ==="
    bash lib/tests/build-specialist-prompt-smoke.sh

    echo ""
    echo "=== anti-bloat contract smoke test ==="
    bash lib/tests/anti-bloat-contract-smoke.sh

    echo ""
    echo "=== loc-trend smoke ==="
    bash lib/tests/loc-trend-smoke.sh

    echo ""
    echo "=== momentum-wire smoke ==="
    bash lib/tests/momentum-wire-smoke.sh

    echo ""
    echo "=== run-specialist smoke test ==="
    bash lib/tests/run-specialist-smoke.sh

    echo ""
    echo "=== dispatch-agent smoke test ==="
    bash lib/tests/dispatch-agent-smoke.sh

    echo ""
    echo "=== critic-fallback smoke test ==="
    bash lib/tests/critic-fallback-smoke.sh

    echo ""
    echo "=== run-dir smoke test ==="
    bash lib/tests/run-dir-smoke.sh

    echo ""
    echo "=== prior-reviews smoke test ==="
    bash lib/tests/prior-reviews-smoke.sh

    echo ""
    echo "=== finalize-meta smoke test ==="
    bash lib/tests/finalize-meta-smoke.sh

    echo ""
    echo "=== review-header smoke test ==="
    bash lib/tests/review-header-smoke.sh

    echo ""
    echo "=== strict-typing checks smoke test ==="
    bash lib/tests/strict-typing-checks-smoke.sh

    echo ""
    echo "=== orchestrator skip smoke test ==="
    bash lib/tests/orchestrator-skip-smoke.sh

    echo ""
    echo "=== review-one-pr SHA-flow smoke test ==="
    bash lib/tests/review-one-pr-sha-flow-smoke.sh

    echo ""
    echo "=== approve-from-replies smoke test ==="
    bash lib/tests/approve-from-replies-smoke.sh

    echo ""
    echo "=== learn-from-replies smoke test ==="
    bash lib/tests/learn-from-replies-smoke.sh

    echo ""
    echo "=== re-request-poller smoke test ==="
    bash lib/tests/re-request-poller-smoke.sh

    echo ""
    echo "=== plow-kid-refresh smoke test ==="
    bash lib/tests/plow-kid-refresh-smoke.sh

    echo ""
    echo "=== install smoke test ==="
    bash lib/tests/install-smoke.sh

    echo ""
    echo "all checks passed"
