"""Snapshot the fleet's shared state for the status page.

Runs INSIDE a reviewer container — the kwr_claims volume is root-only on the
host — piped over stdin by status_page.py (`docker exec -i <c> python3 -`), so
page changes never need an image rebuild. Prints one JSON document.
"""
import fcntl
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

WINDOW_S = 30 * 86400
# pool_status's threshold (lib/state-io.sh): a tick blocks on an in-flight
# review up to the 90m worker ceiling, so only >2h of silence means gone.
NOT_RUNNING_S = 7200


def run_epoch(name):
    """Epoch encoded in a run-dir name <repo>__<pr>__<ts>__<sha7>, else None."""
    parts = name.split("__")
    if len(parts) != 4:
        return None
    try:
        return datetime.strptime(parts[2], "%Y%m%dT%H%M%S%fZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def _json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def account_row(pool, account, now, tz, weekend):
    import quota_throttle
    d = pool / account
    row = quota_throttle.account_state(str(pool), account, int(now), tz, weekend)
    row["tick_age"] = int(now - d.stat().st_mtime)
    if row["tick_age"] > NOT_RUNNING_S:
        row["status"] = "not running"
    elif (d / "auth-offline").exists():
        row["status"] = "offline"
    elif row["state"].startswith("quota-paused"):
        row["status"] = "quota-paused"
    elif row["state"].startswith("throttled"):
        row["status"] = "throttled"
    else:
        row["status"] = "active"
    return row


def pr_locked(locks, repo, pr):
    """True while a worker holds the PR's lock (lib/locking.sh): the same
    non-blocking acquire-and-release probe the dispatcher runs every tick."""
    try:
        fd = os.open(locks / f"{repo.replace('/', '_')}__{pr}", os.O_RDONLY)
    except FileNotFoundError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return False
    except BlockingIOError:
        return True
    finally:
        os.close(fd)


def run_record(path, t, locks):
    meta = _json(path / "meta.json")
    if not isinstance(meta, dict):
        return None
    timings = _json(path / "timings.json")
    nodes = {k: v for k, v in (timings if isinstance(timings, dict) else {}).items()
             if isinstance(v, dict) and "start" in v and "end" in v}
    t0 = min((v["start"] for v in nodes.values()), default=0)
    skipped = path / "_skipped_angles.txt"
    return {"t": t, "repo": meta.get("repo"), "pr": meta.get("pr_num"), "title": meta.get("title"),
            "status": meta.get("status"), "finished_at": meta.get("finished_at"),
            "live": not meta.get("finished_at") and pr_locked(locks, meta.get("repo", ""), meta.get("pr_num")),
            "queued_since": meta.get("queued_since"),
            "total": (meta.get("timings") or {}).get("total"),
            "span": {k: [round(v["start"] - t0), round(v["end"] - t0)] for k, v in nodes.items()},
            "skipped": skipped.read_text().split() if skipped.exists() else []}


AGG_OUT = "agents/aggregator/output.md"


def verdict(run_dir):
    """The aggregator's closing VERDICT line (prompts/aggregator.md), else None."""
    tail = (run_dir / AGG_OUT).read_text().splitlines()[-10:]
    return next((ln for ln in reversed(tail) if ln.startswith("VERDICT:")), None)


def windows(names, runs_dir, now):
    """Reviews that reached a final review (most run dirs are aborted rounds), PRs,
    and each PR's latest verdict, for the last 28 days and the 28 days before."""
    out = {}
    for key, lo in (("cur", now - 28 * 86400), ("prev", now - 56 * 86400)):
        hi = lo + 28 * 86400
        done = [(n, t) for n, t in names if lo <= t < hi and (runs_dir / n / AGG_OUT).exists()]
        latest = {}
        for name, t in done:
            pr = tuple(name.split("__")[:2])
            latest[pr] = max(latest.get(pr, (0, "")), (t, name))
        verdicts = [v for v in (verdict(runs_dir / n) for _, n in latest.values()) if v]
        out[key] = {"reviews": len(done), "prs": len(latest), "verdicts": len(verdicts),
                    "approved": sum(v.startswith("VERDICT: APPROVE") for v in verdicts)}
    return out


def collect(shared, now, tz, weekend):
    pool = shared / "pool"
    runs, names = [], []
    for p in (shared / "runs").iterdir():
        t = run_epoch(p.name)
        if t is None:
            continue
        if now - t < 56 * 86400:
            names.append((p.name, t))
        if now - t > WINDOW_S:
            continue
        rec = run_record(p, t, shared / "locks")
        if rec:
            runs.append(rec)
    accounts = sorted((a for a in os.listdir(pool) if (pool / a).is_dir()), key=lambda a: (len(a), a))
    return {"collected_at": now,
            "accounts": [account_row(pool, a, now, tz, weekend) for a in accounts],
            "queue": _json(shared / "queue.json") or {"specs": []},
            "runs": runs,
            "windows": windows(names, shared / "runs", now)}


def main():
    sys.path.insert(0, os.environ.get("REVIEWER_LIB_DIR", "/app/lib"))
    import quota_throttle
    tz = os.environ.get("KWR_THROTTLE_TIMEZONE", quota_throttle.DEFAULT_TIMEZONE)
    weekend = float(os.environ.get("KWR_THROTTLE_WEEKEND_FACTOR", quota_throttle.DEFAULT_WEEKEND_FACTOR))
    json.dump(collect(Path(os.environ.get("STATE_DIR", "/shared")), time.time(), tz, weekend), sys.stdout)


if __name__ == "__main__":
    main()
