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
    echo "=== state-io smoke test ==="
    bash lib/tests/state-io-smoke.sh

    echo ""
    echo "=== prompt-build smoke test ==="
    bash lib/tests/build-specialist-prompt-smoke.sh

    echo ""
    echo "=== run-specialist smoke test ==="
    bash lib/tests/run-specialist-smoke.sh

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
    echo "=== orchestrator skip smoke test ==="
    bash lib/tests/orchestrator-skip-smoke.sh

    echo ""
    echo "all checks passed"
