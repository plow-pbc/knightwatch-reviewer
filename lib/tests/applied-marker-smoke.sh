#!/usr/bin/env bash
# Smoke: stub `gh` and verify the helper orchestration the
# review-one-pr.sh hook runs produces the expected PATCH payload.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- gh stub: scripted responses keyed by argv ----
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    "api repos/o/r/issues/comments/9001 --jq .body")
        printf '<!-- knightwatch-reviewer:auto-post -->\n1. [blocking] [from: shape] [shape] X. Files: a.sh.\n2. [low] [from: tests] [tests] Y. Files: b.sh.\n'
        ;;
    "api --paginate repos/o/r/commits?sha=branch&since=2026-05-06T10:00:00Z --jq .[].sha")
        printf 'sha1\n'
        ;;
    "api repos/o/r/commits/sha1 --jq .files[].filename")
        printf 'a.sh\n'
        ;;
    "api repos/o/r/issues/comments/9001 --method PATCH --input -")
        # Capture the patched body to a side file for assertion.
        jq -r '.body' > "$STUB_PATCH_OUT"
        ;;
    *)
        echo "STUB: unhandled gh args: $*" >&2; exit 91 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

PATH="$WORK/bin:$PATH"
export STUB_PATCH_OUT="$WORK/patched-body.txt"
: > "$STUB_PATCH_OUT"

# shellcheck disable=SC1090
source "$REPO_ROOT/lib/applied-marker.sh"

# Mirror the hook orchestration:
prior_id=9001
prior_created="2026-05-06T10:00:00Z"
repo="o/r"
branch="branch"

prior_body=$(gh api "repos/$repo/issues/comments/$prior_id" --jq .body)
probes=$(printf '%s' "$prior_body" | extract_probes_from_review)
touched_file="$WORK/touched.txt"
fetch_touched_paths_since "$repo" "$branch" "$prior_created" > "$touched_file"
applied=$(printf '%s\n' "$probes" | compute_applied "$touched_file")
footer=$(printf '%s\n' "$applied" | render_applied_footer)
patch_review_with_applied "$repo" "$prior_id" "$footer"

# Assert the patched body contains the marker with shape:1 (a.sh was
# touched, so shape applied; b.sh was NOT touched, so tests did not).
if ! grep -q '"shape":1' "$STUB_PATCH_OUT"; then
    echo "FAIL smoke: PATCH body missing shape:1 marker" >&2
    cat "$STUB_PATCH_OUT" >&2
    exit 1
fi
if grep -q '"tests"' "$STUB_PATCH_OUT"; then
    echo "FAIL smoke: PATCH body should NOT include tests (b.sh wasn't touched)" >&2
    cat "$STUB_PATCH_OUT" >&2
    exit 1
fi
if ! grep -q 'Applied since this review' "$STUB_PATCH_OUT"; then
    echo "FAIL smoke: PATCH body missing human prose footer" >&2
    exit 1
fi

# Round-trip fence: the writer's output must parse cleanly through the
# bake-off's reader. If a future change (e.g. whitespace, key order)
# breaks the reader's pinned `\}\}` regex, this assertion catches it.
# extract_applied_marker is already in scope via the applied-marker.sh
# source above (P3 review fix moved it next to the marker constants).
got=$(extract_applied_marker < "$STUB_PATCH_OUT" | sort)
want=$'shape\t1'
if [ "$got" != "$want" ]; then
    echo "FAIL smoke: round-trip — extract_applied_marker on PATCH body" >&2
    echo "  got:  <<$got>>" >&2
    echo "  want: <<$want>>" >&2
    exit 1
fi

echo "PASS smoke: applied marker round-trip (touched=a.sh → shape applied, tests not)"
