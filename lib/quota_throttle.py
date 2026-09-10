#!/usr/bin/env python3
"""Preemptive weekly-quota throttle for one codex account.

Codex records a rate-limit snapshot into its own session rollout on every turn,
so an account's weekly usage is readable from disk and costs no API quota:

    {"limit_id": "codex",
     "primary": {"used_percent": 53.0, "window_minutes": 10080,
                 "resets_at": 1789440911}, ...}

Two modes, matching the producer/consumer split:

  record  scan this account's recent rollouts for the newest weekly snapshot
          and write it to the pool's usage.json. Run once per review by
          review-one-pr.sh, so the per-tick consumer reads one small file
          instead of globbing tens of thousands of rollouts.

  decide  read that file and print the epoch this account should be throttled
          until, or nothing if it should keep claiming. Run every tick by
          review-loop.sh.

Two triggers fire a pause (see the design doc):

  A projection  used * 168 / elapsed >= PCT, once elapsed >= MIN_ELAPSED_H.
                The gate is a confidence gate: it keeps the projection off a
                denominator too small to mean anything.
  B absolute    used >= PCT, ungated. There is nothing left to project once an
                account is already at the threshold, and the gate is blind to
                accounts that burn a week's quota inside a day -- which is how
                two of three caps happened on 2026-09-10.
"""

import argparse
import json
import os
import sys
import time
from glob import glob

WINDOW_H = 168.0          # codex weekly window; window_minutes is always 10080
MAX_ROLLOUTS = 200        # bounded scan: newest N by mtime under the date dirs
WINDOW_TOL_S = 3600       # resets_at jitters by seconds within one window


def _env_float(name, default):
    try:
        return float(os.environ.get(name, "") or default)
    except ValueError:
        return float(default)


def decide(used, resets_at, now, pct, min_elapsed_h, pause_h):
    """Epoch to throttle until, or None to keep claiming.

    Fails open on every unusable input: a disabled threshold, and a reading
    whose window has already rolled (its used_percent describes a dead window,
    so trusting it would throttle an account that is actually at zero).
    """
    if pct <= 0:
        return None
    if resets_at <= now:
        return None
    elapsed = WINDOW_H - (resets_at - now) / 3600.0
    fire = used >= pct
    if not fire and elapsed >= min_elapsed_h and elapsed > 0:
        fire = used * WINDOW_H / elapsed >= pct
    if not fire:
        return None
    return int(min(now + pause_h * 3600.0, resets_at))


def _primary(obj):
    """Deepest-first search for a rate_limits block carrying a usable primary."""
    if isinstance(obj, dict):
        rl = obj.get("rate_limits")
        if isinstance(rl, dict):
            p = rl.get("primary")
            if isinstance(p, dict) and p.get("used_percent") is not None \
               and p.get("resets_at") is not None:
                return p
        for v in obj.values():
            found = _primary(v)
            if found:
                return found
    return None


def latest_snapshot(codex_home):
    """Newest weekly snapshot for this account, or None.

    Three properties of real rollouts drive this, each verified against the
    live fleet on 2026-09-10 -- a naive read gets all three wrong:

    1. A single rollout carries readings from MORE THAN ONE window. Sessions
       get resumed, so the last rate_limits line in a file is often an older
       window's. Reading one line per file reported w3 at 55% while it was
       actually capped at 100% -- in a file that held the 100% reading.
    2. resets_at JITTERS by a few seconds between readings of the same window
       (...846/...847/...848 all name one window), so grouping by exact
       equality shatters a window into useless fragments.
    3. Within a window used_percent only ever grows, so the max across that
       window IS the latest reading -- and no ordering heuristic is needed to
       find it. Scanning more files can then only sharpen the estimate, never
       corrupt it, which makes MAX_ROLLOUTS a precision knob rather than a
       correctness risk. Under-reading is fail-safe: it throttles late, never
       early.
    """
    files = glob(os.path.join(codex_home, "sessions", "*", "*", "*", "*.jsonl"))
    files.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    seen = []
    for path in files[:MAX_ROLLOUTS]:
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for line in lines:
            if '"rate_limits"' not in line:
                continue
            try:
                p = _primary(json.loads(line))
            except (ValueError, TypeError):
                continue
            if p:
                seen.append((float(p["used_percent"]), int(p["resets_at"])))
    if not seen:
        return None
    newest = max(r for _, r in seen)
    window = [(u, r) for u, r in seen if newest - r <= WINDOW_TOL_S]
    return {"used_percent": max(u for u, _ in window),
            "resets_at": max(r for _, r in window),
            "observed_at": int(time.time())}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="mode", required=True)

    rec = sub.add_parser("record", help="write this account's usage snapshot")
    rec.add_argument("--codex-home", required=True)
    rec.add_argument("--out", required=True)

    dec = sub.add_parser("decide", help="print the throttle epoch, if any")
    dec.add_argument("--usage", required=True)
    dec.add_argument("--now", type=int, default=None)

    args = ap.parse_args(argv)

    if args.mode == "record":
        snap = latest_snapshot(args.codex_home)
        if snap is None:
            return 1
        tmp = args.out + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(snap, fh)
            fh.write("\n")
        os.replace(tmp, args.out)
        return 0

    # decide -- every failure path is silent and non-throttling.
    try:
        with open(args.usage) as fh:
            snap = json.load(fh)
        used = float(snap["used_percent"])
        resets_at = int(snap["resets_at"])
    except (OSError, ValueError, TypeError, KeyError):
        return 0
    until = decide(
        used, resets_at,
        args.now if args.now is not None else int(time.time()),
        _env_float("KWR_THROTTLE_PCT", 90),
        _env_float("KWR_THROTTLE_MIN_ELAPSED_H", 24),
        _env_float("KWR_THROTTLE_PAUSE_H", 24),
    )
    if until is not None:
        print(until)
    return 0


if __name__ == "__main__":
    sys.exit(main())
