#!/bin/bash
# Smoke for the deterministic strict-typing checkers under lib/checks/.
# Helpers run inside REPO_DIR (the PR's working tree) and follow the
# tri-state contract dispatched in lib/review-one-pr.sh:
#
#   exit 0 — strict mode enforced.        stdout: empty.
#   exit 1 — real gap.                    stdout: gap text → posted as [nit].
#   exit 2 — checker could not determine. stderr: error details → logged loud, no nit.
#
# The smoke fences each leg because collapsing checker errors into
# "gap" silently publishes wrong review text — see PR #27 round-2 bot
# review.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY_CHECK="$PROJECT_ROOT/lib/checks/python-strict-typing.sh"
TS_CHECK="$PROJECT_ROOT/lib/checks/typescript-strict-typing.sh"

TMPDIR=$(mktemp -d -t strict-typing-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# assert_strict CHECK DESC [ARGS...]
#   Asserts: exit 0, empty stdout.
assert_strict() {
    local check="$1" desc="$2"
    shift 2
    local out rc
    out=$(bash "$check" "$@" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: $desc — expected exit 0 (strict), got rc=$rc; stdout: $out"
        exit 1
    fi
    if [ -n "$out" ]; then
        echo "FAIL: $desc — expected empty stdout (strict), got: $out"
        exit 1
    fi
}

# assert_gap CHECK DESC EXPECTED_SUBSTRING [ARGS...]
#   Asserts: exit 1, stdout contains EXPECTED_SUBSTRING.
assert_gap() {
    local check="$1" desc="$2" expected="$3"
    shift 3
    local out rc
    out=$(bash "$check" "$@" 2>/dev/null) || rc=$?
    rc=${rc:-0}
    if [ "$rc" -ne 1 ]; then
        echo "FAIL: $desc — expected exit 1 (gap), got rc=$rc; stdout: $out"
        exit 1
    fi
    if [ -z "$out" ]; then
        echo "FAIL: $desc — expected gap message on stdout, got empty"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -qF "$expected"; then
        echo "FAIL: $desc — expected stdout to contain '$expected', got: $out"
        exit 1
    fi
}

# assert_checker_error CHECK DESC EXPECTED_STDERR_SUBSTRING [ARGS...]
#   Asserts: exit 2, stderr contains EXPECTED_STDERR_SUBSTRING.
assert_checker_error() {
    local check="$1" desc="$2" expected="$3"
    shift 3
    local stderr_file out rc
    stderr_file=$(mktemp)
    out=$(bash "$check" "$@" 2>"$stderr_file") || rc=$?
    rc=${rc:-0}
    local err
    err=$(cat "$stderr_file")
    rm -f "$stderr_file"
    if [ "$rc" -ne 2 ]; then
        echo "FAIL: $desc — expected exit 2 (checker-error), got rc=$rc; stdout: $out; stderr: $err"
        exit 1
    fi
    if ! printf '%s' "$err" | grep -qF "$expected"; then
        echo "FAIL: $desc — expected stderr to contain '$expected', got: $err"
        exit 1
    fi
}

# ===== Python: strict (exit 0) =====
echo "  Python: pyproject.toml [tool.mypy] strict=true → strict..."
W="$TMPDIR/py-mypy"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
[tool.mypy]
strict = true
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-mypy")

echo "  Python: pyproject.toml [tool.pyright] typeCheckingMode=\"strict\" → strict..."
W="$TMPDIR/py-pyright"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.pyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-pyright")

echo "  Python: pyproject.toml [tool.basedpyright] typeCheckingMode=\"strict\" → strict..."
W="$TMPDIR/py-basedpyright"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.basedpyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-basedpyright")

echo "  Python: pyrightconfig.json typeCheckingMode=\"strict\" → strict..."
W="$TMPDIR/py-pyrightconfig"; mkdir -p "$W"
echo '{"typeCheckingMode": "strict"}' > "$W/pyrightconfig.json"
(cd "$W" && assert_strict "$PY_CHECK" "py-pyrightconfig")

echo "  Python: mypy.ini [mypy] strict=True → strict..."
W="$TMPDIR/py-mypyini"; mkdir -p "$W"
cat > "$W/mypy.ini" <<'EOF'
[mypy]
strict = True
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-mypyini")

echo "  Python: setup.cfg [mypy] strict=True → strict..."
W="$TMPDIR/py-setupcfg-mypy"; mkdir -p "$W"
cat > "$W/setup.cfg" <<'EOF'
[mypy]
strict = True
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-setupcfg-mypy")

# Precedence: when both pyrightconfig.json and pyproject.toml [tool.pyright|basedpyright]
# exist, pyright docs say pyrightconfig.json overrides. Strict-in-json + non-strict-in-toml
# must report strict.
echo "  Python: pyrightconfig.json strict + pyproject [tool.pyright] non-strict → strict (json wins)..."
W="$TMPDIR/py-precedence-json-strict"; mkdir -p "$W"
echo '{"typeCheckingMode": "strict"}' > "$W/pyrightconfig.json"
cat > "$W/pyproject.toml" <<'EOF'
[tool.pyright]
typeCheckingMode = "basic"
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-precedence-json-strict")

# ===== Python: gap (exit 1) =====
echo "  Python: setup.cfg strict=true outside [mypy] → gap (line-grep false-positive defense)..."
W="$TMPDIR/py-setupcfg-other"; mkdir -p "$W"
cat > "$W/setup.cfg" <<'EOF'
[some_other_tool]
strict = true
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-setupcfg-other" "no strict-mode config")

echo "  Python: bare pyproject.toml (no strict config) → gap..."
W="$TMPDIR/py-bare"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-bare" "no strict-mode config")

echo "  Python: empty workdir → gap (no python config to find)..."
W="$TMPDIR/py-empty"; mkdir -p "$W"
(cd "$W" && assert_gap "$PY_CHECK" "py-empty" "no strict-mode config")

# Per-flag-strict regression-fence: a project that sets only individual
# mypy flags (without `strict = true`) MUST be a gap. Catches a future
# "soften the threshold" change that would let `disallow_untyped_defs = true`
# alone count as strict.
echo "  Python: per-flag mypy strictness without strict=true → gap..."
W="$TMPDIR/py-per-flag"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.mypy]
disallow_untyped_defs = true
warn_unused_ignores = true
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-per-flag" "no strict-mode config")

# pyright/basedpyright `strict` field is a list-of-paths, NOT a boolean —
# so `[tool.pyright] strict = true` does not enable project-wide strict
# mode. Must be a gap, not strict. (Old code treated this as strict; the
# fix is part of the schema-fidelity work in this PR.)
echo "  Python: pyproject [tool.pyright] strict=true (boolean — wrong schema) → gap..."
W="$TMPDIR/py-pyright-bool"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.pyright]
strict = true
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-pyright-bool" "no strict-mode config")

# Precedence: pyrightconfig.json non-strict overrides pyproject [tool.pyright]
# strict — must report gap (json wins, json says non-strict).
echo "  Python: pyrightconfig.json non-strict + pyproject [tool.pyright] strict → gap (json overrides)..."
W="$TMPDIR/py-precedence-json-nonstrict"; mkdir -p "$W"
echo '{"typeCheckingMode": "basic"}' > "$W/pyrightconfig.json"
cat > "$W/pyproject.toml" <<'EOF'
[tool.pyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-precedence-json-nonstrict" "no strict-mode config")

# ===== Python: checker-error (exit 2) =====

echo "  Python: PROJECT_DIR does not exist → checker-error..."
W="$TMPDIR/py-baddir"; mkdir -p "$W"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-baddir" "is not a directory" nonexistent_subdir)

echo "  Python: PROJECT_DIR is a symlink → checker-error..."
W="$TMPDIR/py-symlink-dir"; mkdir -p "$W/real_api"
ln -s real_api "$W/api"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-symlink-dir" "is a symlink" api)

echo "  Python: pyproject.toml symlink → checker-error..."
W="$TMPDIR/py-symlink-file"; mkdir -p "$W"
echo '[tool.mypy]' > "$TMPDIR/py-symlink-target.toml"
echo 'strict = true' >> "$TMPDIR/py-symlink-target.toml"
ln -s "$TMPDIR/py-symlink-target.toml" "$W/pyproject.toml"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-symlink-file" "pyproject.toml is a symlink")

echo "  Python: malformed pyproject.toml → checker-error..."
W="$TMPDIR/py-malformed-toml"; mkdir -p "$W"
echo 'this is not [valid toml{' > "$W/pyproject.toml"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-malformed-toml" "pyproject.toml parse error")

echo "  Python: malformed pyrightconfig.json → checker-error..."
W="$TMPDIR/py-malformed-json"; mkdir -p "$W"
echo '{not valid json' > "$W/pyrightconfig.json"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-malformed-json" "pyrightconfig.json parse error")

echo "  Python: malformed mypy.ini → checker-error..."
W="$TMPDIR/py-malformed-ini"; mkdir -p "$W"
printf 'no section header\nstrict = true\n' > "$W/mypy.ini"
(cd "$W" && assert_checker_error "$PY_CHECK" "py-malformed-ini" "mypy.ini parse error")

# Project-root arg: plow's strict config lives in api/pyproject.toml,
# not at repo root. Without the arg, repo-root scan misses it; with the
# arg, the helper scopes to api/.
echo "  Python: PROJECT_DIR arg points to subdir with strict config → strict..."
W="$TMPDIR/py-subdir"; mkdir -p "$W/api"
cat > "$W/api/pyproject.toml" <<'EOF'
[tool.basedpyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_strict "$PY_CHECK" "py-subdir-positive" api)
# Sanity: without the arg, the same workdir reports a gap (root has no config).
(cd "$W" && assert_gap "$PY_CHECK" "py-subdir-without-arg" "no strict-mode config")

# ===== TypeScript: strict (exit 0) =====
echo "  TS: tsconfig.json compilerOptions.strict=true → strict..."
W="$TMPDIR/ts-strict"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": true}}' > "$W/tsconfig.json"
(cd "$W" && assert_strict "$TS_CHECK" "ts-strict")

echo "  TS: PROJECT_DIR arg points to subdir with strict tsconfig → strict..."
W="$TMPDIR/ts-subdir"; mkdir -p "$W/web"
echo '{"compilerOptions": {"strict": true}}' > "$W/web/tsconfig.json"
(cd "$W" && assert_strict "$TS_CHECK" "ts-subdir-positive" web)

# ===== TypeScript: gap (exit 1) =====
echo "  TS: tsconfig.json compilerOptions.strict=false → gap..."
W="$TMPDIR/ts-not-strict"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": false}}' > "$W/tsconfig.json"
(cd "$W" && assert_gap "$TS_CHECK" "ts-not-strict" "compilerOptions.strict is not true")

echo "  TS: tsconfig.json without compilerOptions.strict → gap..."
W="$TMPDIR/ts-missing-key"; mkdir -p "$W"
echo '{"compilerOptions": {"target": "es2022"}}' > "$W/tsconfig.json"
(cd "$W" && assert_gap "$TS_CHECK" "ts-missing-key" "compilerOptions.strict is not true")

echo "  TS: no tsconfig.json → gap..."
W="$TMPDIR/ts-none"; mkdir -p "$W"
(cd "$W" && assert_gap "$TS_CHECK" "ts-none" "tsconfig.json not found")

# ===== TypeScript: checker-error (exit 2) =====

echo "  TS: PROJECT_DIR does not exist → checker-error..."
W="$TMPDIR/ts-baddir"; mkdir -p "$W"
(cd "$W" && assert_checker_error "$TS_CHECK" "ts-baddir" "is not a directory" nonexistent_subdir)

echo "  TS: PROJECT_DIR is a symlink → checker-error..."
W="$TMPDIR/ts-symlink-dir"; mkdir -p "$W/real_web"
ln -s real_web "$W/web"
(cd "$W" && assert_checker_error "$TS_CHECK" "ts-symlink-dir" "is a symlink" web)

echo "  TS: tsconfig.json symlink → checker-error..."
W="$TMPDIR/ts-symlink-file"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": true}}' > "$TMPDIR/ts-symlink-target.json"
ln -s "$TMPDIR/ts-symlink-target.json" "$W/tsconfig.json"
(cd "$W" && assert_checker_error "$TS_CHECK" "ts-symlink-file" "tsconfig.json is a symlink")

echo "  TS: malformed tsconfig.json → checker-error..."
W="$TMPDIR/ts-malformed"; mkdir -p "$W"
echo '{not valid json' > "$W/tsconfig.json"
(cd "$W" && assert_checker_error "$TS_CHECK" "ts-malformed" "malformed JSON")

# ===== Diff-scope gate (TOUCHED_FILES_FILE) =====
# The strict-typing nag is only meaningful when the PR touches typed
# code under PROJECT_DIR. Helpers gate on TOUCHED_FILES_FILE: zero
# extension matches → exit 0 + stderr "scope-skip". This fences the
# package-lock-only / docs-only / CI-config-only PR class (the bug
# from the original report).

# assert_scope_skip CHECK DESC TOUCHED_FILES_CONTENT [ARGS...]
#   Asserts: exit 0, empty stdout, stderr contains "scope-skip".
assert_scope_skip() {
    local check="$1" desc="$2" touched="$3"
    shift 3
    local touched_file stderr_file out rc err
    touched_file=$(mktemp)
    printf '%s' "$touched" > "$touched_file"
    stderr_file=$(mktemp)
    out=$(TOUCHED_FILES_FILE="$touched_file" bash "$check" "$@" 2>"$stderr_file") || rc=$?
    rc=${rc:-0}
    err=$(cat "$stderr_file")
    rm -f "$touched_file" "$stderr_file"
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: $desc — expected exit 0 (scope-skip), got rc=$rc; stdout: $out; stderr: $err"
        exit 1
    fi
    if [ -n "$out" ]; then
        echo "FAIL: $desc — expected empty stdout (scope-skip), got: $out"
        exit 1
    fi
    if ! printf '%s' "$err" | grep -qF "scope-skip"; then
        echo "FAIL: $desc — expected stderr to contain 'scope-skip', got: $err"
        exit 1
    fi
}

# assert_runs_with_scope CHECK DESC EXPECTED_RC TOUCHED_FILES_CONTENT [ARGS...]
#   Asserts: helper progresses past the scope gate (exit code matches the
#   normal config-detection branch), stderr does NOT contain "scope-skip".
assert_runs_with_scope() {
    local check="$1" desc="$2" expected_rc="$3" touched="$4"
    shift 4
    local touched_file stderr_file out rc err
    touched_file=$(mktemp)
    printf '%s' "$touched" > "$touched_file"
    stderr_file=$(mktemp)
    out=$(TOUCHED_FILES_FILE="$touched_file" bash "$check" "$@" 2>"$stderr_file") || rc=$?
    rc=${rc:-0}
    err=$(cat "$stderr_file")
    rm -f "$touched_file" "$stderr_file"
    if [ "$rc" -ne "$expected_rc" ]; then
        echo "FAIL: $desc — expected exit $expected_rc (gate passed), got rc=$rc; stdout: $out; stderr: $err"
        exit 1
    fi
    if printf '%s' "$err" | grep -qF "scope-skip"; then
        echo "FAIL: $desc — unexpected scope-skip stderr (helper should have run): $err"
        exit 1
    fi
}

# Shared workdir for gate scenarios: bare pyproject.toml (no strict
# config) so a gate-passes scenario produces exit 1 (gap), and a
# gate-skips scenario produces exit 0 (scope-skip) — distinguishable.
echo "  Python gate: package-lock-only diff → scope-skip (the original-report bug class)..."
W="$TMPDIR/py-gate"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
(cd "$W" && assert_scope_skip "$PY_CHECK" "py-gate-package-lock" \
    'package-lock.json
README.md
.github/workflows/ci.yml')

echo "  Python gate: diff with .py file → gate passes, helper detects gap..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-py-touches" 1 \
    'README.md
src/foo.py')

echo "  Python gate: diff with .pyi stub → gate passes (stubs count)..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-pyi-touches" 1 \
    'src/foo.pyi')

echo "  Python gate: empty TOUCHED_FILES_FILE → scope-skip (no files = no scope)..."
(cd "$W" && assert_scope_skip "$PY_CHECK" "py-gate-empty" '')

# Subdir gate: PROJECT_DIR=api means only api/**/*.py counts.
# A .py file at the repo root or in another subdir is out of scope.
echo "  Python gate (PROJECT_DIR=api): root .py → scope-skip (outside api/)..."
W="$TMPDIR/py-gate-subdir"; mkdir -p "$W/api"
cat > "$W/api/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
(cd "$W" && assert_scope_skip "$PY_CHECK" "py-gate-subdir-rootfile" \
    'foo.py
scripts/bar.py' \
    api)

echo "  Python gate (PROJECT_DIR=api): api/foo.py → gate passes..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-subdir-match" 1 \
    'api/foo.py' \
    api)

# Config-only diff: a PR that flips strict mode in pyproject.toml /
# mypy.ini / pyrightconfig.json / setup.cfg without touching any *.py
# source must NOT scope-skip — the helper reads exactly those files,
# and silently suppressing the gap note on a real strict-mode
# regression is the round-6 Narrow-Fix class.
echo "  Python gate: config-only diff (pyproject.toml) → gate passes (regression-fence: PR #31 round 6)..."
W="$TMPDIR/py-gate-config"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-pyproject-only" 1 \
    'pyproject.toml')

echo "  Python gate: config-only diff (mypy.ini) → gate passes..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-mypy-ini-only" 1 \
    'mypy.ini')

echo "  Python gate: config-only diff (pyrightconfig.json) → gate passes..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-pyright-only" 1 \
    'pyrightconfig.json')

echo "  Python gate: config-only diff (setup.cfg) → gate passes..."
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-setupcfg-only" 1 \
    'setup.cfg')

# Subdir gate: config-file under PROJECT_DIR matches; same file at
# repo root does NOT (helper reads from PROJECT_DIR only).
echo "  Python gate (PROJECT_DIR=api): api/pyproject.toml → gate passes..."
W="$TMPDIR/py-gate-subdir-config"; mkdir -p "$W/api"
cat > "$W/api/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
(cd "$W" && assert_runs_with_scope "$PY_CHECK" "py-gate-subdir-config" 1 \
    'api/pyproject.toml' \
    api)

echo "  Python gate (PROJECT_DIR=api): root pyproject.toml only → scope-skip (helper reads from api/, not root)..."
(cd "$W" && assert_scope_skip "$PY_CHECK" "py-gate-rootcfg-vs-subdir" \
    'pyproject.toml
README.md' \
    api)

# Manual invocation without TOUCHED_FILES_FILE (smoke + ad-hoc) must
# still run unconditionally — the gate is opt-in by the worker.
echo "  Python gate: TOUCHED_FILES_FILE unset → helper runs unconditionally..."
W="$TMPDIR/py-gate-unset"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
EOF
unset TOUCHED_FILES_FILE
(cd "$W" && assert_gap "$PY_CHECK" "py-gate-unset" "no strict-mode config")

# TS gate — same shape.
echo "  TS gate: package-lock-only diff → scope-skip..."
W="$TMPDIR/ts-gate"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": false}}' > "$W/tsconfig.json"
(cd "$W" && assert_scope_skip "$TS_CHECK" "ts-gate-package-lock" \
    'package-lock.json
README.md')

echo "  TS gate: diff with .ts file → gate passes, helper detects gap..."
(cd "$W" && assert_runs_with_scope "$TS_CHECK" "ts-gate-ts-touches" 1 \
    'src/foo.ts')

echo "  TS gate: diff with .tsx file → gate passes..."
(cd "$W" && assert_runs_with_scope "$TS_CHECK" "ts-gate-tsx-touches" 1 \
    'src/Foo.tsx')

# JS files are NOT in scope — strict typing is TypeScript-specific.
echo "  TS gate: diff with .js file only → scope-skip (JS is out of scope)..."
(cd "$W" && assert_scope_skip "$TS_CHECK" "ts-gate-js-only" \
    'src/legacy.js')

# Subdir gate
echo "  TS gate (PROJECT_DIR=web): root .ts → scope-skip (outside web/)..."
W="$TMPDIR/ts-gate-subdir"; mkdir -p "$W/web"
echo '{"compilerOptions": {"strict": false}}' > "$W/web/tsconfig.json"
(cd "$W" && assert_scope_skip "$TS_CHECK" "ts-gate-subdir-rootfile" \
    'foo.ts' \
    web)

echo "  TS gate (PROJECT_DIR=web): web/foo.ts → gate passes..."
(cd "$W" && assert_runs_with_scope "$TS_CHECK" "ts-gate-subdir-match" 1 \
    'web/foo.ts' \
    web)

# Config-only diff: same regression-fence as Python — a PR flipping
# tsconfig.json's strict flag without touching any *.ts must NOT
# scope-skip.
echo "  TS gate: config-only diff (tsconfig.json) → gate passes (regression-fence: PR #31 round 6)..."
W="$TMPDIR/ts-gate-config"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": false}}' > "$W/tsconfig.json"
(cd "$W" && assert_runs_with_scope "$TS_CHECK" "ts-gate-tsconfig-only" 1 \
    'tsconfig.json')

echo "  TS gate (PROJECT_DIR=web): web/tsconfig.json → gate passes..."
W="$TMPDIR/ts-gate-subdir-config"; mkdir -p "$W/web"
echo '{"compilerOptions": {"strict": false}}' > "$W/web/tsconfig.json"
(cd "$W" && assert_runs_with_scope "$TS_CHECK" "ts-gate-subdir-config" 1 \
    'web/tsconfig.json' \
    web)

echo "  TS gate (PROJECT_DIR=web): root tsconfig.json only → scope-skip (helper reads from web/, not root)..."
(cd "$W" && assert_scope_skip "$TS_CHECK" "ts-gate-rootcfg-vs-subdir" \
    'tsconfig.json
package.json' \
    web)

echo "  PASS (15 Python + 9 TS config scenarios + 22 diff-scope-gate scenarios; tri-state contract + schema-fidelity + symlink-refusal + pyright-precedence + diff-scope-gate + config-only fences)"
