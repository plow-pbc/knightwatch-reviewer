#!/usr/bin/env bash
# Deterministic cross-repo prior-art: grep the materialized .siblings/ tree for
# identifiers this diff defines or changes. Zero LLM tokens. Two sections —
# "new symbols" answers "does a sibling already have this shape to extend?";
# "changed/removed symbols" answers "which sibling callers does this break?".
# Output is appended to prior-art.md after the kid section; shape,
# architecture-refined, consumers and the aggregator read it (prompts/).
#
# Identifier extraction is language-agnostic on purpose: definition-shaped
# lines plus SCREAMING_CASE constants and --long-flags. Precision comes from
# the sibling grep (a name with zero hits is dropped), not from parsing.

PRIOR_ART_MAX_SYMBOLS="${PRIOR_ART_MAX_SYMBOLS:-40}"
PRIOR_ART_MAX_HITS="${PRIOR_ART_MAX_HITS:-5}"
PRIOR_ART_MAX_BYTES="${PRIOR_ART_MAX_BYTES:-24576}"

# _prior_art_symbols PREFIX DIFF — identifiers defined on diff lines starting
# with PREFIX ('+' added, '-' removed), one per line, unique, ≥4 chars.
_prior_art_symbols() {
    local prefix="$1"
    printf '%s\n' "$2" \
      | grep -E "^[$prefix][^$prefix]" | cut -c2- \
      | sed -nE \
          -e 's/.*(^|[^A-Za-z0-9_])(def|class|function|func|fn|struct|type|interface|enum|const|let|var|val|proc)[[:space:]]+([A-Za-z_][A-Za-z0-9_]{3,}).*/\3/p' \
          -e 's/^[[:space:]]*([A-Z][A-Z0-9_]{3,})[[:space:]]*=.*/\1/p' \
          -e 's/.*(--[a-z][a-z0-9-]{3,}).*/\1/p' \
      | grep -vxE 'self|this|None|True|False|null|true|false|return|import|from|main|test|init' \
      | awk '!seen[$0]++'
}

# _prior_art_grep SYMBOL WORKDIR SELF_SLUG — up to PRIOR_ART_MAX_HITS lines
# "- owner/repo/path:line: text", excluding the PR's own repo, .git, lockfiles.
_prior_art_grep() {
    local sym="$1" root="$2/.siblings" self="$3" line rel text
    [ -d "$root" ] || return 0
    grep -rnwF --exclude-dir=.git --exclude-dir=node_modules --exclude='*.lock' --exclude=package-lock.json \
         -- "$sym" "$root" 2>/dev/null \
      | grep -vF -- "$root/$self/" \
      | head -n "$PRIOR_ART_MAX_HITS" \
      | while IFS= read -r line; do
            rel="${line#"$root/"}"                 # owner/repo/path:NN:text
            text="${rel#*:}"; text="${text#*:}"    # drop path and line number
            text="${text#"${text%%[![:space:]]*}"}"
            printf -- '- %s: %s\n' "${rel%%:"$text"}" "$text" | cut -c1-200
        done
}

# sibling_prior_art DIFF WORKDIR SELF_SLUG — markdown on stdout, empty when nothing hit.
sibling_prior_art() {
    local diff="$1" workdir="$2" self="$3"
    local out="" count=0 sym hits section body prefix title removed
    removed=$(_prior_art_symbols '-' "$diff")
    for section in new changed; do
        body=""; prefix='+'; title='## Sibling prior art — new symbols'
        [ "$section" = changed ] && { prefix='-'; title='## Sibling references — changed/removed symbols'; }
        while IFS= read -r sym; do
            [ -n "$sym" ] || continue
            # A symbol on both sides was changed, not introduced: one section, the right one.
            [ "$section" = new ] && printf '%s\n' "$removed" | grep -qxF -- "$sym" && continue
            [ "$count" -ge "$PRIOR_ART_MAX_SYMBOLS" ] && break
            hits=$(_prior_art_grep "$sym" "$workdir" "$self")
            [ -n "$hits" ] || continue
            count=$((count + 1))
            body+="### $sym"$'\n'"$hits"$'\n\n'
        done < <(_prior_art_symbols "$prefix" "$diff")
        [ -n "$body" ] && out+="$title"$'\n\n'"$body"
    done
    printf '%s' "$out" | head -c "$PRIOR_ART_MAX_BYTES"
}
