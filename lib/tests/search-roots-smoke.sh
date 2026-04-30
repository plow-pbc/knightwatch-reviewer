#!/bin/bash
# Smoke for lib/search-roots.sh — fences the coverage-state seam that
# the dead-code-search and consumers prompts read from.
#
# Each scenario stubs `gh api` differently to drive stage_search_roots
# down a distinct path:
#   1. trusted on every sibling, every checkout exists -> full
#   2. trusted on some, untrusted on others -> partial with explicit excluded
#   3. untrusted on every sibling -> same-repo-only with excluded counts
#   4. one sibling missing on disk -> reported as `missing`, not silently dropped
#   5. gh api fails for one sibling -> reported as `lookup-error`, not collapsed into excluded
#
# Each scenario asserts BOTH the coverage header AND the per-sibling
# classification lines. That's the whole point of the seam — both prompts
# rely on the per-sibling status to qualify their verdicts, so a coverage
# header alone (or a stripped-down list) is not enough.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMPDIR=$(mktemp -d -t search-roots-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Provide checkouts for two of three siblings; the third is intentionally absent.
mkdir -p "$TMPDIR/repos/foo" "$TMPDIR/repos/bar"
# (sibling "qux" has no directory — drives the `missing` path.)

REPOS=("acme/self" "acme/foo" "acme/bar" "acme/qux")
declare -A SOURCE_PATHS=(
    ["acme/self"]="$TMPDIR/repos/self"
    ["acme/foo"]="$TMPDIR/repos/foo"
    ["acme/bar"]="$TMPDIR/repos/bar"
    ["acme/qux"]="$TMPDIR/repos/qux"
)

# `gh` stub — table-driven from MOCK_PERMS. Format:
#   MOCK_PERMS="acme/foo:write,acme/bar:read"
# missing key -> empty stdout + non-zero exit (lookup-error).
# Special key prefix `ERR:` forces non-zero exit even when present.
export PATH="$TMPDIR/bin:$PATH"
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/gh" <<'STUB'
#!/bin/bash
# We only support: gh api repos/<repo>/collaborators/<user>/permission --jq .permission
if [ "$1" != "api" ] || [[ "$2" != repos/*/collaborators/*/permission ]]; then
    echo "stub: unexpected gh invocation: $*" >&2; exit 99
fi
endpoint="$2"
repo="${endpoint#repos/}"; repo="${repo%/collaborators/*}"
IFS=',' read -ra entries <<< "${MOCK_PERMS:-}"
for e in "${entries[@]}"; do
    key="${e%%:*}"; val="${e#*:}"
    if [ "$key" = "$repo" ]; then
        if [[ "$val" == ERR:* ]]; then exit 1; fi
        printf '%s\n' "$val"
        exit 0
    fi
done
exit 1
STUB
chmod +x "$TMPDIR/bin/gh"

. "$PROJECT_ROOT/lib/auth.sh"
. "$PROJECT_ROOT/lib/search-roots.sh"

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $label"
        echo "  expected: $(printf '%s' "$expected" | head -c 400)"
        echo "  got:      $(printf '%s' "$actual" | head -c 400)"
        exit 1
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "FAIL: $label"
        echo "  did not find: $needle"
        echo "  in: $(printf '%s' "$haystack" | head -c 400)"
        exit 1
    fi
}

export MOCK_PERMS

# --- scenario 1: trusted on every sibling, all checkouts exist -> full ----------
# (We narrow REPOS for this scenario so all remaining siblings have
# checkouts. Easier than maintaining a 4th checkout dir.)
echo "  scenario 1: full coverage..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
MOCK_PERMS="acme/self:write,acme/foo:write,acme/bar:admin"
OUT=$(stage_search_roots "acme/self" "alice")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 1: header" "# coverage: full" "$OUT"
assert_contains "scenario 1: foo included" "acme/foo included $TMPDIR/repos/foo" "$OUT"
assert_contains "scenario 1: bar included" "acme/bar included $TMPDIR/repos/bar" "$OUT"

# --- scenario 2: partial — one excluded ---------------------------------------
echo "  scenario 2: partial coverage..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
MOCK_PERMS="acme/self:write,acme/foo:write,acme/bar:read"
OUT=$(stage_search_roots "acme/self" "alice")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 2: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 2: included=1" "included=1" "$OUT"
assert_contains "scenario 2: excluded=1" "excluded=1" "$OUT"
assert_contains "scenario 2: foo included" "acme/foo included $TMPDIR/repos/foo" "$OUT"
assert_contains "scenario 2: bar excluded" "acme/bar excluded" "$OUT"

# --- scenario 3: untrusted everywhere -> same-repo-only -----------------------
echo "  scenario 3: same-repo-only via excluded..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
MOCK_PERMS="acme/self:write,acme/foo:read,acme/bar:read"
OUT=$(stage_search_roots "acme/self" "alice")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 3: header same-repo-only" "# coverage: same-repo-only" "$OUT"
assert_contains "scenario 3: excluded=2" "excluded=2" "$OUT"
assert_contains "scenario 3: foo excluded" "acme/foo excluded" "$OUT"
assert_contains "scenario 3: bar excluded" "acme/bar excluded" "$OUT"

# --- scenario 4: missing checkout dir reported, not silently skipped ---------
echo "  scenario 4: missing checkout..."
MOCK_PERMS="acme/self:write,acme/foo:write,acme/bar:write,acme/qux:write"
OUT=$(stage_search_roots "acme/self" "alice")
assert_contains "scenario 4: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 4: missing=1" "missing=1" "$OUT"
assert_contains "scenario 4: qux missing" "acme/qux missing" "$OUT"
# qux must NOT be listed as included (the previous bug).
if printf '%s' "$OUT" | grep -q "acme/qux included"; then
    echo "FAIL: scenario 4: qux must not be included when its checkout is absent"
    exit 1
fi

# --- scenario 5: lookup-error distinct from excluded --------------------------
echo "  scenario 5: lookup-error..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
# foo trusted; bar's gh call exits non-zero (network/rate-limit simulated).
MOCK_PERMS="acme/self:write,acme/foo:write,acme/bar:ERR:network"
OUT=$(stage_search_roots "acme/self" "alice")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 5: header partial" "# coverage: partial" "$OUT"
assert_contains "scenario 5: lookup-error=1" "lookup-error=1" "$OUT"
assert_contains "scenario 5: bar lookup-error" "acme/bar lookup-error" "$OUT"
# A lookup-error sibling must NOT be tagged as excluded — that's the
# whole point of the seam (collapsing those was the bug we just fixed).
if printf '%s' "$OUT" | grep -q "acme/bar excluded"; then
    echo "FAIL: scenario 5: lookup-error must not be reported as excluded"
    exit 1
fi

# --- scenario 6: outer trust gate — untrusted on $REPO short-circuits ---------
# Even when the author has push on every sibling, an untrusted-on-$REPO
# author must NOT see any sibling listed as `included` — because the
# review comment lands on $REPO's PR (publicly readable) and would
# expose sibling data to every $REPO reader. This is the regression
# class the bot caught in round 4: dropping the outer gate during the
# stage_search_roots extraction. Lock it down here.
echo "  scenario 6: outer trust gate (untrusted on \$REPO)..."
saved_repos=("${REPOS[@]}")
REPOS=("acme/self" "acme/foo" "acme/bar")
# Author has push on EVERY sibling, but READ on $REPO itself.
MOCK_PERMS="acme/self:read,acme/foo:write,acme/bar:admin"
OUT=$(stage_search_roots "acme/self" "alice")
REPOS=("${saved_repos[@]}")
assert_contains "scenario 6: header same-repo-only" "# coverage: same-repo-only" "$OUT"
assert_contains "scenario 6: cites untrusted on \$REPO" "author untrusted on acme/self" "$OUT"
# Critically: NO sibling line at all — not even excluded entries —
# because the outer gate short-circuits before per-sibling classification.
if printf '%s' "$OUT" | grep -qE "(included|excluded|missing|lookup-error)"; then
    echo "FAIL: scenario 6: untrusted-on-\$REPO must short-circuit; got per-sibling lines"
    echo "  output: $OUT"
    exit 1
fi

echo "  PASS (6 scenarios: full, partial-excluded, same-repo-only, missing-checkout, lookup-error, outer-gate-short-circuit)"
