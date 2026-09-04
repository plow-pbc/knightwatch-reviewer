#!/usr/bin/env bash
# Smoke for lib/prior-art-grep.sh: identifier extraction + sibling grep + caps.
# The smoke is the contract; the extraction regex is a heuristic behind it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP=$(mktemp -d -t prior-art-grep-XXXXXX); trap 'rm -rf "$TMP"' EXIT
. "$PROJECT_ROOT/lib/prior-art-grep.sh"

WORK="$TMP/work"; mkdir -p "$WORK/.siblings/acme/libx/src" "$WORK/.siblings/acme/self/src"
cat > "$WORK/.siblings/acme/libx/src/retry.py" <<'EOF'
def retry_with_backoff(fn, attempts=3):
    pass
result = fetch_widgets(limit=10)
EOF
printf 'def retry_with_backoff(): pass\n' > "$WORK/.siblings/acme/self/src/dup.py"   # self must be excluded
printf 'class Client:\n    def retry_with_backoff(self):\n        pass\n' > "$WORK/.siblings/acme/libx/src/nested.py"   # indented hit
mkdir -p "$WORK/.siblings/acme/libx/.git"; printf 'retry_with_backoff\n' > "$WORK/.siblings/acme/libx/.git/junk"

DIFF=$(cat <<'EOF'
diff --git a/app/util.py b/app/util.py
--- a/app/util.py
+++ b/app/util.py
@@ -1,4 +1,6 @@
-def fetch_widgets(limit):
+def fetch_widgets(limit, offset=0):
+def retry_with_backoff(fn, attempts=3):
+    return fn()
+MAX_WIDGETS = 10
EOF
)
out=$(sibling_prior_art "$DIFF" "$WORK" "acme/self")

echo "  1: new definition finds sibling prior art, cited without .siblings prefix..."
printf '%s\n' "$out" | grep -q '^## Sibling prior art — new symbols$' || { echo "FAIL: header"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -q '^### retry_with_backoff$' || { echo "FAIL: symbol"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -q '^- acme/libx/src/retry.py:1: def retry_with_backoff' || { echo "FAIL: citation"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -q '\.siblings/' && { echo "FAIL: leaked .siblings prefix"; exit 1; }
# Indented matches (methods, nested defs — most real code) cite path:line then the trimmed text, once.
printf '%s\n' "$out" | grep -qx -- '- acme/libx/src/nested.py:2: def retry_with_backoff(self):' || { echo "FAIL: indented citation"; printf '%s\n' "$out"; exit 1; }

echo "  2: changed definition finds sibling references..."
printf '%s\n' "$out" | grep -q '^## Sibling references — changed/removed symbols$' || { echo "FAIL: refs header"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -A2 '^### fetch_widgets$' | grep -q 'acme/libx/src/retry.py:3' || { echo "FAIL: caller"; printf '%s\n' "$out"; exit 1; }

echo "  3: own repo and .git are excluded..."
printf '%s\n' "$out" | grep -q 'acme/self/' && { echo "FAIL: self included"; exit 1; }
printf '%s\n' "$out" | grep -q '\.git/junk' && { echo "FAIL: .git searched"; exit 1; }

echo "  4: constants count, short names don't, no hits → empty output..."
printf '%s\n' "$out" | grep -q '^### MAX_WIDGETS$' && { echo "FAIL: MAX_WIDGETS has no sibling hit, must not be listed"; exit 1; }
[ -z "$(sibling_prior_art "$(printf '+def ab(): pass\n')" "$WORK" "acme/self")" ] || { echo "FAIL: short/no-hit should be empty"; exit 1; }
[ -z "$(sibling_prior_art "$DIFF" "$TMP/no-siblings-here" "acme/self")" ] || { echo "FAIL: no .siblings tree should be empty"; exit 1; }

echo "  5: caps — at most 5 hits per symbol..."
for i in $(seq 1 9); do printf 'x = retry_with_backoff()\n' > "$WORK/.siblings/acme/libx/src/c$i.py"; done
n=$(sibling_prior_art "$DIFF" "$WORK" "acme/self" \
    | awk '/^### retry_with_backoff$/ { f=1; next } /^#/ { f=0 } f && /^- / { n++ } END { print n+0 }')
[ "$n" -eq 5 ] || { echo "FAIL: $n hits, cap is 5"; exit 1; }

echo "  6: bash name() { declarations count; changed symbols take the budget before new ones..."
printf 'stage_marker() {\n  :\n}\nstage_marker\n' > "$WORK/.siblings/acme/libx/src/lib.sh"
BASH_DIFF=$(printf '+stage_marker() {\n+    :\n+}\n-def fetch_widgets(limit):\n')
out=$(sibling_prior_art "$BASH_DIFF" "$WORK" "acme/self")
printf '%s\n' "$out" | grep -q '^### stage_marker$' || { echo "FAIL: bash function declaration not extracted"; printf '%s\n' "$out"; exit 1; }
refs_pos=$(printf '%s\n' "$out" | grep -n '^## Sibling references' | cut -d: -f1)
new_pos=$(printf '%s\n' "$out" | grep -n '^## Sibling prior art' | cut -d: -f1)
[ "$refs_pos" -lt "$new_pos" ] || { echo "FAIL: changed-symbol references must precede new-symbol prior art (budget order)"; printf '%s\n' "$out"; exit 1; }
echo "  7: a public-repo review cites path:line only — no sibling source text in a public comment..."
out=$(REPO_VISIBILITY=public sibling_prior_art "$DIFF" "$WORK" "acme/self")
printf '%s\n' "$out" | grep -qE '^- acme/libx/src/[^:]+:[0-9]+$' || { echo "FAIL: public review should cite path:line only"; printf '%s\n' "$out"; exit 1; }
printf '%s\n' "$out" | grep -qE '^- [^ ]+:[0-9]+: ' && { echo "FAIL: sibling source text leaked into a public-repo review"; printf '%s\n' "$out"; exit 1; }
echo "  PASS (7 scenarios: new-symbol-prior-art, changed-symbol-references, self-and-.git-excluded, no-hit-empty, per-symbol-cap, bash-decls-and-changed-first, public-review-cites-only)"
