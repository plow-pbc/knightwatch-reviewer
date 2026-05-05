#!/usr/bin/env bash
# Hermetic smoke for the bake-off parsers. No network, no LLM, no gh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_ROOT/lib/bakeoff-parsers.sh"

FIX_DIR="$REPO_ROOT/lib/tests/fixtures/specialist-bakeoff"

echo "  count_attributions: 5 probes across 4 specialists..."
got=$(count_attributions < "$FIX_DIR/review-1.md" | sort | uniq -c | awk '{print $2"="$1}' | sort)
want=$'aggregator=1\nshape=1\nsimplification=2\ntests=1'
if [ "$got" != "$want" ]; then
    echo "FAIL: count_attributions output mismatch"
    echo "got:"
    echo "$got"
    echo "want:"
    echo "$want"
    exit 1
fi

echo "PASS"
