#!/bin/bash
# Smoke for the deterministic strict-typing checkers under lib/checks/.
# These run inside REPO_DIR (the PR's working tree) and emit the gap
# description on stdout when strict mode isn't enforced, empty when it
# is. The worker (lib/review-one-pr.sh) treats non-empty stdout as a
# guaranteed [nit] in the posted comment — bypassing the LLM entirely —
# so a regression in either checker silently mis-classifies real
# projects, which is exactly the bug class this smoke fences.
#
# Helper contract is tri-state:
#   exit 0 — strict mode enforced.
#   exit 1 — gap (stdout = gap text → becomes a [nit]).
#   exit 2 — checker error (stderr = details → worker logs loud, no nit).
#
# The smoke fences each leg of the tri-state because collapsing
# checker errors into "gap" silently publishes wrong review text — see
# PR #27 round-2 bot review.

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

echo "  PASS (15 Python + 9 TS scenarios; tri-state contract + schema-fidelity + symlink-refusal + pyright-precedence regression-fences)"
