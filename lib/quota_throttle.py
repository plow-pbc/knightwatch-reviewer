#!/usr/bin/env python3
"""Preemptive weekly-quota throttle for one codex account.

Codex records a rate-limit snapshot into its session rollout on every turn, so
weekly usage is readable from disk at no API cost:

    {"primary": {"used_percent": 53.0, "window_minutes": 10080,
                 "resets_at": 1789440911}, ...}

`record` captures that snapshot after a review; `decide` reads it each tick and
prints the epoch to throttle until. Two triggers fire a pause: a projection
gated on enough elapsed window to trust it, and an ungated absolute check --
the gate is blind to accounts that burn a week's quota inside a day.
"""

import argparse
import json
import os
import sys
import time
from glob import glob

WINDOW_H = 168.0          # codex weekly window
WINDOW_MINUTES = 10080    # ...as codex reports it; the block must say so, not be assumed
MAX_ROLLOUTS = 200        # bounded scan: newest N by mtime under the date dirs
WINDOW_TOL_S = 3600       # resets_at jitters by seconds within one window


def decide(used, resets_at, now, pct, min_elapsed_h, pause_h):
    """Epoch to throttle until, or None to keep claiming.

    Fails open on a disabled threshold and on a reading whose window already
    rolled -- that used_percent describes a dead window, so trusting it would
    throttle an account currently at zero.
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


def _weekly(rec):
    """The weekly reading from one rollout line as (used_percent, resets_at).

    Identified by its declared window, never by position: a tiered response
    placing a short session limit here would otherwise be read as weekly usage
    and mis-decide silently. A block whose window does not match is skipped,
    which fails open -- no snapshot rather than a wrong one.
    """
    try:
        p = rec["payload"]["rate_limits"]["primary"]
        if p["window_minutes"] == WINDOW_MINUTES:
            return (float(p["used_percent"]), int(p["resets_at"]))
    except (KeyError, TypeError, ValueError):
        pass
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
                rec = json.loads(line)
            except ValueError:
                continue
            hit = _weekly(rec)
            if hit:
                seen.append(hit)
    if not seen:
        return None
    newest = max(r for _, r in seen)
    window = [(u, r) for u, r in seen if newest - r <= WINDOW_TOL_S]
    return {"used_percent": max(u for u, _ in window),
            "resets_at": max(r for _, r in window)}


def account_state(pool_dir, account, now):
    """One account's quota line for the operator table.

    `used` is reported ONLY when the snapshot describes the window that is
    still open. A reading whose window has rolled says nothing about current
    usage -- an account that capped mid-window leaves its last non-null
    reading behind and goes dark, so the stale number can sit there for days
    looking like a live measurement. decide() already ignores those; this
    prints why instead of a misleading percentage.
    """
    d = os.path.join(pool_dir, account)
    def epoch(name):
        try:
            with open(os.path.join(d, name)) as fh:
                return int(fh.readline().strip())
        except (OSError, ValueError):
            return 0
    cap, throttle = epoch("quota-paused-until"), epoch("throttle-paused-until")
    state = ("hard-capped until " + _stamp(cap) if now < cap else
             "throttled until " + _stamp(throttle) if now < throttle else "claiming")
    try:
        with open(os.path.join(d, "usage.json")) as fh:
            snap = json.load(fh)
        used, resets_at = float(snap["used_percent"]), int(snap["resets_at"])
    except (OSError, ValueError, TypeError, KeyError):
        return {"account": account, "note": "no snapshot recorded", "state": state}
    if resets_at <= now:
        return {"account": account, "state": state,
                "note": "stale: window ended " + _stamp(resets_at)}
    elapsed = WINDOW_H - (resets_at - now) / 3600.0
    return {"account": account, "state": state, "used": used,
            "elapsed": elapsed, "projected": used * WINDOW_H / elapsed,
            "resets_at": resets_at}


def _stamp(epoch_s):
    return time.strftime("%b %d %H:%M UTC", time.gmtime(epoch_s))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="mode", required=True)

    rec = sub.add_parser("record", help="write this account's usage snapshot")
    rec.add_argument("--codex-home", required=True)
    rec.add_argument("--out", required=True)

    dec = sub.add_parser("decide", help="print the throttle epoch, if any")
    dec.add_argument("--usage", required=True)
    dec.add_argument("--now", type=int, default=None)

    st = sub.add_parser("status", help="per-account quota table for the fleet")
    st.add_argument("--pool-dir", required=True)
    st.add_argument("--now", type=int, default=None)

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

    if args.mode == "status":
        now = args.now if args.now is not None else int(time.time())
        for account in sorted(os.listdir(args.pool_dir)):
            if not os.path.isdir(os.path.join(args.pool_dir, account)):
                continue
            r = account_state(args.pool_dir, account, now)
            if "used" in r:
                print(f"{r['account']:<4}{r['used']:>6.0f}%{r['elapsed']:>7.0f}h"
                      f"{r['projected']:>10.0f}%  {r['state']}")
            else:
                print(f"{r['account']:<4}{'—':>6} {'—':>6}  {'—':>9}  "
                      f"{r['state']} ({r['note']})")
        return 0

    # decide -- always non-throttling on failure, but only SILENT when the
    # snapshot is legitimately absent. A file that exists and will not parse is
    # a fault, not an idle throttle, and collapsing the two is what lets the
    # feature stop working while the loop's logs still read healthy.
    try:
        with open(args.usage) as fh:
            snap = json.load(fh)
        used = float(snap["used_percent"])
        resets_at = int(snap["resets_at"])
    except FileNotFoundError:
        return 0          # nothing recorded yet; the throttle is simply idle
    except (OSError, ValueError, TypeError, KeyError) as exc:
        sys.stderr.write(f"unreadable usage snapshot {args.usage}: {exc}\n")
        return 2
    until = decide(
        used, resets_at,
        args.now if args.now is not None else int(time.time()),
        float(os.environ.get("KWR_THROTTLE_PCT", 90)),
        float(os.environ.get("KWR_THROTTLE_MIN_ELAPSED_H", 24)),
        float(os.environ.get("KWR_THROTTLE_PAUSE_H", 24)),
    )
    if until is not None:
        print(until)
    return 0


if __name__ == "__main__":
    sys.exit(main())
