#!/usr/bin/env bash
# Convention seam — operator-defined review conventions, generalized.
#
# Replaces the SEED-hardcoded is_seed_repo()/seed_test_summary() (PR #151)
# with a convention-AGNOSTIC resolver driven by the operator's kwr-config
# repo. kwr ships no convention-specific literals; "SEED" is just one
# operator-supplied convention living in kwr-config, not in the engine.
#
# The operator hosts a kwr-config repo (pulled by org-sync.sh into
# $KWR_CONFIG_DIR) with:
#   config.json   { "bindings": [ {"match":{"org","slug-glob?","marker?"}, "doc"} ] }
#   conventions/  the review-posture docs each binding's `doc` points at
#   standards/    the $STANDARDS bundle (operator-owned; see resolve_standards)
#
# A binding matches a repo when the org equals the repo owner AND (if given)
# the slug-glob matches the repo name AND (if given) the marker file exists at
# the TRUSTED base ref. First match wins → its doc is the authoritative
# convention. No kwr-config configured → no binding (caller falls back to the
# repo's own .knightwatch/ then built-in defaults).
#
# Parsing split: config.json is JSON → jq (kwr already depends on jq). The
# markdown doc frontmatter is flat `key: value` → awk, mirroring
# knightwatch-config.sh's parser-light per-repo .knightwatch/ reads.

# Local cache of the pulled kwr-config repo. org-sync.sh keeps it fresh; every
# other consumer only READS it. Override via env / config.env if needed.
: "${KWR_CONFIG_DIR:=$HOME/services/kwr-config}"

# kwr_config_valid — the single "is the external kwr-config wired AND usable"
# predicate, shared by org-sync's pre-discovery gate and the worker resolver so
# "broken" means the same thing in both (no drift between three ad-hoc checks).
#   0 — KWR_CONFIG_REPO set, jq present, config.json on disk and valid JSON.
#   non-0 — unset (the open-source default) OR set-but-broken. Callers that must
#           distinguish those two check `[ -n "$KWR_CONFIG_REPO" ]` themselves
#           (unset = no-op fallback; set-but-broken = fail loud, since org-sync
#           delivers the cache before any worker runs, so a missing/malformed
#           config means the wiring is wrong).
kwr_config_valid() {
    [ -n "${KWR_CONFIG_REPO:-}" ]                              || return 1
    command -v jq >/dev/null 2>&1                              || return 1
    [ -f "$KWR_CONFIG_DIR/config.json" ]                       || return 1
    # Validate the SHAPE the consumers read, not just that it parses — a
    # parseable-but-wrong-shape config (e.g. `bindings` a string) would otherwise
    # silently drop bindings/coverage. bindings/orgs/repos are each optional but
    # MUST be arrays when present.
    jq -e '(.bindings//[]|type=="array") and (.orgs//[]|type=="array") and (.repos//[]|type=="array")' \
        "$KWR_CONFIG_DIR/config.json" >/dev/null 2>&1
}

# convention_frontmatter <doc_path> <key>
#   Echo the value of a flat `key: value` line inside the doc's leading `---`
#   frontmatter fence (surrounding quotes stripped). Empty if absent.
convention_frontmatter() {
    local doc="$1" key="$2"
    awk -v k="$key" '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { exit }
        infm {
            idx=index($0, ":")
            if (idx>0) {
                fk=substr($0,1,idx-1); gsub(/^[ \t]+|[ \t]+$/,"",fk)
                if (fk==k) {
                    v=substr($0,idx+1); gsub(/^[ \t]+|[ \t]+$/,"",v)
                    gsub(/^"|"$/,"",v)
                    print v; exit
                }
            }
        }
    ' "$doc"
}

# _config_path_safe <path> — 0 iff <path> is a regular, non-symlink file whose
# canonical path stays under $KWR_CONFIG_DIR. Guards a config.json `doc` (or a
# planted symlink) from escaping the config repo via `..`/absolute paths to stage
# root-only host files — e.g. the GH_TOKEN config.env mounted at /root/.kwr — into
# the Codex-readable scratch. Used for both binding docs and standards reads.
_config_path_safe() {
    local p="$1" real base
    [ -f "$p" ] && [ ! -L "$p" ] || return 1
    real=$(realpath -- "$p" 2>/dev/null)               || return 1
    base=$(realpath -- "$KWR_CONFIG_DIR" 2>/dev/null)  || return 1
    case "$real/" in "$base/"*) return 0 ;; *) return 1 ;; esac
}

# convention_body <doc_path>
#   Echo the doc with any leading `---` frontmatter fence stripped. A doc
#   without frontmatter is echoed verbatim.
convention_body() {
    awk '
        NR==1 && $0=="---" { infm=1; next }
        infm && $0=="---"  { infm=0; next }
        infm { next }
        { print }
    ' "$1"
}

# resolve_binding <repo_slug> <repo_dir> <base_ref>
#   stdout: absolute path to the matched convention doc.
#   exit 0 — a binding matched (doc path on stdout).
#        1 — no convention applies: kwr-config unset, or no binding matched.
#            Caller falls back to the repo's own .knightwatch/ then defaults.
#        2 — kwr-config is ACTIVE but BROKEN: config.json missing/malformed, jq
#            absent, or a matched binding's doc missing on disk. The operator
#            wired a convention layer that can't be delivered — caller fails loud
#            rather than silently reviewing convention repos as generic ones.
# Markers are read from <base_ref> (a SHA snapshotted before PR code runs), so a
# PR that adds a marker on its head can't flip detection. A git error reading a
# marker fails that binding soft (advisory staging, not a trust gate).
resolve_binding() {
    local repo_slug="$1" repo_dir="$2" base_ref="$3"
    [ -n "${KWR_CONFIG_REPO:-}" ] || return 1            # unset → no convention
    if ! kwr_config_valid; then                          # set-but-broken → fail loud
        echo "conventions: KWR_CONFIG_REPO set but config unusable (missing/malformed config.json or jq absent) — failing loud" >&2
        return 2
    fi

    local cfg="$KWR_CONFIG_DIR/config.json"
    local owner="${repo_slug%%/*}" name="${repo_slug##*/}"

    # config.json is validated parseable by kwr_config_valid above.
    local bindings
    bindings=$(jq -c '.bindings[]?' "$cfg")

    local b match_org slug_glob marker doc listing
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        match_org=$(jq -r '.match.org // ""' <<<"$b")
        [ "$match_org" = "$owner" ] || continue

        # One glob per binding (aliases are separate first-match-wins bindings).
        # Matched in [[ ]] where the RHS pattern is NOT pathname-expanded — so no
        # cwd-glob hazard, and no whitespace-split mini-language to carry.
        slug_glob=$(jq -r '.match["slug-glob"] // ""' <<<"$b")
        if [ -n "$slug_glob" ]; then
            # shellcheck disable=SC2053  — $slug_glob is a glob pattern vs $name
            [[ "$name" == $slug_glob ]] || continue
        fi

        marker=$(jq -r '.match.marker // ""' <<<"$b")
        if [ -n "$marker" ]; then
            listing=$(git -C "$repo_dir" ls-tree "$base_ref" -- "$marker" 2>/dev/null) || continue
            [ -n "$listing" ] || continue
        fi

        doc=$(jq -r '.doc // ""' <<<"$b")
        if [ -z "$doc" ]; then
            echo "conventions: binding matched $repo_slug but declares no doc — broken config, failing loud" >&2
            return 2
        fi
        if ! _config_path_safe "$KWR_CONFIG_DIR/$doc"; then
            echo "conventions: binding matched $repo_slug but doc is missing or escapes the config repo (must be a regular file under $KWR_CONFIG_DIR): $doc" >&2
            return 2
        fi
        printf '%s\n' "$KWR_CONFIG_DIR/$doc"
        return 0
    done <<<"$bindings"

    return 1
}

# stage_convention <repo_dir> <doc_path>
#   The shared write primitive — both the live worker (lib/review-one-pr.sh) and
#   operator-bench replay (lib/replay.sh) call it so convention.md is staged with
#   identical shape. Requires write_scratch (caller sources lib/scratch.sh) and a
#   set $RUN_DIR.
stage_convention() {
    write_scratch "$1" "convention.md" "$(convention_body "$2")"
}

# stage_convention_run <repo_dir> <repo_slug> <base_ref>
#   Errexit-safe one-shot resolve+stage for callers (like replay) that stage at
#   detection time under `set -euo pipefail`. On a match: stages convention.md and
#   echoes the convention's test-note (possibly empty). Returns 0 (matched), 1 (no
#   convention — caller falls back), or 2 (broken config — caller fails loud). The
#   `&& rc=0 || rc=$?` capture suppresses errexit so a rc-1 no-convention result
#   doesn't abort the run. (The worker uses resolve_binding + stage_convention
#   separately because it detects early but must write AFTER the .codex-scratch
#   reset; replay has no such reset, so it stages in one call here.)
stage_convention_run() {
    local repo_dir="$1" repo_slug="$2" base_ref="$3" doc rc
    doc=$(resolve_binding "$repo_slug" "$repo_dir" "$base_ref") && rc=0 || rc=$?
    case $rc in
        0) stage_convention "$repo_dir" "$doc"
           convention_frontmatter "$doc" "test-note"
           return 0 ;;
        *) return "$rc" ;;
    esac
}

# resolve_standards
#   Echo the $STANDARDS bundle. When an external kwr-config is active and ships
#   standards/*.md, concatenate those (sorted — name them 10-/20-/… for order).
#   Otherwise the operator's ~/.claude bundle (back-compat for the current
#   deploy, and the open-source no-config default).
resolve_standards() {
    # Uses kwr_config_valid (same predicate as resolve_binding). In the worker,
    # resolve_binding runs FIRST and aborts the review on a set-but-broken config,
    # so this only executes with a valid or unset config — set-but-broken falls to
    # ~/.claude here only if called out of that order (a safe operator-local
    # default, not wrong bytes).
    if kwr_config_valid; then
        local f any=0
        for f in "$KWR_CONFIG_DIR"/standards/*.md; do
            _config_path_safe "$f" || continue
            cat "$f"; printf '\n\n'; any=1
        done
        [ "$any" -eq 1 ] && return 0
        # valid config but no standards/ shipped → fall through to ~/.claude.
    fi
    [ -f ~/.claude/CODING_STANDARDS.md ]        && { cat ~/.claude/CODING_STANDARDS.md; printf '\n\n'; }
    [ -f ~/.claude/REVIEW_PRACTICES.md ]        && { cat ~/.claude/REVIEW_PRACTICES.md; printf '\n\n'; }
    [ -f ~/.claude/TESTING.md ]                 && { cat ~/.claude/TESTING.md; printf '\n\n'; }
    [ -f ~/.claude/COMMENT_REVIEW_MISTAKES.md ] && { printf '## Known Review Mistakes (avoid repeating these)\n'; cat ~/.claude/COMMENT_REVIEW_MISTAKES.md; }
}

# sync_kwr_config
#   Clone or fast-forward the operator's kwr-config repo into $KWR_CONFIG_DIR.
#   No-op when KWR_CONFIG_REPO is unset. Called by org-sync.sh on each tick (the
#   pull cadence). ff-only pull is non-destructive: a transient outage leaves the
#   last-good cache in place rather than blanking config. Returns non-zero on
#   clone/pull failure for the caller to log.
sync_kwr_config() {
    local _auth _cur _tmp _rc
    [ -n "${KWR_CONFIG_REPO:-}" ] || return 0
    # Clone-URL hygiene (same rule the SEED convention enforces): `git clone <url>`
    # puts the whole URL in process argv (visible via /proc + shell history) and
    # sync_kwr_config's output is captured into the persistent org-sync log, so a
    # credential-bearing URL leaks the token. Reject query/fragment, and — for
    # http/https — ANY userinfo in the authority, which covers both `user:tok@host`
    # AND the bare-token `https://ghp_xxx@host` form GitHub documents. scp-style
    # `git@host:...` and `ssh://git@host` are key-auth (not credential-in-URL), so
    # they're left alone. Auth private config repos via the git credential helper.
    case "$KWR_CONFIG_REPO" in
        *"?"*|*"#"*)
            echo "conventions: KWR_CONFIG_REPO must not contain a query/fragment (argv+log leak)" >&2
            return 1 ;;
    esac
    case "$KWR_CONFIG_REPO" in
        http://*|https://*)
            _auth="${KWR_CONFIG_REPO#*://}"; _auth="${_auth%%/*}"
            case "$_auth" in
                *@*)
                    echo "conventions: http(s) KWR_CONFIG_REPO must not embed credentials (userinfo) — use a credential helper" >&2
                    return 1 ;;
            esac ;;
    esac
    if [ -d "$KWR_CONFIG_DIR/.git" ]; then
        _cur=$(git -C "$KWR_CONFIG_DIR" remote get-url origin 2>/dev/null || echo "")
        if [ "$_cur" = "$KWR_CONFIG_REPO" ]; then
            # Same origin → ordinary ff-pull (keeps the last-good cache on a
            # transient failure rather than blanking it). `return` propagates the
            # pull's exit so the caller can WARN-and-continue.
            git -C "$KWR_CONFIG_DIR" pull --ff-only --quiet
            return
        fi
        # Different origin (operator changed KWR_CONFIG_REPO, or a stale/credential
        # origin): re-clone, but IN PLACE — the reviewer containers bind-mount this
        # dir, so an `rm -rf` + recreate would swap the dir inode and leave running
        # reviewers on the old (now-unlinked) copy until restart. Clone to a temp
        # sibling and mirror its contents in with `rsync --delete`, preserving the
        # dir inode. (A plain ff-pull can't be used here — unrelated histories — and
        # would silently keep serving the OLD repo. Re-cloning from the hygiene-
        # checked URL also drops any credential origin so it can't leak to the log.)
        _tmp="${KWR_CONFIG_DIR}.reclone.$$"
        rm -rf "$_tmp"
        if git clone --quiet "$KWR_CONFIG_REPO" "$_tmp"; then
            # --checksum, NOT the default size+mtime quick-check: a changed
            # config.json can be byte-identical in length to the old one and written
            # in the same second (e.g. two `{"orgs":[...]}` of equal length), which
            # rsync's quick-check would skip — silently keeping the old content.
            rsync -a --delete --checksum "$_tmp"/ "$KWR_CONFIG_DIR"/; _rc=$?
            rm -rf "$_tmp"
            return "$_rc"
        fi
        rm -rf "$_tmp"
        return 1
    fi
    # Fresh clone: no cache yet (no bind mount to preserve).
    mkdir -p "$(dirname "$KWR_CONFIG_DIR")"
    git clone --quiet "$KWR_CONFIG_REPO" "$KWR_CONFIG_DIR"
}
