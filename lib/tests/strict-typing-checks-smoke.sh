#!/bin/bash
# Smoke for the deterministic strict-typing checkers under lib/checks/.
# These run inside REPO_DIR (the PR's working tree) and emit the gap
# description on stdout when strict mode isn't enforced, empty when it
# is. The worker (lib/review-one-pr.sh) treats non-empty stdout as a
# guaranteed [nit] in the posted comment — bypassing the LLM entirely —
# so a regression in either checker silently mis-classifies real
# projects, which is exactly the bug class this smoke fences.
#
# Coverage:
#   Python checker:
#     - pyproject.toml [tool.mypy] strict = true                  → no gap
#     - pyproject.toml [tool.pyright] typeCheckingMode="strict"   → no gap
#     - pyproject.toml [tool.basedpyright] typeCheckingMode=...   → no gap
#       (the canonical signal — pyright/basedpyright `strict` is a
#       list of paths, not a boolean; matches plow's api/pyproject.toml)
#     - pyrightconfig.json `"strict": true`                       → no gap
#     - mypy.ini [mypy] strict = True                             → no gap
#     - setup.cfg [mypy] strict = True                            → no gap
#     - setup.cfg `strict = true` outside [mypy] (e.g. [other])   → gap
#       (regression-fences against the line-grep false-positive)
#     - bare pyproject.toml (no strict config)                    → gap
#     - per-flag mypy strictness without strict=true              → gap
#     - empty workdir (no Python at all)                          → gap
#     - symlinked pyproject.toml                                  → gap
#       (refused: fork-trust-boundary leak)
#     - PROJECT_DIR arg points to subdir with strict config       → no gap
#       (plow-style nested project root)
#   TypeScript checker:
#     - tsconfig.json `compilerOptions.strict: true`              → no gap
#     - tsconfig.json `compilerOptions.strict: false`             → gap
#     - tsconfig.json without compilerOptions.strict              → gap
#     - no tsconfig.json                                          → gap
#     - symlinked tsconfig.json                                   → gap
#     - PROJECT_DIR arg points to subdir with strict tsconfig     → no gap

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY_CHECK="$PROJECT_ROOT/lib/checks/python-strict-typing.sh"
TS_CHECK="$PROJECT_ROOT/lib/checks/typescript-strict-typing.sh"

TMPDIR=$(mktemp -d -t strict-typing-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

assert_no_gap() {
    local check="$1" desc="$2"
    shift 2
    local out
    out=$(bash "$check" "$@")
    if [ -n "$out" ]; then
        echo "FAIL: $desc — expected empty (no gap), got: $out"
        exit 1
    fi
}

assert_gap() {
    local check="$1" desc="$2" expected_substring="$3"
    shift 3
    local out
    out=$(bash "$check" "$@")
    if [ -z "$out" ]; then
        echo "FAIL: $desc — expected gap message on stdout, got empty"
        exit 1
    fi
    if ! printf '%s' "$out" | grep -qF "$expected_substring"; then
        echo "FAIL: $desc — expected output to contain '$expected_substring', got: $out"
        exit 1
    fi
}

# ===== Python =====
echo "  Python: pyproject.toml [tool.mypy] strict=true → no gap..."
W="$TMPDIR/py-mypy"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[project]
name = "x"
[tool.mypy]
strict = true
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-mypy")

echo "  Python: pyproject.toml [tool.pyright] typeCheckingMode=\"strict\" → no gap..."
W="$TMPDIR/py-pyright"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.pyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-pyright")

echo "  Python: pyproject.toml [tool.basedpyright] typeCheckingMode=\"strict\" → no gap..."
W="$TMPDIR/py-basedpyright"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.basedpyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-basedpyright")

echo "  Python: pyrightconfig.json {\"strict\": true} → no gap..."
W="$TMPDIR/py-pyrightconfig"; mkdir -p "$W"
echo '{"strict": true}' > "$W/pyrightconfig.json"
(cd "$W" && assert_no_gap "$PY_CHECK" "py-pyrightconfig")

echo "  Python: mypy.ini [mypy] strict=True → no gap..."
W="$TMPDIR/py-mypyini"; mkdir -p "$W"
cat > "$W/mypy.ini" <<'EOF'
[mypy]
strict = True
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-mypyini")

echo "  Python: setup.cfg [mypy] strict=True → no gap..."
W="$TMPDIR/py-setupcfg-mypy"; mkdir -p "$W"
cat > "$W/setup.cfg" <<'EOF'
[mypy]
strict = True
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-setupcfg-mypy")

# Regression-fence on the line-grep false-positive: a `strict = true`
# line outside the [mypy] section (e.g. another tool in setup.cfg) MUST
# NOT count as strict typing. Catches the bug-class the structural INI
# parse fixes.
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

# Regression-fence on the per-flag-strict false-positive: a project that
# sets only individual mypy flags (without `strict = true`) MUST be
# treated as a gap. Catches a future "soften the threshold" change that
# would let `disallow_untyped_defs = true` alone count as strict.
echo "  Python: per-flag mypy strictness without strict=true → gap..."
W="$TMPDIR/py-per-flag"; mkdir -p "$W"
cat > "$W/pyproject.toml" <<'EOF'
[tool.mypy]
disallow_untyped_defs = true
warn_unused_ignores = true
EOF
(cd "$W" && assert_gap "$PY_CHECK" "py-per-flag" "no strict-mode config")

# Symlink-refusal regression-fence. A fork PR could symlink pyproject.toml
# to an arbitrary host file to leak one bit per review (whether the
# target's TOML happens to encode strict mode). Refuse rather than read.
echo "  Python: pyproject.toml symlink → gap (symlink refused)..."
W="$TMPDIR/py-symlink"; mkdir -p "$W"
echo '[tool.mypy]' > "$TMPDIR/py-symlink-target.toml"
echo 'strict = true' >> "$TMPDIR/py-symlink-target.toml"
ln -s "$TMPDIR/py-symlink-target.toml" "$W/pyproject.toml"
(cd "$W" && assert_gap "$PY_CHECK" "py-symlink" "no strict-mode config")

# Project-root arg: plow's strict config lives in api/pyproject.toml,
# not at repo root. Without the arg, repo-root scan misses it; with the
# arg, the helper scopes to api/.
echo "  Python: PROJECT_DIR arg points to subdir with strict config → no gap..."
W="$TMPDIR/py-subdir"; mkdir -p "$W/api"
cat > "$W/api/pyproject.toml" <<'EOF'
[tool.basedpyright]
typeCheckingMode = "strict"
EOF
(cd "$W" && assert_no_gap "$PY_CHECK" "py-subdir-positive" api)
# Sanity: without the arg, the same workdir reports a gap (root has no config).
(cd "$W" && assert_gap "$PY_CHECK" "py-subdir-without-arg" "no strict-mode config")

# ===== TypeScript =====
echo "  TS: tsconfig.json compilerOptions.strict=true → no gap..."
W="$TMPDIR/ts-strict"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": true}}' > "$W/tsconfig.json"
(cd "$W" && assert_no_gap "$TS_CHECK" "ts-strict")

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

echo "  TS: tsconfig.json symlink → gap (symlink refused)..."
W="$TMPDIR/ts-symlink"; mkdir -p "$W"
echo '{"compilerOptions": {"strict": true}}' > "$TMPDIR/ts-symlink-target.json"
ln -s "$TMPDIR/ts-symlink-target.json" "$W/tsconfig.json"
(cd "$W" && assert_gap "$TS_CHECK" "ts-symlink" "tsconfig.json is a symlink")

echo "  TS: PROJECT_DIR arg points to subdir with strict tsconfig → no gap..."
W="$TMPDIR/ts-subdir"; mkdir -p "$W/web"
echo '{"compilerOptions": {"strict": true}}' > "$W/web/tsconfig.json"
(cd "$W" && assert_no_gap "$TS_CHECK" "ts-subdir-positive" web)

echo "  PASS (12 Python + 6 TS scenarios; per-flag-strict + line-grep + symlink + project-dir regression-fences)"
