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

    # Detach the suite's git ops from the machine-global roborev post-commit
    # hook. The smokes build throwaway git repos under /tmp and commit into
    # them as fixtures (the materializer pins `git rev-parse HEAD` and reads
    # `git ls-tree $sha`, so a fixture sibling MUST have a commit). On a box
    # where the seed installed roborev's `core.hooksPath` in ~/.gitconfig,
    # every fixture commit would otherwise fire post-commit and enqueue a
    # review against the live daemon for a /tmp repo that vanishes on exit —
    # polluting ~/.roborev/reviews.db with thousands of orphan repos + failed
    # jobs. Neutralizing global git config for the test process stops the
    # enqueue at the source (--no-verify does NOT skip post-commit).
    export GIT_CONFIG_GLOBAL=/dev/null

    # Same class, different source: detach the suite from the DEPLOYMENT's env.
    # lib/render-compose.sh's x-reviewer-env exports these operator-config paths,
    # and every consumer resolves them as ${VAR:-<sandbox default>} — so with one
    # ambient, a smoke that writes its fixture to the default path silently reads
    # the LIVE file instead and fails pointing at whatever subsystem owns that
    # file, not at the env bleed.
    #
    # Where that actually bites: the HOST/systemd review branch, which runs the
    # PR's gate with `env -u LOG_FILE just … test` and so inherits the operator
    # environment (lib/run-dir.sh), and any manual `docker exec` shell, which
    # gets the full compose env. The CONTAINER review path is NOT a trigger —
    # run_just_test launches the gate under `env -i` with a fixed allowlist
    # (PATH/HOME/DOCKER_HOST/XDG_CACHE_HOME/UV_CACHE_DIR/PIP_CACHE_DIR), so none
    # of these reach it. Do not weaken that allowlist on the strength of this
    # scrub: it is a token-exposure boundary first and a hermeticity one second.
    #
    # Scrubbed HERE, once, rather than per-suite: twelve smokes source the
    # manifest loader and a thirteenth would silently reopen the hole. Kept as a
    # plain list rather than a test-enforced coupling to x-reviewer-env: at one
    # operator and six path-shaped vars, a var added without a scrub entry is
    # cheap to notice and fix when observed. Not scrubbed: DOCKER_HOST
    # (render-compose-smoke needs a live daemon) and STATE_DIR/REPOS_DIR/
    # WORKDIRS_DIR (each smoke exports its own sandboxed value). Per-command
    # overrides in a scenario are unaffected; this only clears the environment.
    unset REPOS_CONF_FILE CONFIG_ENV_FILE REPO_ENV_DIR KWR_CONFIG_DIR LOCAL_STATE_DIR KWR_CLONE_ROOT

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

    # Runs before any commit-heavy smoke: if the GIT_CONFIG_GLOBAL=/dev/null
    # export above were dropped, this fails fast here — before the fixture
    # commits in search-roots/diff-build/sibling-symlinks could enqueue stray
    # live review jobs into ~/.roborev/reviews.db.
    echo ""
    echo "=== git-global-hook isolation smoke test ==="
    bash lib/tests/git-global-hook-isolation-smoke.sh

    echo ""
    echo "=== python pipeline tests ==="
    python3 -m unittest discover -s lib/tests -p 'test_*.py' -v

    echo ""
    echo "=== repos.conf smoke test ==="
    bash lib/tests/repos-conf-smoke.sh

    echo ""
    echo "=== render-compose smoke test ==="
    bash lib/tests/render-compose-smoke.sh

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
    echo "=== gh rate-limit smoke test ==="
    bash lib/tests/gh-rate-limit-smoke.sh

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
    echo "=== conventions smoke test ==="
    bash lib/tests/conventions-smoke.sh

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
    echo "=== pr-comments smoke ==="
    bash lib/tests/pr-comments-smoke.sh

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
    echo "=== container-state-split smoke test ==="
    bash lib/tests/container-state-split-smoke.sh

    echo ""
    echo "=== review-loop smoke test ==="
    bash lib/tests/review-loop-smoke.sh

    echo ""
    echo "=== run-just-test isolation smoke test ==="
    bash lib/tests/run-just-test-isolation-smoke.sh

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
    echo "=== poll-pr-actions smoke test (approve path) ==="
    bash lib/tests/approve-from-replies-smoke.sh

    echo ""
    echo "=== learn-from-replies smoke test ==="
    bash lib/tests/learn-from-replies-smoke.sh

    echo ""
    echo "=== poll-pr-actions smoke test (re-request path) ==="
    bash lib/tests/re-request-poller-smoke.sh

    echo ""
    echo "=== pr-enumerate smoke test ==="
    bash lib/tests/pr-enumerate-smoke.sh

    echo ""
    echo "=== queue smoke test ==="
    bash lib/tests/queue-smoke.sh

    echo ""
    echo "=== queue-distribute smoke test ==="
    bash lib/tests/queue-distribute-smoke.sh

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
    echo "=== replay-staging smoke test ==="
    bash lib/tests/replay-staging-smoke.sh

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
    echo "=== reeval-marker smoke test ==="
    bash lib/tests/reeval-marker-smoke.sh

    echo ""
    echo "all checks passed"

# Render docker-compose.yml from docker/secrets/fleet.conf.
fleet:
    bash lib/render-compose.sh
