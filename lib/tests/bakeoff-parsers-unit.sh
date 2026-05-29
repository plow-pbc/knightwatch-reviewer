#!/usr/bin/env bash
# Unit tests for the lib/bakeoff-parsers.sh stdin parsers — roster marker,
# /<prefix>-props, /<prefix>-critique. Pure functions; no GH/file I/O.
# Pin the prefix to the default ("srosro") so test bodies match the
# fixture command literals regardless of caller env.
set -euo pipefail
export BOT_CMD_PREFIX=srosro
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../bakeoff-parsers.sh"
FIX="$HERE/fixtures/specialist-bakeoff"

echo "=== bakeoff-parsers unit tests ==="

echo "  extract_roster_marker: comma-separated list parses to one specialist per line..."
OUT=$(extract_roster_marker < "$FIX/review-with-roster-marker.md" | sort | paste -sd, -)
[ "$OUT" = "aggregator,security,shape,tests" ] || { echo "FAIL: roster: $OUT"; exit 1; }

echo "  extract_roster_marker: missing marker emits nothing..."
NO_MARKER=$(printf '<!-- knightwatch-reviewer:auto-post -->\n\nno roster here\n' | extract_roster_marker)
[ -z "$NO_MARKER" ] || { echo "FAIL: expected empty, got: $NO_MARKER"; exit 1; }

echo "  extract_props_attributions: '/srosro-props [from: tests]' → tests..."
OUT=$(printf '/srosro-props [from: tests] solid catch on the missing assertion\n' | extract_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: srosro-props: $OUT"; exit 1; }

echo "  extract_props_attributions: ignores body without /srosro-props line..."
OUT=$(printf 'just a comment with [from: tests] mention but no command\n' | extract_props_attributions)
[ -z "$OUT" ] || { echo "FAIL: srosro-props leaked: $OUT"; exit 1; }

echo "  extract_critique_attributions: '/srosro-critique [from: shape]' → shape..."
OUT=$(printf '/srosro-critique [from: shape] this finding misread the contract\n' | extract_critique_attributions)
[ "$OUT" = "shape" ] || { echo "FAIL: srosro-critique: $OUT"; exit 1; }

echo "  extract_critique_attributions: requires the command on the same line as the tag..."
OUT=$(printf '/srosro-critique\nseparately: [from: shape] is wrong\n' | extract_critique_attributions)
[ -z "$OUT" ] || { echo "FAIL: cross-line attribution leaked: $OUT"; exit 1; }

echo "  extract_props_attributions: prose-mentioned [from: X] after command does NOT mis-attribute..."
OUT=$(printf '/srosro-props [from: tests] solid catch — way better than [from: shape] would have been\n' | extract_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: prose [from:] leaked: $OUT"; exit 1; }

echo "  extract_props_attributions: same [from: X] repeated → deduped to one..."
OUT=$(printf '/srosro-props [from: tests] line one\n/srosro-props [from: tests] line two\n' | extract_props_attributions)
[ "$OUT" = "tests" ] || { echo "FAIL: dedup: $OUT"; exit 1; }

echo "  extract_roster_marker: empty specialists list emits nothing..."
OUT=$(printf '<!-- knightwatch-bakeoff: specialists= -->\n' | extract_roster_marker)
[ -z "$OUT" ] || { echo "FAIL: empty roster leaked: $OUT"; exit 1; }

echo "  extract_roster_marker: tolerates extra whitespace before -->..."
OUT=$(printf '<!-- knightwatch-bakeoff: specialists=tests,shape   -->\n' | extract_roster_marker | sort | paste -sd, -)
[ "$OUT" = "shape,tests" ] || { echo "FAIL: whitespace tolerance: $OUT"; exit 1; }

echo "  probe_severity: extracts [blocking] from a probe line..."
OUT=$(printf '1. [blocking] [from: tests] missing case. Files: x.sh.\n' | probe_severity)
[ "$OUT" = "blocking" ] || { echo "FAIL: severity: $OUT"; exit 1; }

echo "  probe_severity: emits one severity per probe line for multi-line input..."
OUT=$(printf '1. [medium] [from: shape] foo.\n2. [low] [from: tests] bar.\n' | probe_severity | paste -sd, -)
[ "$OUT" = "medium,low" ] || { echo "FAIL: multi-line: $OUT"; exit 1; }

# Digit-tolerance fixtures use a synthetic `demo-v2` (not a real specialist,
# so the rename canonicalizer leaves it untouched) — these prove the name
# grammar accepts a digit-bearing name; the canonicalization block below
# separately proves the rename fold.
echo "  extract_roster_marker: accepts digit-suffixed specialist name (demo-v2)..."
OUT=$(printf '<!-- knightwatch-bakeoff: specialists=tests,demo-v2,security -->\n' \
    | extract_roster_marker | sort | paste -sd, -)
[ "$OUT" = "demo-v2,security,tests" ] || { echo "FAIL: digit name in roster: $OUT"; exit 1; }

echo "  count_attributions: accepts [from: demo-v2] in probe line..."
OUT=$(printf '1. [medium] [from: demo-v2] some finding. Files: foo.sh.\n' | count_attributions)
[ "$OUT" = "demo-v2" ] || { echo "FAIL: digit name in attribution: $OUT"; exit 1; }

echo "  extract_props_attributions: accepts /srosro-props [from: demo-v2]..."
OUT=$(printf '/srosro-props [from: demo-v2] great catch\n' | extract_props_attributions)
[ "$OUT" = "demo-v2" ] || { echo "FAIL: digit name in props: $OUT"; exit 1; }

echo "  extract_critique_attributions: accepts /srosro-critique [from: demo-v2]..."
OUT=$(printf '/srosro-critique [from: demo-v2] overreach\n' | extract_critique_attributions)
[ "$OUT" = "demo-v2" ] || { echo "FAIL: digit name in critique: $OUT"; exit 1; }

# Rename fold: historical markers still carry the pre-rename architecture-v2;
# every name-emitting parser must canonicalize it to contract-drift so a
# rewalk maps old reviews onto the renamed lane instead of re-creating a
# phantom one (see canonicalize_specialist_names in bakeoff-parsers.sh).
echo "  canonicalize: architecture-v2 → contract-drift across roster/count/props/critique..."
OUT=$(printf '<!-- knightwatch-bakeoff: specialists=architecture-v2 -->\n' | extract_roster_marker)
[ "$OUT" = "contract-drift" ] || { echo "FAIL: roster canon: $OUT"; exit 1; }
OUT=$(printf '1. [medium] [from: architecture-v2] x. Files: a.sh.\n' | count_attributions)
[ "$OUT" = "contract-drift" ] || { echo "FAIL: count canon: $OUT"; exit 1; }
OUT=$(printf '/srosro-props [from: architecture-v2] x\n' | extract_props_attributions)
[ "$OUT" = "contract-drift" ] || { echo "FAIL: props canon: $OUT"; exit 1; }
OUT=$(printf '/srosro-critique [from: architecture-v2] x\n' | extract_critique_attributions)
[ "$OUT" = "contract-drift" ] || { echo "FAIL: critique canon: $OUT"; exit 1; }

# probe_cited_paths is the Applied/Edited bakeoff scorecard parser — uniquely
# uncovered by the digit-tolerance tests above. A revert at the awk `from_re`
# site would silently break scorecard credit while the other tests stay green.
# Pin the digit-tolerance contract at this final site.
echo "  probe_cited_paths: digit-bearing specialist name (demo-v2)..."
got=$(printf '1. [medium] [from: demo-v2] [shape] Two-place policy drift between manifest pin and Dockerfile source. Files: manifests/plow-starter.yaml:8, Dockerfile:71.\n' \
    | probe_cited_paths | sort)
want=$'Dockerfile\nmanifests/plow-starter.yaml'
[ "$got" = "$want" ] || { echo "FAIL: probe_cited_paths digit-bearing [from: demo-v2]"; echo "  got: $got"; echo "  want: $want"; exit 1; }

echo "PASS"
