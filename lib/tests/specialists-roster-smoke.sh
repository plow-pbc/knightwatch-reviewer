#!/usr/bin/env bash
# Smoke fence for the BAKEOFF_SPECIALISTS python3 import in
# lib/review-one-pr.sh. If lib/pipeline.py::SPECIALISTS ever changes
# shape (renamed, becomes a list, returns a single string, etc.), the
# write-time roster marker would silently break — this smoke catches
# the breakage at test time, not at deploy time.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "  specialists-roster: python3 import returns non-empty comma-separated list..."
ROSTER=$(python3 -c "import sys; sys.path.insert(0, '$REPO_ROOT'); from lib.pipeline import SPECIALISTS; print(','.join(list(SPECIALISTS) + ['aggregator']))")
[ -n "$ROSTER" ] || { echo "FAIL: roster is empty"; exit 1; }

echo "  specialists-roster: contains aggregator (sentinel for the +['aggregator'] suffix)..."
case ",$ROSTER," in
    *,aggregator,*) ;;
    *) echo "FAIL: aggregator not in roster: '$ROSTER'"; exit 1 ;;
esac

echo "  specialists-roster: contains tests + security (sentinels for the imported tuple)..."
case ",$ROSTER," in
    *,tests,*) ;;
    *) echo "FAIL: tests not in roster: '$ROSTER'"; exit 1 ;;
esac
case ",$ROSTER," in
    *,security,*) ;;
    *) echo "FAIL: security not in roster: '$ROSTER'"; exit 1 ;;
esac

# Experiment-defining membership (PR #79: swap performance for architecture-v2).
# Pins THIS PR's bakeoff A/B membership so a future cleanup can't silently
# drop architecture-v2 or re-introduce performance without failing this smoke.
echo "  specialists-roster: contains architecture-v2 (PR #79 A/B specialist)..."
case ",$ROSTER," in
    *,architecture-v2,*) ;;
    *) echo "FAIL: architecture-v2 not in roster: '$ROSTER'"; exit 1 ;;
esac
echo "  specialists-roster: does NOT contain performance (dropped in PR #79)..."
case ",$ROSTER," in
    *,performance,*) echo "FAIL: performance back in roster: '$ROSTER'"; exit 1 ;;
    *) ;;
esac

echo "  specialists-roster: shape is comma-separated (no spaces, no leading/trailing comma)..."
[[ "$ROSTER" != *" "* ]] || { echo "FAIL: roster has spaces: '$ROSTER'"; exit 1; }
[[ "$ROSTER" != ,* ]] || { echo "FAIL: leading comma: '$ROSTER'"; exit 1; }
[[ "$ROSTER" != *, ]] || { echo "FAIL: trailing comma: '$ROSTER'"; exit 1; }

echo "PASS"
