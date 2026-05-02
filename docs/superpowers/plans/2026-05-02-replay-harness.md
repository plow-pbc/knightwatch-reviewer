# Replay Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `lib/replay.sh` — a deterministic harness that re-runs the review pipeline against frozen historical run-dir snapshots, so prompt edits can be validated experimentally before merge. Sets up the seam for downstream LLM-as-a-judge iteration.

**Architecture:** `dispatch_agent` is the canonical worker entry point per stage and already handles all prompt-building. We add one override (`PROMPTS_DIR`) so replay can swap prompt sets, then build `lib/replay.sh` as a thin wrapper that stages a fixture into a tmp run-dir and re-invokes `dispatch_agent` for the requested stage. Validation is via shape assertions (token presence/absence, byte caps, severity counts) against output.md — never exact-text diffs, since LLM output is non-deterministic. Fixtures live under `lib/tests/fixtures/runs/<name>/` as trimmed copies of real `~/.pr-reviewer/runs/` snapshots from wakeup. First scope: stage-only replay (`--stage aggregator`). From-stage and full replay come in a follow-up plan once first cut is validated.

**Tech Stack:** bash, jq, codex CLI (existing). No new deps.

**Test principles** (from `~/.claude/CODING_STANDARDS.md` and `~/.claude/CLAUDE.md`):
- Loud-on-failure — no skips, no soft passes; a broken test crashes
- Test behavior, not self-evident language/runtime details
- Shared fixtures over inline setup; refactor lifecycle setup into helpers
- Remove low-value helper tests before adding boilerplate
- 1–2 focused behavior tests per cross-layer change, not exhaustive layer-by-layer
- A bug fix without a regression test that exercises the old-bug path is *blocking: tests*

**Test consolidation:** `prompts/anti-bloat-contract-smoke.sh` (146 LoC, token-presence in `prompts/*.md`) and `prompts/momentum-wire-smoke.sh` (49 LoC, token-presence in `lib/orchestrate.sh`) both use the same `assert_grep` shape on tracked files. Folded into one `prompt-contracts-smoke.sh`. Net −75 LoC of test code, justfile entries collapse from 2 to 1, no behavior loss.

---

## File Structure

**New files:**
- `lib/replay.sh` — main entry point: `replay <fixture> --stage <name> [--prompts DIR] [--diff]`
- `lib/replay-shape.sh` — shape-assertion DSL (`assert_contains`, `assert_not_contains`, `assert_byte_cap`, `assert_severity_count`)
- `lib/tests/replay-smoke.sh` — end-to-end smoke for the replay tool itself (uses a synthetic fixture with a stubbed `codex`)
- `lib/tests/prompt-contracts-smoke.sh` — consolidated token-presence checks (replaces `anti-bloat-contract-smoke.sh` + `momentum-wire-smoke.sh`)
- `lib/tests/fixtures/runs/README.md` — fixture format spec
- `lib/tests/fixtures/runs/552-r11-stuck-record/` — canonical fixture (the "carry-forward without critic" collapse case)
  - `meta.json`, `inputs/`, `agents/<each>/output.md`, `expected/aggregator.shape`, `expected/notes.md`
- `tools/freeze-run.sh` — extract a fixture from a wakeup run-dir
- `lib/tests/fixtures/judge-rubric.md` — placeholder rubric format spec for downstream LLM-as-a-judge work (no judge invocation yet)

**Modified files:**
- `lib/orchestrate.sh` — add `PROMPTS_DIR` override (1 line)
- `lib/prompt-build.sh` — add `PROMPTS_DIR` override (3 lines)
- `lib/tests/build-specialist-prompt-smoke.sh` — extend with `PROMPTS_DIR` override scenario
- `justfile` — add `replay`, `replay-all` recipes; collapse two anti-bloat/momentum entries into one `prompt-contracts` entry
- `lib/tests/anti-bloat-contract-smoke.sh` — DELETE (folded)
- `lib/tests/momentum-wire-smoke.sh` — DELETE (folded)

---

## Task 1: Add `PROMPTS_DIR` override to prompt-reading code paths

**Files:**
- Modify: `lib/prompt-build.sh:41`, `lib/prompt-build.sh:66-67`
- Modify: `lib/orchestrate.sh:61` (default-specialist case) AND `lib/orchestrate.sh:75` (`go-deep-*` case from PR #42)
- Test: `lib/tests/build-specialist-prompt-smoke.sh` (extend)

**Why this is a separate task:** every later task assumes prompts can be swapped via env var. Land this seam first so subsequent tasks have something to lean on.

- [ ] **Step 1: Write the failing test scenario in `lib/tests/build-specialist-prompt-smoke.sh`**

Append a new scenario before the final `echo "ok"` line. Find the end of the file (around line 270) and add:

```bash
echo "  scenario: PROMPTS_DIR override redirects prompt reads..."

# Set up an alternate prompts dir with a stub common-header that the
# default path would NOT have. If the override is honored, build_specialist_prompt
# must read from the alternate path.
ALT_PROMPTS_DIR="$TMPDIR/alt-prompts"
mkdir -p "$ALT_PROMPTS_DIR"
cat > "$ALT_PROMPTS_DIR/common-header.md" <<'COMMON'
ALT_COMMON_MARKER

PR: {{PR_ID}}
COMMON
cat > "$ALT_PROMPTS_DIR/security.md" <<'BODY'
ALT_BODY_MARKER

You are the security specialist for {{PR_ID}}.
BODY

# Default path would be $HOME/.pr-reviewer/prompts/common-header.md (set above
# in this test to point at /tmp/...prompts). Override should win.
PROMPTS_DIR="$ALT_PROMPTS_DIR" \
    OUT=$(build_specialist_prompt security "$ALT_PROMPTS_DIR/security.md" \
        "owner/repo#1" "title" "https://x" "alice")

echo "$OUT" | grep -qF "ALT_COMMON_MARKER" \
    || { echo "FAIL: PROMPTS_DIR override didn't redirect common-header"; exit 1; }
echo "$OUT" | grep -qF "ALT_BODY_MARKER" \
    || { echo "FAIL: alt body marker missing"; exit 1; }

# And verify default behavior still works (PROMPTS_DIR unset → falls back).
unset PROMPTS_DIR
OUT_DEFAULT=$(build_specialist_prompt security "$ALT_PROMPTS_DIR/security.md" \
    "owner/repo#1" "title" "https://x" "alice")
echo "$OUT_DEFAULT" | grep -qF "ALT_COMMON_MARKER" \
    && { echo "FAIL: default (PROMPTS_DIR unset) leaked alt path"; exit 1; }

echo "  ok: PROMPTS_DIR override + default fallback"
```

- [ ] **Step 2: Run the smoke; expect failure on the new scenario**

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
bash lib/tests/build-specialist-prompt-smoke.sh
```

Expected: previous scenarios pass, new scenario fails — output contains `FAIL: PROMPTS_DIR override didn't redirect common-header` (because the production code reads `$HOME/.pr-reviewer/prompts/common-header.md` literally with no env override).

- [ ] **Step 3: Add the `PROMPTS_DIR` override to `lib/prompt-build.sh`**

Edit `lib/prompt-build.sh`. Replace the three hardcoded paths.

In `build_specialist_prompt` (around line 41), change:

```bash
    local common="$HOME/.pr-reviewer/prompts/common-header.md"
```

to:

```bash
    local common="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/common-header.md"
```

In `build_aggregator_prompt` (around lines 66-67), change:

```bash
    local aggregator="$HOME/.pr-reviewer/prompts/aggregator.md"
    local voice="$HOME/.pr-reviewer/prompts/voice.md"
```

to:

```bash
    local prompts_dir="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}"
    local aggregator="$prompts_dir/aggregator.md"
    local voice="$prompts_dir/voice.md"
```

- [ ] **Step 4: Add the same override to BOTH prompt-paths in `lib/orchestrate.sh`**

`dispatch_agent` (introduced in PR #43, extended in PR #42's go-deep branch) reads from two distinct hardcoded prompt paths. Both need the override.

At line 61, change:

```bash
    local file="$HOME/.pr-reviewer/prompts/${name}.md"
```

to:

```bash
    local file="${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/${name}.md"
```

At line 75 (inside the `go-deep-*)` case), change:

```bash
            prompt=$(substitute_placeholders \
                "$HOME/.pr-reviewer/prompts/go-deep.md" \
                "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR" "$angle") ;;
```

to:

```bash
            prompt=$(substitute_placeholders \
                "${PROMPTS_DIR:-$HOME/.pr-reviewer/prompts}/go-deep.md" \
                "$PR_ID" "$PR_TITLE" "$PR_URL" "$PR_AUTHOR" "$angle") ;;
```

Sanity-check after both edits: `grep -c '\$HOME/.pr-reviewer/prompts' lib/orchestrate.sh lib/prompt-build.sh` should return 0 (every reference now has the env-var override).

- [ ] **Step 5: Re-run the smoke; expect pass**

```bash
bash lib/tests/build-specialist-prompt-smoke.sh
```

Expected: `ok: PROMPTS_DIR override + default fallback` printed; exit 0.

- [ ] **Step 6: Run the full pre-merge suite to verify nothing broke**

```bash
just test
```

Expected: all 29 existing smokes pass (the override is opt-in via env var; everything else is unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/prompt-build.sh lib/orchestrate.sh lib/tests/build-specialist-prompt-smoke.sh
git commit -m "$(cat <<'EOF'
feat(replay): PROMPTS_DIR override on prompt-reading paths

Lets the replay harness swap prompt sets without touching the production
~/.pr-reviewer/prompts symlink. Default behavior unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Build `lib/replay-shape.sh` assertion DSL

**Files:**
- Create: `lib/replay-shape.sh`
- Create: `lib/tests/replay-shape-smoke.sh`

**Why a separate file:** the assertion vocabulary needs to be standalone so fixture `expected/<stage>.shape` files can be diff-readable and so `replay-smoke.sh` can exercise the assertion runner against synthetic outputs without spinning up `dispatch_agent`. Avoids fixture rot per `~/.claude/CLAUDE.md`'s "remove low-value helper tests before adding boilerplate" — one shared assertion vocab, not per-fixture grep boilerplate.

- [ ] **Step 1: Write the failing test `lib/tests/replay-shape-smoke.sh`**

```bash
#!/bin/bash
# Smoke for lib/replay-shape.sh — the assertion DSL the replay harness
# uses to fence pipeline output behavior. Assertions are intentionally
# loose (token presence/absence, byte caps, severity counts) — exact-text
# matches against LLM output would calcify on temperature jitter.
#
# Hermetic: no codex, no network, no fixtures — synthetic strings only.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../replay-shape.sh
. "$PROJECT_ROOT/lib/replay-shape.sh"

TMPDIR=$(mktemp -d -t replay-shape-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# ---- assert_contains ----
echo "  scenario: assert_contains hits a literal substring..."
SAMPLE="**Findings**
1. [blocking] something
2. [medium] something else"
assert_contains "$SAMPLE" "[blocking]" "should find blocking" \
    || { echo "FAIL: assert_contains missed a literal hit"; exit 1; }

echo "  scenario: assert_contains exits non-zero on miss..."
if assert_contains "$SAMPLE" "ZZZZ_not_present" "should miss" 2>/dev/null; then
    echo "FAIL: assert_contains returned 0 for absent token"
    exit 1
fi

# ---- assert_not_contains ----
echo "  scenario: assert_not_contains passes when token absent..."
assert_not_contains "$SAMPLE" "Pre-merge auto-checks" "no pre-merge section" \
    || { echo "FAIL: assert_not_contains tripped on legitimately absent token"; exit 1; }

echo "  scenario: assert_not_contains fails when token present..."
if assert_not_contains "$SAMPLE" "[blocking]" "should fail — blocking is present" 2>/dev/null; then
    echo "FAIL: assert_not_contains returned 0 with token clearly present"
    exit 1
fi

# ---- assert_byte_cap ----
echo "  scenario: assert_byte_cap passes when under cap..."
assert_byte_cap "$SAMPLE" 1000 "small sample under 1000 bytes" \
    || { echo "FAIL: byte_cap tripped on body well under cap"; exit 1; }

echo "  scenario: assert_byte_cap fails when over cap..."
BIG=$(printf 'x%.0s' $(seq 1 2000))
if assert_byte_cap "$BIG" 500 "should fail — 2000 chars vs cap 500" 2>/dev/null; then
    echo "FAIL: byte_cap returned 0 on a body 4× the cap"
    exit 1
fi

# ---- assert_severity_count ----
# Counts occurrences of "[<severity>]" markers in the body. Used to
# fence "no more than N blocking findings" type assertions.
echo "  scenario: assert_severity_count exact match..."
assert_severity_count "$SAMPLE" "blocking" 1 "expect exactly 1 blocking" \
    || { echo "FAIL: severity_count miscounted blocking=1"; exit 1; }
assert_severity_count "$SAMPLE" "medium" 1 "expect exactly 1 medium" \
    || { echo "FAIL: severity_count miscounted medium=1"; exit 1; }
assert_severity_count "$SAMPLE" "low" 0 "expect 0 low" \
    || { echo "FAIL: severity_count miscounted low=0"; exit 1; }

echo "  scenario: assert_severity_count fails on mismatch..."
if assert_severity_count "$SAMPLE" "blocking" 5 "should fail" 2>/dev/null; then
    echo "FAIL: severity_count returned 0 on wrong count"
    exit 1
fi

# ---- run_shape_file ----
# A .shape file is a series of one-assertion-per-line directives. Empty
# lines and lines starting with `#` are ignored. Each non-comment line
# is a directive: contains <token>, not_contains <token>,
# byte_cap <int>, severity_count <name> <int>.
echo "  scenario: run_shape_file applies all directives in order..."
cat > "$TMPDIR/sample.shape" <<'SHAPE'
# fixture: synthetic
contains [blocking]
not_contains Pre-merge auto-checks
byte_cap 1000
severity_count blocking 1
severity_count medium 1
SHAPE
run_shape_file "$SAMPLE" "$TMPDIR/sample.shape" \
    || { echo "FAIL: shape file with all-passing directives didn't pass"; exit 1; }

echo "  scenario: run_shape_file fails loud on first failed directive..."
cat > "$TMPDIR/bad.shape" <<'SHAPE'
contains [blocking]
contains ZZZZ_not_present
SHAPE
if run_shape_file "$SAMPLE" "$TMPDIR/bad.shape" 2>/dev/null; then
    echo "FAIL: bad shape file passed when it should have failed"
    exit 1
fi

echo "ok"
```

- [ ] **Step 2: Run the smoke — expect failure (file doesn't exist yet)**

```bash
bash lib/tests/replay-shape-smoke.sh
```

Expected: `lib/tests/replay-shape-smoke.sh: line 11: lib/replay-shape.sh: No such file or directory`.

- [ ] **Step 3: Implement `lib/replay-shape.sh`**

```bash
#!/bin/bash
# Replay shape-assertion DSL.
#
# Used by lib/replay.sh and fixture `expected/<stage>.shape` files to
# fence pipeline-output behavior without calcifying exact wording.
# Each assertion fails LOUD: prints to stderr what was expected vs
# what was found, and returns non-zero so callers using `set -e`
# crash the run on first failure.
#
# The DSL is intentionally small. Add a directive ONLY when the new
# class of assertion can't be expressed via the existing four.

assert_contains() {
    local body="$1" token="$2" label="${3:-}"
    if printf '%s' "$body" | grep -qF -- "$token"; then
        return 0
    fi
    printf 'assert_contains FAIL: token %s not found in body (label: %s)\n' \
        "$(printf '%q' "$token")" "$label" >&2
    return 1
}

assert_not_contains() {
    local body="$1" token="$2" label="${3:-}"
    if printf '%s' "$body" | grep -qF -- "$token"; then
        printf 'assert_not_contains FAIL: token %s present in body but should be absent (label: %s)\n' \
            "$(printf '%q' "$token")" "$label" >&2
        return 1
    fi
    return 0
}

assert_byte_cap() {
    local body="$1" cap="$2" label="${3:-}"
    local size
    size=$(printf '%s' "$body" | wc -c | tr -d ' ')
    if [ "$size" -le "$cap" ]; then
        return 0
    fi
    printf 'assert_byte_cap FAIL: body %d bytes > cap %d (label: %s)\n' \
        "$size" "$cap" "$label" >&2
    return 1
}

assert_severity_count() {
    local body="$1" severity="$2" expected="$3" label="${4:-}"
    local actual
    actual=$(printf '%s' "$body" | grep -cF -- "[$severity]")
    if [ "$actual" -eq "$expected" ]; then
        return 0
    fi
    printf 'assert_severity_count FAIL: severity=%s expected=%d actual=%d (label: %s)\n' \
        "$severity" "$expected" "$actual" "$label" >&2
    return 1
}

# run_shape_file BODY SHAPE_FILE
#   Applies every directive in SHAPE_FILE to BODY. Returns 0 only if
#   every directive passes. First failure prints to stderr and exits
#   the function with the assertion's return code.
run_shape_file() {
    local body="$1" shape_file="$2"
    if [ ! -f "$shape_file" ]; then
        printf 'run_shape_file FAIL: shape file not found: %s\n' "$shape_file" >&2
        return 2
    fi
    local lineno=0
    local line directive arg1 arg2 arg3
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # Skip blanks and comments.
        case "$line" in
            ''|'#'*) continue ;;
        esac
        # Split: directive [arg1] [arg2] [arg3...]
        # `read` with explicit field count handles tokens-with-spaces in arg2+ for `contains "foo bar"`.
        directive=$(printf '%s\n' "$line" | awk '{print $1}')
        case "$directive" in
            contains)
                arg1=$(printf '%s\n' "$line" | sed -E 's/^contains[[:space:]]+//')
                assert_contains "$body" "$arg1" "$shape_file:$lineno" || return $?
                ;;
            not_contains)
                arg1=$(printf '%s\n' "$line" | sed -E 's/^not_contains[[:space:]]+//')
                assert_not_contains "$body" "$arg1" "$shape_file:$lineno" || return $?
                ;;
            byte_cap)
                arg1=$(printf '%s\n' "$line" | awk '{print $2}')
                assert_byte_cap "$body" "$arg1" "$shape_file:$lineno" || return $?
                ;;
            severity_count)
                arg1=$(printf '%s\n' "$line" | awk '{print $2}')
                arg2=$(printf '%s\n' "$line" | awk '{print $3}')
                assert_severity_count "$body" "$arg1" "$arg2" "$shape_file:$lineno" || return $?
                ;;
            *)
                printf 'run_shape_file FAIL: unknown directive %q at %s:%d\n' \
                    "$directive" "$shape_file" "$lineno" >&2
                return 2
                ;;
        esac
    done < "$shape_file"
    return 0
}
```

- [ ] **Step 4: Run the smoke — expect pass**

```bash
bash lib/tests/replay-shape-smoke.sh
```

Expected: each `scenario:` line prints, final `ok` prints; exit 0.

- [ ] **Step 5: Wire into justfile**

Edit `justfile`. After the existing `bash lib/tests/critic-fallback-smoke.sh` block (around line 86), add:

```
    echo "=== replay-shape smoke ==="
    bash lib/tests/replay-shape-smoke.sh
```

Run `just test`. Expected: all smokes pass, including the new one.

- [ ] **Step 6: Commit**

```bash
git add lib/replay-shape.sh lib/tests/replay-shape-smoke.sh justfile
git commit -m "$(cat <<'EOF'
feat(replay): shape-assertion DSL for fence-against-LLM-output testing

Four directives (contains / not_contains / byte_cap / severity_count) cover
the fence classes the replay harness needs without calcifying exact LLM
output. Loose-on-prose, strict-on-shape — survives temperature jitter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Define fixture format + `tools/freeze-run.sh`

**Files:**
- Create: `tools/freeze-run.sh`
- Create: `lib/tests/fixtures/runs/README.md`
- Create: `lib/tests/fixtures/runs/.gitkeep` (so the dir is tracked even when empty)

**Why a separate task:** the fixture format is the contract every later fixture follows. Lock it down once, in one place, before populating.

- [ ] **Step 1: Write `lib/tests/fixtures/runs/README.md`**

```markdown
# Replay fixtures

Frozen snapshots of real review runs. Each fixture is a trimmed copy of
a `~/.pr-reviewer/runs/<run-id>/` directory from wakeup, plus an
`expected/` subdir with shape assertions.

## Layout

```
lib/tests/fixtures/runs/<fixture-name>/
├── meta.json                    # frozen from the original run
├── inputs/
│   ├── diff.patch
│   ├── full-diff.patch          # present on re-reviews
│   ├── prior-reviews.md         # present when ≥1 prior review
│   ├── previous-review.md
│   ├── standards.md
│   ├── product-context.md
│   ├── commits.md
│   ├── file-history.md
│   ├── author-intent.md
│   └── (other inputs/*.md the worker stages)
├── agents/
│   ├── intent/output.md
│   ├── security/output.md
│   ├── data-integrity/output.md
│   ├── architecture/output.md
│   ├── simplification/output.md
│   ├── tests/output.md
│   ├── shape/output.md
│   ├── performance/output.md
│   ├── consumers/output.md
│   ├── dead-code-search/output.md
│   ├── critic/output.md
│   └── aggregator/output.md     # baseline output we're trying to improve on
└── expected/
    ├── notes.md                 # what this fixture is testing
    └── <stage>.shape            # shape assertions per stage we replay
```

## Naming

`<pr-num>-r<round>-<short-symptom>` — e.g. `552-r11-stuck-record`,
`562-r1-strict-typing-hallucination`. Names should immediately tell a
reader what failure mode this fixture pins.

## Size budget

Each fixture < 300 KB. Real runs are ~3 MB; the freeze tool drops
prompt.txt files (regenerable) and `log.txt` files (operational) and
keeps only `output.md` per agent. If a fixture exceeds 300 KB, trim
its `inputs/` files (e.g., truncate prior-reviews.md to the most
recent 3 reviews) — fence the trim with a comment in
`expected/notes.md`.

## Adding a fixture

```bash
# On wakeup, identify the run-dir to freeze:
ls /home/odio/.pr-reviewer/runs/ | grep cncorp_plow__552 | sort
# Copy locally:
scp -r odio@wakeup:/home/odio/.pr-reviewer/runs/cncorp_plow__552__... /tmp/
# Freeze:
./tools/freeze-run.sh /tmp/cncorp_plow__552__... 552-r11-stuck-record
# Then write expected/notes.md and expected/aggregator.shape by hand.
```

## What gets dropped during freeze

- `agents/<name>/prompt.txt` — regenerable from current prompts/ + inputs
- `agents/<name>/log.txt` — operational, no fixture value
- `inputs/diff.patch.tmp`, any `.lock` files
- Anything > 100 KB in `inputs/` gets a stderr warning (decide: trim or drop)

## What MUST stay

- `meta.json` (drives stage-replay's input-binding)
- All `inputs/*.md` not size-flagged
- All `agents/<name>/output.md` (used as baseline + input to downstream stages)
- `expected/` (assertions — the regression fence)
```

- [ ] **Step 2: Write `tools/freeze-run.sh`**

```bash
#!/bin/bash
# Freeze a wakeup run-dir into a replay fixture.
#
# Usage: tools/freeze-run.sh <source-run-dir> <fixture-name>
#
#   <source-run-dir> — path to a directory like
#                      ~/.pr-reviewer/runs/cncorp_plow__552__...
#   <fixture-name>   — short slug, will be created at
#                      lib/tests/fixtures/runs/<fixture-name>/
#
# Drops regenerable + operational files (prompt.txt, log.txt). Warns
# loud (stderr) if any retained file is > 100 KB so the operator can
# decide whether to trim. Refuses to overwrite an existing fixture
# without --force (don't silently clobber a hand-tuned shape file).

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <source-run-dir> <fixture-name> [--force]" >&2
    exit 2
fi

SRC="$1"
NAME="$2"
FORCE="${3:-}"

if [ ! -d "$SRC" ]; then
    echo "freeze-run: source not a directory: $SRC" >&2
    exit 1
fi
if [ ! -f "$SRC/meta.json" ]; then
    echo "freeze-run: source missing meta.json — not a valid run-dir: $SRC" >&2
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$PROJECT_ROOT/lib/tests/fixtures/runs/$NAME"

if [ -d "$DEST" ] && [ "$FORCE" != "--force" ]; then
    echo "freeze-run: fixture already exists at $DEST (pass --force to overwrite)" >&2
    exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"

# meta.json — direct copy
cp "$SRC/meta.json" "$DEST/meta.json"

# inputs/ — copy whole tree
if [ -d "$SRC/inputs" ]; then
    cp -r "$SRC/inputs" "$DEST/inputs"
fi

# agents/ — copy each agent's output.md only; drop prompt.txt + log.txt
mkdir -p "$DEST/agents"
for agent_dir in "$SRC/agents"/*/; do
    [ -d "$agent_dir" ] || continue
    name=$(basename "$agent_dir")
    if [ -f "$agent_dir/output.md" ]; then
        mkdir -p "$DEST/agents/$name"
        cp "$agent_dir/output.md" "$DEST/agents/$name/output.md"
    fi
done

# expected/ — placeholder structure; operator writes shape files by hand
mkdir -p "$DEST/expected"
cat > "$DEST/expected/notes.md" <<EOF
# Fixture: $NAME

Source: \`$(basename "$SRC")\`
Frozen: $(date -u +%Y-%m-%dT%H:%M:%SZ)

## What this fixture pins

(TODO: describe the failure mode this fixture is regression-fencing.)

## Stages with .shape assertions

(TODO: list, e.g. \`aggregator.shape\` — what each one fences.)
EOF

# Size warning pass.
echo "Frozen $NAME at $DEST"
echo "Sizes (warn if > 100 KB):"
find "$DEST" -type f -size +100k -printf '  WARN: %p — %k KB\n' >&2
TOTAL_KB=$(du -sk "$DEST" | awk '{print $1}')
echo "  total: ${TOTAL_KB} KB (budget: 300 KB)"
if [ "$TOTAL_KB" -gt 300 ]; then
    echo "  WARN: fixture exceeds 300 KB budget — trim before committing" >&2
fi
```

- [ ] **Step 3: Make the tool executable + create the empty fixtures dir**

```bash
chmod +x tools/freeze-run.sh
mkdir -p lib/tests/fixtures/runs
touch lib/tests/fixtures/runs/.gitkeep
```

- [ ] **Step 4: Smoke-test the freeze tool against a synthetic source dir**

```bash
TMPDIR=$(mktemp -d)
SRC="$TMPDIR/synthetic-run"
mkdir -p "$SRC/inputs" "$SRC/agents/aggregator" "$SRC/agents/critic"
cat > "$SRC/meta.json" <<'JSON'
{"repo":"x/y","pr_id":"x/y#1","pr_num":1,"sha":"deadbeef","branch":"b","title":"t",
 "started_at":"2026-05-02T00:00:00Z","posted_at":"2026-05-02T00:01:00Z","status":"completed"}
JSON
echo "diff content" > "$SRC/inputs/diff.patch"
echo "agg output" > "$SRC/agents/aggregator/output.md"
echo "agg prompt — should be dropped" > "$SRC/agents/aggregator/prompt.txt"
echo "agg log — should be dropped" > "$SRC/agents/aggregator/log.txt"
echo "critic out" > "$SRC/agents/critic/output.md"

./tools/freeze-run.sh "$SRC" smoke-fixture --force

# Assertions
DEST=lib/tests/fixtures/runs/smoke-fixture
[ -f "$DEST/meta.json" ] || { echo "FAIL: meta.json missing"; exit 1; }
[ -f "$DEST/inputs/diff.patch" ] || { echo "FAIL: diff.patch missing"; exit 1; }
[ -f "$DEST/agents/aggregator/output.md" ] || { echo "FAIL: agg output missing"; exit 1; }
[ ! -f "$DEST/agents/aggregator/prompt.txt" ] || { echo "FAIL: prompt.txt should be dropped"; exit 1; }
[ ! -f "$DEST/agents/aggregator/log.txt" ] || { echo "FAIL: log.txt should be dropped"; exit 1; }
[ -f "$DEST/expected/notes.md" ] || { echo "FAIL: notes.md placeholder missing"; exit 1; }
echo "ok"

# Clean up the smoke fixture (we don't want to commit it)
rm -rf "$DEST"
```

Expected: prints `ok`. The smoke-fixture dir is removed before commit.

- [ ] **Step 5: Commit**

```bash
git add tools/freeze-run.sh lib/tests/fixtures/runs/README.md lib/tests/fixtures/runs/.gitkeep
git commit -m "$(cat <<'EOF'
feat(replay): fixture format spec + freeze-run tool

Drops regenerable artifacts (prompt.txt, log.txt) and warns on
oversize files. Each fixture < 300 KB.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Freeze the canonical 552-R11 fixture + write expected shape

**Files:**
- Create: `lib/tests/fixtures/runs/552-r11-stuck-record/` (full tree, populated by freeze tool)
- Create: `lib/tests/fixtures/runs/552-r11-stuck-record/expected/aggregator.shape`
- Create: `lib/tests/fixtures/runs/552-r11-stuck-record/expected/notes.md` (overwrite the placeholder)

**Why this fixture first:** R11 is the load-bearing collapse case. 99-line incremental diff, 9 prior reviews, 3 carried-forward Bug-Class-Recurrence findings, the actual 5.7 KB output we want to learn to NOT produce on the next prompt iteration.

- [ ] **Step 1: Pull the run-dir from wakeup**

```bash
TMPSRC=$(mktemp -d)
scp -r odio@wakeup:/home/odio/.pr-reviewer/runs/cncorp_plow__552__20260501T010012396Z__5a88157 "$TMPSRC/"
ls "$TMPSRC/cncorp_plow__552__20260501T010012396Z__5a88157/"
```

Expected: see `agents`, `inputs`, `meta.json`, `run.log`.

- [ ] **Step 2: Freeze it**

```bash
./tools/freeze-run.sh "$TMPSRC/cncorp_plow__552__20260501T010012396Z__5a88157" 552-r11-stuck-record
```

Expected: `Frozen 552-r11-stuck-record at lib/tests/fixtures/runs/552-r11-stuck-record`. Size warnings will fire on `inputs/full-diff.patch` (large) and possibly `inputs/prior-reviews.md`.

- [ ] **Step 3: Trim oversize inputs**

```bash
DEST=lib/tests/fixtures/runs/552-r11-stuck-record

# full-diff.patch is ~13 MB and not strictly required for an aggregator
# replay (the aggregator reads diff.patch + cited file paths). Drop it.
rm -f "$DEST/inputs/full-diff.patch"

# prior-reviews.md may need a trim — keep only the most recent 3 reviews
# so the fixture stays under 300 KB. The trim is itself the fence: if
# Bug-Class-Recurrence detection requires fewer than 3 prior reviews,
# this fixture exposes that.
# Use awk to keep only the last 3 `--- review at ... ---` blocks.
python3 - "$DEST/inputs/prior-reviews.md" <<'PY'
import re, sys
p = sys.argv[1]
with open(p) as f:
    text = f.read()
blocks = re.split(r'(?=^--- review at )', text, flags=re.M)
# blocks[0] is the prefix before any block (usually empty); the rest are
# review blocks. Keep the last 3.
prefix = blocks[0]
review_blocks = blocks[1:]
kept = review_blocks[-3:] if len(review_blocks) > 3 else review_blocks
with open(p, 'w') as f:
    f.write(prefix + ''.join(kept))
PY

du -sk "$DEST"
```

Expected: `du -sk` reports < 300 KB.

- [ ] **Step 4: Write `expected/notes.md` (overwrite placeholder)**

```bash
cat > lib/tests/fixtures/runs/552-r11-stuck-record/expected/notes.md <<'EOF'
# Fixture: 552-r11-stuck-record

Source: `cncorp_plow__552__20260501T010012396Z__5a88157`
Frozen: 2026-05-02

## What this fixture pins

R11 of cncorp/plow#552 — the canonical "stuck-record" collapse case.
The increment was 99 lines (manifest pin + lockfile bump). Prior 9 reviews
flagged 3 Bug-Class-Recurrence findings (F1 endpoint resolution, F2 lifecycle
atomicity, F3 DiagnosticsBundler hardcoding). Plonkus made zero commits in
response across R3–R11; the bot kept re-emitting ~5 KB of carried-forward
prose every 30 minutes.

The aggregator output we're trying NOT to reproduce:
- `Pre-merge auto-checks` section (LLM-hallucinated, no header note for it)
- 3+ `[blocking]` findings on a 99-line lockfile-bump increment
- ~5700 bytes total body length

## Stages with .shape assertions

- `aggregator.shape` — fences the four collapse modes:
  1. No "Pre-merge auto-checks" section (LLM hallucinates this even when
     the worker scope-skipped strict-typing — see `lib/checks/python-strict-typing.sh`).
  2. Carried-forward findings count downgrades after 3+ rounds with no
     author engagement (max 1 blocking carried forward, not 3).
  3. Body byte-cap: < 1500 bytes when increment < 200 LOC and < 3 new
     findings (R11's increment qualifies).
  4. No "How to use" trailer on re-reviews.

## Trims

- `inputs/full-diff.patch` dropped (was 13 MB, not needed for aggregator-only replay).
- `inputs/prior-reviews.md` truncated to the 3 most recent reviews
  (was 9 reviews, ~22 KB; trimmed for the 300 KB fixture budget).
EOF
```

- [ ] **Step 5: Write `expected/aggregator.shape`**

```bash
cat > lib/tests/fixtures/runs/552-r11-stuck-record/expected/aggregator.shape <<'EOF'
# 552-r11-stuck-record — aggregator output assertions.
#
# This fixture is the regression fence for the four collapse modes
# documented in expected/notes.md. Each directive lines up with one of
# them. If a future prompt change re-introduces any of these, this
# shape file fails LOUD.

# Mode 1: hallucinated Pre-merge section. The worker's scope-skip
# means no `❌ Strict typing not enforced` header; the LLM must not
# invent the section under any other framing.
not_contains Pre-merge auto-checks
not_contains Sam stubbornly wants strict mode

# Mode 2: carried-forward fatigue. After 3+ rounds with no author
# engagement, BCR findings should downgrade or collapse. Cap blocking
# count at 2 — the new dirty-ref finding (legitimate) plus at most one
# carried-forward. Anything higher means the bot is still autopiloting
# 3+ blockers from prior reviews.
severity_count blocking 2

# Mode 3: body byte-cap on small increments. Increment is 99 lines;
# fewer than 3 NEW specialist findings. Body should compress.
byte_cap 1500

# Mode 4: re-review trailer. First review needs the slash-command
# explainer; re-reviews don't.
not_contains For humans only
not_contains Generated by [sam's ai review bot]

# Negative-space sanity: every aggregator output must still produce
# the verdict line.
contains VERDICT
EOF
```

- [ ] **Step 6: Verify the fixture passes its shape against the BASELINE output (it should fail — baseline is the bug)**

This is the regression fence working as intended: the original R11 output is what we're trying to NOT produce, so running the shape against it should FAIL on every assertion that pins the bug.

```bash
cd /Users/so/Hacking/knightwatch-reviewer2
. lib/replay-shape.sh
BASELINE=$(cat lib/tests/fixtures/runs/552-r11-stuck-record/agents/aggregator/output.md)
run_shape_file "$BASELINE" lib/tests/fixtures/runs/552-r11-stuck-record/expected/aggregator.shape
echo "exit=$?"
```

Expected: stderr shows multiple assert FAILs (Pre-merge auto-checks present, severity_count blocking ≠ 2 or 3, byte_cap exceeded, etc.). `exit=` is non-zero. **This is correct** — the baseline is the bug.

- [ ] **Step 7: Commit the fixture**

```bash
git add lib/tests/fixtures/runs/552-r11-stuck-record/
git commit -m "$(cat <<'EOF'
feat(replay): fixture for #552 R11 stuck-record collapse

Pins four collapse modes from the audit: hallucinated Pre-merge section,
carried-forward fatigue without engagement signal, oversize body on
small-increment re-reviews, repeated trailer on re-reviews. The current
prompt set fails these assertions — that's the regression fence we're
working against.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Build `lib/replay.sh` stage-only mode

**Files:**
- Create: `lib/replay.sh`
- Create: `lib/tests/replay-smoke.sh`

**Why stage-only first:** the stuck-record collapse is an aggregator-only failure mode (specialists were fine; the aggregator inserted carried-forward findings). Aggregator-only replay covers most prompt-iteration use cases at < $0.10 per replay. From-stage and full replay are a follow-up plan.

- [ ] **Step 1: Write the failing smoke `lib/tests/replay-smoke.sh`**

```bash
#!/bin/bash
# End-to-end smoke for lib/replay.sh — stage-local replay against a
# synthetic fixture with a stubbed `codex`. Verifies:
#
#   1. Fixture inputs are staged into a real run-dir layout (.codex-scratch
#      symlinks, $RUN_DIR/{inputs,agents}, $REPO_DIR with .git).
#   2. dispatch_agent <stage> is called with the right $PROMPTS_DIR
#      (defaults to repo's prompts/) and reads from that dir.
#   3. The stubbed codex's output ends up in $RUN_DIR/agents/<stage>/output.md.
#   4. Shape assertions from `expected/<stage>.shape` are applied to the
#      stub output — pass case (deliberately written to satisfy shape).
#   5. Shape mismatch fails LOUD (return non-zero, descriptive stderr).
#
# The stubbed codex writes a fixed string to its -o target so the smoke
# is deterministic. Real LLM replay is exercised by `just replay <fixture>`
# (gated, costs $).

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR=$(mktemp -d -t replay-smoke-XXXXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# Build a synthetic fixture that's small but structurally valid.
FIX="$TMPDIR/fixtures/runs/synth"
mkdir -p "$FIX/inputs" "$FIX/agents/aggregator" "$FIX/expected"
cat > "$FIX/meta.json" <<'JSON'
{"repo":"x/y","pr_id":"x/y#1","pr_num":1,"sha":"deadbeef","branch":"b","title":"synth",
 "started_at":"2026-05-02T00:00:00Z","posted_at":"2026-05-02T00:01:00Z","status":"completed"}
JSON
echo "synthetic diff" > "$FIX/inputs/diff.patch"
echo "synthetic intent" > "$FIX/agents/intent/output.md" 2>/dev/null || \
    { mkdir -p "$FIX/agents/intent"; echo "Inferred intent: synthetic" > "$FIX/agents/intent/output.md"; }
mkdir -p "$FIX/agents/security"; echo "## [security] findings\n\n### Surveyed\n- nothing — clean" > "$FIX/agents/security/output.md"
echo "OK_OUTPUT_MARKER" > "$FIX/agents/aggregator/output.md"
cat > "$FIX/expected/aggregator.shape" <<'SHAPE'
contains REPLAY_STUB_MARKER
not_contains FORBIDDEN_TOKEN
byte_cap 500
SHAPE

# Stub codex — writes REPLAY_STUB_MARKER to the -o target.
STUB_BIN="$TMPDIR/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/codex" <<'STUB'
#!/bin/bash
# Stub codex: parse -o <path> and write a fixed marker.
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -z "$out" ] && { echo "stub-codex: -o not passed" >&2; exit 1; }
printf 'REPLAY_STUB_MARKER\nVERDICT: APPROVE\n' > "$out"
STUB
chmod +x "$STUB_BIN/codex"

# Run replay.sh.
PATH="$STUB_BIN:$PATH" \
    bash "$PROJECT_ROOT/lib/replay.sh" "$FIX" --stage aggregator
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: replay.sh exit=$RC on a passing-shape fixture"; exit 1; }
echo "  ok: stage replay against passing shape"

# Negative scenario: shape that fails.
cat > "$FIX/expected/aggregator.shape" <<'SHAPE'
contains FORBIDDEN_TOKEN
SHAPE
PATH="$STUB_BIN:$PATH" \
    bash "$PROJECT_ROOT/lib/replay.sh" "$FIX" --stage aggregator 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: replay.sh returned 0 on shape that should have failed"; exit 1; }
echo "  ok: stage replay fails LOUD on shape mismatch"

# Bad fixture: missing meta.json.
BAD="$TMPDIR/fixtures/runs/bad"
mkdir -p "$BAD/inputs"
PATH="$STUB_BIN:$PATH" \
    bash "$PROJECT_ROOT/lib/replay.sh" "$BAD" --stage aggregator 2>/dev/null
RC=$?
[ "$RC" -ne 0 ] || { echo "FAIL: replay.sh returned 0 on fixture missing meta.json"; exit 1; }
echo "  ok: replay.sh refuses fixture without meta.json"

echo "ok"
```

- [ ] **Step 2: Run smoke — expect failure (replay.sh doesn't exist yet)**

```bash
bash lib/tests/replay-smoke.sh
```

Expected: `lib/replay.sh: No such file or directory` — exit non-zero.

- [ ] **Step 3: Implement `lib/replay.sh`**

```bash
#!/bin/bash
# Replay a frozen review fixture against the current prompts.
#
# Usage:
#   lib/replay.sh <fixture-dir> --stage <name> [--prompts <dir>] [--diff]
#
#   <fixture-dir> — path to a fixture under lib/tests/fixtures/runs/
#   --stage NAME  — re-run only this stage (intent, security, ..., aggregator).
#                   Other stages' outputs come from the fixture's agents/<name>/output.md.
#   --prompts DIR — alternate prompts dir (default: repo's prompts/).
#                   Sets PROMPTS_DIR for dispatch_agent.
#   --diff        — diff the new output against the fixture's baseline.
#                   Diagnostic only; success/failure is driven by the
#                   shape file at expected/<stage>.shape.
#
# Exit codes:
#   0 — replay produced output that satisfies expected/<stage>.shape
#   1 — shape mismatch (assertion failed; stderr has details)
#   2 — fixture invalid, missing args, or staging error
#
# Cost note: one stage-replay = one codex call. Aggregator replay
# against the canonical fixture: ~$0.05.

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=replay-shape.sh
. "$PROJECT_ROOT/lib/replay-shape.sh"
# orchestrate.sh provides dispatch_agent. It needs prompt-build.sh's
# helpers in scope first.
# shellcheck source=prompt-build.sh
. "$PROJECT_ROOT/lib/prompt-build.sh"
# shellcheck source=state-io.sh
. "$PROJECT_ROOT/lib/state-io.sh"
# shellcheck source=orchestrate.sh
. "$PROJECT_ROOT/lib/orchestrate.sh"

FIXTURE=""
STAGE=""
PROMPTS_DIR_ARG=""
SHOW_DIFF=""

while [ $# -gt 0 ]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --prompts) PROMPTS_DIR_ARG="$2"; shift 2 ;;
        --diff) SHOW_DIFF=1; shift ;;
        -*) echo "replay: unknown flag $1" >&2; exit 2 ;;
        *) FIXTURE="$1"; shift ;;
    esac
done

if [ -z "$FIXTURE" ] || [ -z "$STAGE" ]; then
    echo "Usage: $0 <fixture-dir> --stage <name> [--prompts DIR] [--diff]" >&2
    exit 2
fi
if [ ! -f "$FIXTURE/meta.json" ]; then
    echo "replay: fixture missing meta.json: $FIXTURE" >&2
    exit 2
fi
if [ ! -f "$FIXTURE/expected/${STAGE}.shape" ]; then
    echo "replay: fixture has no expected/${STAGE}.shape — nothing to fence" >&2
    exit 2
fi

# Default PROMPTS_DIR to the repo's prompts/.
if [ -z "$PROMPTS_DIR_ARG" ]; then
    PROMPTS_DIR_ARG="$PROJECT_ROOT/prompts"
fi
export PROMPTS_DIR="$PROMPTS_DIR_ARG"

# Stage the fixture into a tmp run-dir. dispatch_agent reads $RUN_DIR
# and $REPO_DIR; we set both so the stage runs against the fixture's
# inputs and writes into our tmp area (not the fixture itself).
WORK=$(mktemp -d -t replay-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export RUN_DIR="$WORK/run"
export REPO_DIR="$WORK/repo"
mkdir -p "$RUN_DIR/inputs" "$RUN_DIR/agents" "$REPO_DIR"
# REPO_DIR must look like a git repo for run-specialist.sh's check.
git -C "$REPO_DIR" init --quiet

# Copy fixture inputs.
cp -r "$FIXTURE/inputs/." "$RUN_DIR/inputs/"

# Stage upstream agents' outputs as inputs for the requested stage.
# Aggregator reads .codex-scratch/specialists/<name>.md + critic.md +
# inferred-intent.md; orchestrate.sh's run_specialist_pipeline sets up
# those symlinks. We mirror the symlink layout here so dispatch_agent
# sees the same surface.
mkdir -p "$REPO_DIR/.codex-scratch" "$REPO_DIR/.codex-scratch/specialists"
for agent_dir in "$FIXTURE"/agents/*/; do
    name=$(basename "$agent_dir")
    if [ -f "$agent_dir/output.md" ]; then
        mkdir -p "$RUN_DIR/agents/$name"
        cp "$agent_dir/output.md" "$RUN_DIR/agents/$name/output.md"
    fi
done
# Wire .codex-scratch symlinks pointing at the staged agent outputs.
ln -sfn "$RUN_DIR/agents/intent/output.md" "$REPO_DIR/.codex-scratch/inferred-intent.md" 2>/dev/null || true
ln -sfn "$RUN_DIR/agents/critic/output.md" "$REPO_DIR/.codex-scratch/critic.md" 2>/dev/null || true
for spec in security data-integrity architecture simplification tests shape performance consumers; do
    if [ -f "$RUN_DIR/agents/$spec/output.md" ]; then
        ln -sfn "$RUN_DIR/agents/$spec/output.md" "$REPO_DIR/.codex-scratch/specialists/$spec.md"
    fi
done
# Also link inputs/* into .codex-scratch (the prompts cite these paths).
for f in "$RUN_DIR/inputs"/*.md "$RUN_DIR/inputs"/*.patch; do
    [ -f "$f" ] || continue
    ln -sfn "$f" "$REPO_DIR/.codex-scratch/$(basename "$f")"
done

# PR placeholders from meta.json.
PR_ID=$(jq -r '.pr_id' "$FIXTURE/meta.json")
PR_NUM=$(jq -r '.pr_num' "$FIXTURE/meta.json")
PR_TITLE=$(jq -r '.title' "$FIXTURE/meta.json")
PR_URL="https://github.com/$(jq -r '.repo' "$FIXTURE/meta.json")/pull/$PR_NUM"
PR_AUTHOR=$(jq -r '.author // "unknown"' "$FIXTURE/meta.json")
export PR_ID PR_NUM PR_TITLE PR_URL PR_AUTHOR
export _LIB_DIR="$PROJECT_ROOT/lib"

# Wipe the staged stage's output so the replay produces a fresh one.
rm -rf "$RUN_DIR/agents/$STAGE"
mkdir -p "$RUN_DIR/agents/$STAGE"

# Replay.
echo "replay: $FIXTURE stage=$STAGE prompts=$PROMPTS_DIR" >&2
dispatch_agent "$STAGE"
DISPATCH_RC=$?
if [ "$DISPATCH_RC" -ne 0 ]; then
    echo "replay: dispatch_agent exit=$DISPATCH_RC" >&2
    exit 2
fi

OUT_FILE="$RUN_DIR/agents/$STAGE/output.md"
if [ ! -s "$OUT_FILE" ]; then
    echo "replay: empty output at $OUT_FILE" >&2
    exit 2
fi

# Optional diff against baseline.
if [ -n "$SHOW_DIFF" ]; then
    BASELINE="$FIXTURE/agents/$STAGE/output.md"
    if [ -f "$BASELINE" ]; then
        echo "--- baseline ($BASELINE)" >&2
        echo "+++ replay ($OUT_FILE)" >&2
        diff -u "$BASELINE" "$OUT_FILE" >&2 || true
    fi
fi

# Apply shape assertions.
BODY=$(cat "$OUT_FILE")
run_shape_file "$BODY" "$FIXTURE/expected/${STAGE}.shape"
SHAPE_RC=$?
if [ "$SHAPE_RC" -eq 0 ]; then
    echo "replay: PASS — shape assertions satisfied"
else
    echo "replay: FAIL — shape mismatch (see stderr above)" >&2
fi
exit "$SHAPE_RC"
```

- [ ] **Step 4: Make replay.sh executable**

```bash
chmod +x lib/replay.sh
```

- [ ] **Step 5: Run the smoke — expect pass**

```bash
bash lib/tests/replay-smoke.sh
```

Expected: each `ok:` line prints; exit 0. Verifies replay.sh stages the fixture, calls dispatch_agent, applies shape, and fails LOUD on mismatch.

- [ ] **Step 6: Wire smoke into justfile (right after replay-shape smoke)**

In `justfile`, after `bash lib/tests/replay-shape-smoke.sh`, add:

```
    echo "=== replay smoke ==="
    bash lib/tests/replay-smoke.sh
```

Run `just test`. Expected: all 30 smokes pass.

- [ ] **Step 7: Commit**

```bash
git add lib/replay.sh lib/tests/replay-smoke.sh justfile
git commit -m "$(cat <<'EOF'
feat(replay): stage-local replay harness

lib/replay.sh stages a frozen fixture into a tmp run-dir, calls
dispatch_agent for the requested stage with $PROMPTS_DIR pointing at
either the working tree's prompts/ or an alternate, and applies
shape assertions. Smoke uses a stubbed codex for hermeticity.

Cost: one stage-replay ≈ one codex call (~$0.05 for aggregator).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Add `just replay` recipes

**Files:**
- Modify: `justfile`

- [ ] **Step 1: Add the recipes to `justfile`**

After the existing `test:` recipe block (around line 134), append:

```
# Replay one fixture's stage against the working-tree prompts.
# Costs one codex call (~$0.05 for aggregator). Not part of `just test`
# (the pre-merge gate stays free); run this explicitly when iterating
# on prompts.
#
# Usage: just replay 552-r11-stuck-record aggregator
replay FIXTURE STAGE:
    bash lib/replay.sh lib/tests/fixtures/runs/{{FIXTURE}} --stage {{STAGE}}

# Replay every fixture's `aggregator.shape` against the working-tree
# prompts. ~$0.05 × N fixtures. Useful before merging a prompt edit;
# costs real money — gate behind explicit invocation, not `just test`.
replay-all:
    #!/usr/bin/env bash
    set -euo pipefail
    failures=0
    for fixture_dir in lib/tests/fixtures/runs/*/; do
        [ -d "$fixture_dir" ] || continue
        [ -f "$fixture_dir/expected/aggregator.shape" ] || continue
        name=$(basename "$fixture_dir")
        echo "=== replay $name aggregator ==="
        if ! bash lib/replay.sh "$fixture_dir" --stage aggregator; then
            failures=$((failures + 1))
        fi
    done
    if [ "$failures" -gt 0 ]; then
        echo "$failures fixture(s) failed shape assertions" >&2
        exit 1
    fi
    echo "all replays passed"
```

- [ ] **Step 2: Sanity-check the recipe parses**

```bash
just --list | grep replay
```

Expected: `replay` and `replay-all` listed.

- [ ] **Step 3: Commit**

```bash
git add justfile
git commit -m "$(cat <<'EOF'
feat(replay): just recipes (replay <fixture> <stage>, replay-all)

Costs real money (codex calls), so explicitly NOT in `just test`.
Use before merging a prompt edit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Consolidate `anti-bloat-contract-smoke` + `momentum-wire-smoke` into `prompt-contracts-smoke`

**Files:**
- Create: `lib/tests/prompt-contracts-smoke.sh`
- Delete: `lib/tests/anti-bloat-contract-smoke.sh`
- Delete: `lib/tests/momentum-wire-smoke.sh`
- Modify: `justfile` (collapse two entries to one)

**Why:** Both are token-presence `assert_grep` checks against tracked files. Same shape, two files, two justfile entries — exactly the boilerplate `~/.claude/CLAUDE.md` says to consolidate. As of post-PR-#45 main, `anti-bloat-contract-smoke.sh` is 226 lines with ~38 assertions; `momentum-wire-smoke.sh` is 49 lines with 3. Consolidation gives a single `prompt-contracts-smoke.sh` and one justfile entry. Net −49 LoC of test code, no behavior loss; replay covers the LLM-behavior side, this consolidated smoke covers the cheaper "you renamed a token; the OTHER side got out of sync" omission class.

**Approach:** Concatenate, dedupe headers — don't rewrite the assertion list from memory. Every assertion in the current main must be preserved verbatim; the assertions are dense (PR #45's K-decay thresholds, severe-bug carve-out, paired-token uniqueness fences) and rewriting would risk silently dropping fences.

- [ ] **Step 1: Read both source files in full**

```bash
cat lib/tests/anti-bloat-contract-smoke.sh
cat lib/tests/momentum-wire-smoke.sh
```

Note: both files define their own `assert_grep`. The consolidated file uses one shared definition. Both files use the same `cd` to project root pattern.

- [ ] **Step 2: Write `lib/tests/prompt-contracts-smoke.sh` by merging the two**

The merged file is `anti-bloat-contract-smoke.sh` verbatim with the momentum-wire assertions appended after the `# ----- carry-forward stress-test contract (PR#45) -----` block but before the final `echo "  PASS"`.

```bash
#!/bin/bash
# Smoke: cross-file prompt + orchestrator-wire contract sync.
#
# Cheap (millisec) token-presence checks against tracked files.
# Catches "renamed token on one side, forgot the other" omission class.
# Behavior-side tests live in lib/replay.sh + lib/tests/fixtures/runs/.
#
# Folded from anti-bloat-contract-smoke.sh + momentum-wire-smoke.sh —
# both used the same assert_grep shape against tracked files, no
# behavior loss in the merge. The behavior-side checks (does the
# pipeline actually USE these tokens correctly?) belong to the replay
# harness; this stays as the cheap "did the prompt and the wire
# survive the rename?" tier.
#
# This file's ASSERTIONS ARE THE CONTRACT — when you remove an
# assertion, you remove a token fence. Don't drop assertions to "clean
# up"; the K-decay paired tokens, the negative fences, and the
# specialist-registration tokens are all load-bearing and were each
# written in response to a specific regression. See PR #25, PR #38,
# PR #42, PR #45 review history if uncertain about a specific fence.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

assert_grep() {
    local label="$1" pattern="$2" file="$3"
    grep -qF -- "$pattern" "$file" || { echo "FAIL: $label"; exit 1; }
}

# ====================================================================
# Section 1: prompt-contract sync (formerly anti-bloat-contract-smoke.sh)
# ====================================================================

echo "  asserting Rule 8 (Remedy-cost framing) in common-header.md..."
assert_grep "Rule 8 missing from prompts/common-header.md" \
    "Remedy-cost framing" prompts/common-header.md

echo "  asserting voice-posture pointer in common-header.md..."
assert_grep "common-header.md should reference Broken-Glass Test" \
    "Broken-Glass Test" prompts/common-header.md
assert_grep "common-header.md should mandate cost-naming" \
    "adds complexity and makes PMF iteration harder" prompts/common-header.md
assert_grep "common-header.md should reference review-priority.md scratch input" \
    "review-priority.md" prompts/common-header.md

echo "  asserting REMEDY-BLOAT bucket in critic.md..."
assert_grep "REMEDY-BLOAT bucket missing from prompts/critic.md" \
    "REMEDY-BLOAT" prompts/critic.md

echo "  asserting REFRAME-AS-QUESTION bucket in critic.md..."
assert_grep "REFRAME-AS-QUESTION bucket missing from prompts/critic.md" \
    "REFRAME-AS-QUESTION" prompts/critic.md

echo "  asserting voice-posture pointer in critic.md..."
assert_grep "critic.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/critic.md

echo "  asserting Pre-PMF lens reference in critic.md..."
assert_grep "critic.md should reference loc-trend.md (Pre-PMF lens)" \
    "loc-trend.md" prompts/critic.md

# ----- Phase 1: decline-history awareness + remedy-LOC + calibration ----
echo "  asserting decline-history input in critic.md..."
assert_grep "critic.md should reference decline-history.md" \
    "decline-history.md" prompts/critic.md

echo "  asserting remedy-LOC estimate contract in critic.md..."
assert_grep "critic.md should fence Estimated remedy LOC token" \
    "Estimated remedy LOC" prompts/critic.md

echo "  asserting calibration-question contract in critic.md..."
assert_grep "critic.md should fence Calibration questions for go-deep token" \
    "Calibration questions for go-deep" prompts/critic.md

# ----- Phase 2: go-deep tech-lead specialist + aggregator integration ----
echo "  asserting decline-history input in aggregator.md..."
assert_grep "aggregator.md should reference decline-history.md" \
    "decline-history.md" prompts/aggregator.md

echo "  asserting layered-file note in aggregator.md..."
assert_grep "aggregator.md should describe layered specialist files" \
    "layered specialist files" prompts/aggregator.md

echo "  asserting go-deep recommendation handlers in aggregator.md..."
assert_grep "aggregator.md should reference SIMPLIFY-WITH-PATTERN go-deep recommendation" \
    "SIMPLIFY-WITH-PATTERN" prompts/aggregator.md

echo "  asserting go-deep prompt exists with 20-LOC threshold reference..."
assert_grep "go-deep.md should fence the 20-LOC remedy threshold reference" \
    "20-LOC remedy threshold" prompts/go-deep.md
assert_grep "go-deep.md should fence the four recommendation tokens" \
    "KEEP | SIMPLIFY-WITH-PATTERN | DROP | REFRAME" prompts/go-deep.md

echo "  asserting REMEDY-BLOAT handler in aggregator.md..."
assert_grep "REMEDY-BLOAT handler missing from prompts/aggregator.md" \
    "REMEDY-BLOAT" prompts/aggregator.md

echo "  asserting aggregator handler accepts branch-negative alternatives..."
assert_grep "aggregator.md should mention branch-negative alternative" \
    "branch-negative" prompts/aggregator.md

# ----- new specialist + scratch wiring (PR#25) ----------------------
echo "  asserting performance specialist registered in critic.md..."
assert_grep "critic.md should reference performance specialist" \
    "specialists/performance.md" prompts/critic.md

echo "  asserting consumers specialist registered in critic.md..."
assert_grep "critic.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/critic.md

echo "  asserting performance specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference performance specialist" \
    "specialists/performance.md" prompts/aggregator.md

echo "  asserting consumers specialist registered in aggregator.md..."
assert_grep "aggregator.md should reference consumers specialist" \
    "specialists/consumers.md" prompts/aggregator.md

echo "  asserting common-header documents dead-code.md scratch..."
assert_grep "common-header.md should document dead-code.md" \
    "dead-code.md" prompts/common-header.md

echo "  asserting voice-posture pointer in aggregator.md..."
assert_grep "aggregator.md should cite Broken-Glass Test" \
    "Broken-Glass Test" prompts/aggregator.md
echo "  asserting Open Questions Q: format in aggregator.md..."
assert_grep "aggregator.md should describe Q: question template" \
    "**Q:" prompts/aggregator.md
echo "  asserting re-review loop-breaker (Path 2) in aggregator.md..."
assert_grep "aggregator.md should reference loc-trend.md trigger" \
    "loc-trend.md" prompts/aggregator.md
assert_grep "aggregator.md should reference momentum specialist output" \
    "momentum.md" prompts/aggregator.md

echo "  asserting Path 2 trigger phrases in aggregator.md..."
assert_grep "aggregator.md should fence the 1.5× LOC threshold" \
    "1.5×" prompts/aggregator.md
assert_grep "aggregator.md should fence the 2+ prior rounds threshold" \
    "2+ prior rounds" prompts/aggregator.md
assert_grep "aggregator.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/aggregator.md

echo "  asserting aggregator.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/aggregator.md; then
    echo "FAIL: aggregator.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

echo "  asserting Pre-PMF lens trigger phrases in critic.md..."
assert_grep "critic.md should fence prior-rounds-only language ('any prior round')" \
    "any prior round" prompts/critic.md

echo "  asserting critic.md has no 'this round or any prior round' regression..."
if grep -qF "this round or any prior round" prompts/critic.md; then
    echo "FAIL: critic.md regressed to old 'this round or any prior round' wording"
    exit 1
fi

# ----- carry-forward stress-test contract (PR#45) -----------------------
echo "  asserting carry-forward stress-test pass in critic.md..."
assert_grep "critic.md should fence Carry-forward stress-test pass" \
    "Carry-forward stress-test" prompts/critic.md
assert_grep "critic.md should fence the Carried-forward output section" \
    "Carried-forward findings" prompts/critic.md
assert_grep "critic.md should fence engagement-K signal" \
    "Engagement signal" prompts/critic.md

echo "  asserting K-decay thresholds in critic.md..."
assert_grep "critic.md should fence K >= 3 -> REFRAME-AS-QUESTION decay rule" \
    "K ≥ 3 with no engagement: REFRAME-AS-QUESTION" prompts/critic.md
assert_grep "critic.md should fence K >= 5 -> REMEDY-BLOAT decay rule" \
    "K ≥ 5 with no engagement: REMEDY-BLOAT" prompts/critic.md

echo "  asserting severe-bug carve-out for K-decay in critic.md..."
assert_grep "critic.md should carve severe-bug findings out of K-decay" \
    "Severe-bug carve-out for K-decay" prompts/critic.md
assert_grep "critic.md should key carve-out on failing-path text not specialist tag" \
    "Key on the cited failing-path text" prompts/critic.md
assert_grep "critic.md severe-bug carve-out should cover data-loss class" \
    "data loss" prompts/critic.md

echo "  asserting aggregator applies critic carry-forward verdicts..."
assert_grep "aggregator.md should reference critic's Carried-forward findings section" \
    "Carried-forward findings" prompts/aggregator.md
assert_grep "aggregator.md should defer carry-forward verdicts to the step-1 table" \
    "same step-1 verdict table below" prompts/aggregator.md
assert_grep "aggregator.md should fence the K >= 3 fallback to REFRAME-AS-QUESTION on unchanged code" \
    "K ≥ 3 rounds without engagement" prompts/aggregator.md

# ====================================================================
# Section 2: orchestrator wiring (formerly momentum-wire-smoke.sh)
# ====================================================================

ORCHESTRATE=lib/orchestrate.sh

echo "  asserting momentum.md invocation in orchestrate.sh..."
assert_grep "orchestrate.sh missing momentum.md reference" \
    "momentum.md" "$ORCHESTRATE"

echo "  asserting momentum gate on previous-review.md..."
assert_grep "orchestrate.sh missing momentum gate (\$RUN_DIR/inputs/previous-review.md)" \
    'if [ -s "$RUN_DIR/inputs/previous-review.md" ]' "$ORCHESTRATE"

echo "  asserting momentum is dispatched..."
assert_grep "orchestrate.sh missing dispatch_agent momentum call" \
    'dispatch_agent momentum' "$ORCHESTRATE"

echo "  PASS"
```

- [ ] **Step 3: Verify the new smoke passes**

```bash
bash lib/tests/prompt-contracts-smoke.sh
```

Expected: each `asserting:` line prints, final `ok` prints; exit 0.

- [ ] **Step 4: Verify the new smoke FAILS LOUD if a token gets removed**

Temporarily remove the `REMEDY-BLOAT` token from `prompts/critic.md` and rerun the smoke. It must fail.

```bash
sed -i.bak 's/REMEDY-BLOAT/REMEDY_GONE/g' prompts/critic.md
bash lib/tests/prompt-contracts-smoke.sh; echo "exit=$?"
mv prompts/critic.md.bak prompts/critic.md
```

Expected: `FAIL: REMEDY-BLOAT missing from prompts/critic.md`, `exit=1`. Then the restore + a final clean run prints `ok`.

```bash
bash lib/tests/prompt-contracts-smoke.sh
```

- [ ] **Step 5: Delete the two folded files**

```bash
git rm lib/tests/anti-bloat-contract-smoke.sh lib/tests/momentum-wire-smoke.sh
```

- [ ] **Step 6: Update `justfile`** — collapse two entries to one

In `justfile`, find the lines:

```
    echo "=== anti-bloat contract smoke test ==="
    bash lib/tests/anti-bloat-contract-smoke.sh

    echo ""
    echo "=== loc-trend smoke ==="
    bash lib/tests/loc-trend-smoke.sh

    echo ""
    echo "=== momentum-wire smoke ==="
    bash lib/tests/momentum-wire-smoke.sh
```

Replace with:

```
    echo "=== prompt-contracts smoke ==="
    bash lib/tests/prompt-contracts-smoke.sh

    echo ""
    echo "=== loc-trend smoke ==="
    bash lib/tests/loc-trend-smoke.sh
```

(The `momentum-wire` block is removed; `anti-bloat-contract` is renamed to `prompt-contracts`.)

- [ ] **Step 7: Run full pre-merge gate**

```bash
just test
```

Expected: 28 smokes pass (was 29 + 2 new from prior tasks − 2 deleted = 29 unique, but the count varies by what's actually in `justfile`). Output ends `ok` on every smoke; exit 0.

- [ ] **Step 8: Commit**

```bash
git add lib/tests/prompt-contracts-smoke.sh justfile
git commit -m "$(cat <<'EOF'
refactor(tests): consolidate anti-bloat + momentum-wire token-presence smokes

Both used assert_grep against tracked files for cross-file token sync.
Folded into one prompt-contracts-smoke.sh — same coverage, −75 LoC of
test code, justfile collapses 2 entries to 1. Behavior-side checks are
the replay harness's job; this stays as the cheap token-grep tier.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Stub the LLM-as-a-judge rubric format (no judge invocation yet)

**Files:**
- Create: `lib/tests/fixtures/judge-rubric.md`

**Why:** the user explicitly said "eventually this will be used with llm-as-a-judge to iterate and improve the prompts." Define the rubric format file now (one task, no LLM call) so the seam exists when the judge work lands. Defer implementation of the actual judge invocation — premature.

- [ ] **Step 1: Write `lib/tests/fixtures/judge-rubric.md`**

```markdown
# LLM-as-a-judge rubric (placeholder)

This file is the format spec for a future judge step that will compare
a replay's output against the fixture's baseline output and emit a
verdict: `improved | regressed | neutral` with one-line rationale.

## Status

Not yet implemented. `lib/replay.sh` exits on shape-assertion result;
no judge call is made today.

## Planned invocation

```
lib/replay.sh <fixture> --stage aggregator --judge
```

The `--judge` flag, when implemented, will:
1. Run the stage replay as today.
2. Pass `(baseline, replay_output, judge-rubric.md)` to a separate
   codex call.
3. Parse the judge's verdict + rationale.
4. Print verdict to stdout, rationale to stderr.
5. Exit 0 only if shape assertions pass AND judge says improved/neutral.

## Rubric format (forward-compatible)

```yaml
# judge-rubric.md is read as YAML front-matter + criteria list.
---
goal: improve aggregator output quality on small-increment re-reviews
criteria:
  - id: no_hallucinated_sections
    description: Replay must not invent sections not present in baseline (e.g. "Pre-merge auto-checks").
    weight: 1.0
  - id: no_carry_forward_fatigue
    description: After 3+ rounds with no author engagement, carried-forward findings should downgrade or collapse to one-liners.
    weight: 1.0
  - id: byte_economy_on_small_increments
    description: When `inputs/diff.patch` is < 200 lines and < 3 NEW findings, body should fit under 1500 bytes.
    weight: 0.7
  - id: signal_preservation
    description: New legitimate findings (e.g. dirty-ref blocking on R11) must not be dropped in service of brevity.
    weight: 1.0
verdict_classes:
  - improved
  - regressed
  - neutral
---

# Judge prompt (rendered into the codex call)

You are evaluating a knightwatch-reviewer pipeline change. Compare the
replay output against the baseline against the criteria above. Output:

```
verdict: <improved|regressed|neutral>
rationale: <one sentence per criterion>
```

Be strict on `signal_preservation` — losing a legitimate finding is a
regression even if everything else improves.
```
```

- [ ] **Step 2: Note the file in `lib/tests/fixtures/runs/README.md`**

Append at the end of `lib/tests/fixtures/runs/README.md`:

```markdown

## LLM-as-a-judge

`lib/tests/fixtures/judge-rubric.md` defines the placeholder rubric
format. Not yet wired — `replay.sh --judge` is a future flag. See that
file for the planned shape.
```

- [ ] **Step 3: Commit**

```bash
git add lib/tests/fixtures/judge-rubric.md lib/tests/fixtures/runs/README.md
git commit -m "$(cat <<'EOF'
docs(replay): stub LLM-as-a-judge rubric format

Defines the format and placeholder criteria for a future --judge flag.
No invocation yet — premature. The seam exists so the judge work can
land without re-litigating the rubric format.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (run before handoff)

- [ ] Every task names exact files and shows actual code; no "TBD" or "implement appropriate handling".
- [ ] Type/identifier consistency: `assert_contains` / `assert_not_contains` / `assert_byte_cap` / `assert_severity_count` / `run_shape_file` are spelled the same in `lib/replay-shape.sh`, `lib/tests/replay-shape-smoke.sh`, fixture `expected/*.shape`, and `lib/replay.sh`.
- [ ] `PROMPTS_DIR` env var name is consistent across `lib/prompt-build.sh`, `lib/orchestrate.sh`, `lib/replay.sh`, and the smoke that fences the override.
- [ ] Fixture name `552-r11-stuck-record` is consistent across the freeze command, the directory it lands at, the README example, and the `just replay` example.
- [ ] No new test calcifies LLM prose — every shape assertion is loose (token presence/byte cap/severity count). Per `~/.claude/CODING_STANDARDS.md` line 54: "Tests calcify too — a test for a scenario that doesn't occur preserves a contract that may have been wrong."
- [ ] `just test` stays cheap (no LLM calls); `just replay` is the explicit-cost knob.
- [ ] Test consolidation only collapses files that share assertion shape; no seam tests deleted.
