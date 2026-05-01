#!/bin/bash
# Smoke for lib/diff-build.sh.
#
# Covers two helpers:
#
# 1. is_clean_incremental_available: returns success (exit 0) iff
#    (a) prior reviewed SHA is still an ancestor of HEAD (no force-push
#        evicted it), AND
#    (b) no merge commits exist in known_sha..HEAD (no merge-from-main
#        between then and now to pollute attribution).
#    Any other condition → exit 1, caller falls back to full PR diff
#    with a deterministic warning at the top of the review.
#
# 2. extract_touched_files_both_sides: emits sorted-unique paths from
#    every `diff --git a/X b/Y` header in a unified diff. Captures BOTH
#    sides — additions, deletions, and renames (including
#    similarity-100% pure renames where +++/--- headers are absent).
#    Used by the worker's strict-typing scope gate; covers the
#    Narrow-Fix flagged in PR #31 round 1 where post-image-only parse
#    silently skipped delete/rename PRs of typed files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TMPDIR=$(mktemp -d -t diff-build-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

. "$SCRIPT_DIR/diff-build.sh"

REPO="$TMPDIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

echo a > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -qm init

git -C "$REPO" remote add origin "$REPO/.git"
git -C "$REPO" fetch -q origin main

git -C "$REPO" checkout -qb feature
echo f > "$REPO/feature.txt"
git -C "$REPO" add feature.txt
git -C "$REPO" commit -qm "B1"
PRIOR=$(git -C "$REPO" rev-parse HEAD)

# --- scenario 1: SHA is ancestor, no merges in range -----------------
echo "  scenario 1: clean incremental (ancestor + no merges)..."
echo f2 > "$REPO/feature2.txt"
git -C "$REPO" add feature2.txt
git -C "$REPO" commit -qm "B2"
if ! is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 1: should be clean (PRIOR is ancestor, no merges in range)"
    exit 1
fi

# --- scenario 2: SHA is ancestor, merge commit in range --------------
echo "  scenario 2: merge commit in range -> not clean..."
git -C "$REPO" checkout -q main
echo m > "$REPO/main-only.txt"
git -C "$REPO" add main-only.txt
git -C "$REPO" commit -qm "M1"
git -C "$REPO" fetch -q origin main
git -C "$REPO" checkout -q feature
git -C "$REPO" merge --no-ff -q -m "merge main" origin/main
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 2: merge commit in range should fail clean check"
    exit 1
fi

# --- scenario 3: rebased-away SHA (not ancestor of HEAD) -------------
# Capture HEAD and reset to a SHA before PRIOR; then PRIOR's branch
# point is no longer an ancestor of (the new) HEAD. Use checkout -B
# to a fresh-rooted history to simulate a force-push.
echo "  scenario 3: rebased-away SHA -> not clean..."
git -C "$REPO" checkout -q main
git -C "$REPO" checkout -qB feature main
echo orphaned > "$REPO/orphaned.txt"
git -C "$REPO" add orphaned.txt
git -C "$REPO" commit -qm "post-rebase HEAD"
if is_clean_incremental_available "$REPO" "$PRIOR"; then
    echo "FAIL scenario 3: orphaned SHA should fail clean check (PRIOR not ancestor of new HEAD)"
    exit 1
fi

# --- scenario 4: SHA doesn't exist at all ----------------------------
echo "  scenario 4: nonexistent SHA -> not clean..."
if is_clean_incremental_available "$REPO" "0000000000000000000000000000000000000000"; then
    echo "FAIL scenario 4: nonexistent SHA should fail clean check"
    exit 1
fi

# =====================================================================
# extract_touched_files_both_sides — diff-text parser
# =====================================================================

# assert_extract DESC EXPECTED_LINES DIFF_TEXT
#   EXPECTED_LINES: newline-separated, sorted, what the helper should output
#   DIFF_TEXT: the unified-diff input
assert_extract() {
    local desc="$1" expected="$2" diff_text="$3"
    local got
    got=$(printf '%s' "$diff_text" | extract_touched_files_both_sides)
    if [ "$got" != "$expected" ]; then
        echo "FAIL: $desc"
        echo "  expected:"
        printf '    %s\n' $expected
        echo "  got:"
        printf '    %s\n' $got
        exit 1
    fi
}

echo "  extract: addition → post-image only (one diff --git, /dev/null in --- )..."
assert_extract "addition" "foo.py" \
'diff --git a/foo.py b/foo.py
new file mode 100644
index 0000000..abc1234
--- /dev/null
+++ b/foo.py
@@ -0,0 +1,3 @@
+x = 1
+y = 2
+z = 3
'

# Delete: post-image is /dev/null, but `diff --git a/foo.py b/foo.py`
# still lists foo.py on both sides. Helper must emit foo.py — the
# Narrow-Fix that prompted this helper.
echo "  extract: deletion → captures the deleted typed file (regression-fence: PR #31 round 1)..."
assert_extract "deletion" "foo.py" \
'diff --git a/foo.py b/foo.py
deleted file mode 100644
index abc1234..0000000
--- a/foo.py
+++ /dev/null
@@ -1,3 +0,0 @@
-x = 1
-y = 2
-z = 3
'

# Rename with content change: similarity < 100, has both --- a/ and +++ b/.
echo "  extract: rename with content change → both sides..."
assert_extract "rename-with-content" "$(printf 'new.js\nold.ts')" \
'diff --git a/old.ts b/new.js
similarity index 80%
rename from old.ts
rename to new.js
index abc1234..def5678
--- a/old.ts
+++ b/new.js
@@ -1,3 +1,3 @@
-let x = 1;
+const x = 1;
'

# Pure rename, similarity 100: NO --- a/ or +++ b/ lines at all. Helper
# must still emit both paths from the diff --git line — this is the
# rename case the post-image-only parse missed entirely.
echo "  extract: similarity-100% pure rename → both sides (no +++/--- in input)..."
assert_extract "rename-pure" "$(printf 'new.js\nold.ts')" \
'diff --git a/old.ts b/new.js
similarity index 100%
rename from old.ts
rename to new.js
'

echo "  extract: modification → one path (a and b are the same file)..."
assert_extract "modification" "foo.py" \
'diff --git a/foo.py b/foo.py
index abc1234..def5678 100644
--- a/foo.py
+++ b/foo.py
@@ -1,3 +1,3 @@
 x = 1
-y = 2
+y = 99
 z = 3
'

echo "  extract: multiple files in one diff → sorted-unique union..."
assert_extract "multi-file" "$(printf 'README.md\npackage-lock.json\nsrc/a.py\nsrc/b.py')" \
'diff --git a/src/a.py b/src/a.py
index abc..def 100644
--- a/src/a.py
+++ b/src/a.py
@@ -1 +1 @@
-1
+2
diff --git a/src/b.py b/src/b.py
index abc..def 100644
--- a/src/b.py
+++ b/src/b.py
@@ -1 +1 @@
-3
+4
diff --git a/README.md b/README.md
index abc..def 100644
--- a/README.md
+++ b/README.md
@@ -1 +1 @@
-old
+new
diff --git a/package-lock.json b/package-lock.json
index abc..def 100644
--- a/package-lock.json
+++ b/package-lock.json
@@ -1 +1 @@
-old
+new
'

echo "  extract: empty diff → empty output (no crash)..."
assert_extract "empty" "" ""

# Negative: dedup. Same file appears in `diff --git` once but body
# also has +++/---; only the diff --git fields are read so no dups.
echo "  extract: same file once in diff --git → emitted exactly once (no dup from +++/--- body)..."
assert_extract "no-dup" "foo.py" \
'diff --git a/foo.py b/foo.py
index abc..def 100644
--- a/foo.py
+++ b/foo.py
@@ -1,3 +1,3 @@
 x = 1
-y = 2
+y = 3
 z = 3
'

# =====================================================================
# classify_gh_pr_diff_failure — (stdout, stderr) → outcome token
# =====================================================================
# Worker switches on the token: "ok" passes through, "cap-exceeded"
# triggers a local git diff fallback, "error" aborts loudly. The
# tri-state is load-bearing — collapsing "cap-exceeded" into "error"
# (the prior worker behavior with `2>/dev/null`) lost reviewable
# 300-650-file PRs to a wrong-cause "auth/network" abort.

assert_classify_gh() {
    local stdout="$1" stderr="$2" expected="$3" desc="$4"
    local got
    got=$(classify_gh_pr_diff_failure "$stdout" "$stderr")
    if [ "$got" != "$expected" ]; then
        echo "FAIL: classify_gh_pr_diff_failure — $desc: expected '$expected', got '$got'"
        exit 1
    fi
}

echo "  classify_gh: non-empty stdout → ok (no fallback needed)..."
assert_classify_gh \
    "$(printf 'diff --git a/foo b/foo\nindex abc..def\n--- a/foo\n+++ b/foo\n@@\n-x\n+y\n')" \
    "" \
    "ok" \
    "non-empty stdout passes through"

echo "  classify_gh: empty stdout + HTTP 406 status (the reliable backstop) → cap-exceeded..."
# HTTP 406 is the underlying status — gh always prefixes API errors
# with `HTTP NNN`. Match on this even if the textual reason changes.
assert_classify_gh \
    "" \
    "HTTP 406: this diff is too large to render" \
    "cap-exceeded" \
    "HTTP 406 status alone fences the cap"

echo "  classify_gh: empty stdout + 'exceeded max files (300)' stderr → cap-exceeded (user-diagnosed wording)..."
assert_classify_gh \
    "" \
    "gh: exceeded max files (300)" \
    "cap-exceeded" \
    "user-diagnosed wording from PR #31 follow-up"

echo "  classify_gh: empty stdout + 'maximum number of files' stderr → cap-exceeded (alt phrasing)..."
assert_classify_gh \
    "" \
    "pull request diff exceeded the maximum number of files: 300" \
    "cap-exceeded" \
    "GitHub API verbose phrasing"

echo "  classify_gh: empty stdout + auth-failure stderr → error..."
assert_classify_gh \
    "" \
    "gh: To get started with GitHub CLI, please run:  gh auth login" \
    "error" \
    "auth failure must NOT be misclassified as cap-exceeded"

echo "  classify_gh: empty stdout + network-failure stderr → error..."
assert_classify_gh \
    "" \
    "gh: error connecting to api.github.com" \
    "error" \
    "network failure must NOT be misclassified as cap-exceeded"

echo "  classify_gh: empty stdout + empty stderr → error (no signal at all, abort safely)..."
assert_classify_gh \
    "" \
    "" \
    "error" \
    "totally empty failure → error (not ok, not cap-exceeded)"

# Wording-fence: the GitHub error string for the cap mentions both
# "exceeded" and "300". Match must NOT be tied to the exact "300"
# constant — GitHub could raise the cap to 500 without changing the
# helper's behavior. Check that wording-only changes work.
echo "  classify_gh: empty stdout + cap-stderr with different number → still cap-exceeded..."
assert_classify_gh \
    "" \
    "HTTP 406: pull request diff exceeded the maximum number of files: 500" \
    "cap-exceeded" \
    "cap-exceeded match must not pin to a specific file count"

echo "  PASS (4 is_clean + 7 extract_touched_files_both_sides + 8 classify_gh_pr_diff_failure scenarios; rename/delete + 300-file-cap fences for PR #31)"
