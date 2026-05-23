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

    # macOS /bin/bash is frozen at 3.2 (no associative arrays). The
    # smokes use declare -A in 12 files, so bash 4+ is required. On
    # macOS, `brew install bash` and ensure /opt/homebrew/bin is first
    # in PATH (or use `#!/usr/bin/env bash` shebangs, which we do).
    bash_major=$(bash -c 'echo ${BASH_VERSION%%.*}')
    if [ "$bash_major" -lt 4 ]; then
        echo "FATAL: bash $bash_major detected; smokes require bash 4+." >&2
        echo "On macOS: brew install bash, then ensure /opt/homebrew/bin precedes /bin in PATH." >&2
        exit 1
    fi
    echo "  bash major version: $bash_major"
    echo ""

    echo "=== bash -n (syntax check on tracked .sh files) ==="
    while IFS= read -r f; do
        bash -n "$f" && echo "  ok: $f"
    done < <(git ls-files '*.sh')

    echo ""
    echo "=== python pipeline tests ==="
    python3 -m unittest discover -s lib/tests -p 'test_*.py' -v

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
    echo "=== prompt-contracts smoke (anti-bloat + momentum-wire + elegant-convergence, folded) ==="
    bash lib/tests/prompt-contracts-smoke.sh

    echo ""
    echo "=== loc-trend smoke ==="
    bash lib/tests/loc-trend-smoke.sh

    echo ""
    echo "=== decline-history smoke ==="
    bash lib/tests/decline-history-smoke.sh

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
    echo "=== just-test flock smoke test ==="
    bash lib/tests/just-test-flock-smoke.sh

    echo ""
    echo "=== orchestrator skip smoke test ==="
    bash lib/tests/orchestrator-skip-smoke.sh

    echo ""
    echo "=== review-one-pr SHA-flow smoke test ==="
    bash lib/tests/review-one-pr-sha-flow-smoke.sh

    echo ""
    echo "=== review-one-pr pull/head precheck smoke test ==="
    bash lib/tests/review-one-pr-pull-head-smoke.sh

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
    echo "=== pr-enumerate smoke test ==="
    bash lib/tests/pr-enumerate-smoke.sh

    echo ""
    echo "=== plow-kid-refresh smoke test ==="
    bash lib/tests/plow-kid-refresh-smoke.sh

    echo ""
    echo "=== org-sync smoke test ==="
    bash lib/tests/org-sync-smoke.sh

    echo ""
    echo "=== install smoke test ==="
    bash lib/tests/install-smoke.sh

    echo ""
    echo "=== replay smoke test ==="
    bash lib/tests/replay-smoke.sh

    echo ""
    echo "=== replay-verify smoke test ==="
    bash lib/tests/replay-verify-smoke.sh

    echo ""
    echo "=== replay-batch stdin-isolation smoke test ==="
    bash lib/tests/replay-batch-stdin-isolation-smoke.sh

    echo ""
    echo "=== bakeoff-store unit test ==="
    bash lib/tests/bakeoff-store-unit.sh

    echo ""
    echo "=== bakeoff-parsers unit test ==="
    bash lib/tests/bakeoff-parsers-unit.sh

    echo ""
    echo "=== specialist-bakeoff smoke test ==="
    bash lib/tests/specialist-bakeoff-smoke.sh

    echo ""
    echo "=== specialists-roster smoke test ==="
    bash lib/tests/specialists-roster-smoke.sh

    echo ""
    echo "=== cmd-prefix smoke test ==="
    bash lib/tests/cmd-prefix-smoke.sh

    echo ""
    echo "all checks passed"
