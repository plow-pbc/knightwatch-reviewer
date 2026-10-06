"""Render the knightwatch status page (tailnet-only, ~/pages/knightwatch/).

build() turns collected sources into the page model: every number and every
red/amber rule lives here so it is testable; status_page.html only draws it.
"""
import statistics
from datetime import datetime

DAY = 86400
WORKER_CEILING_S = 90 * 60
STUCK_FACTOR = 3
QUEUE_RED_S = 3600
GH_RED = 0.2


def _epoch(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() if iso else None


def _p50(xs):
    return round(statistics.median(xs)) if xs else None


def _dur(s):
    return f"{round(s)}s" if s < 90 else f"{round(s / 60)}m" if s < 5400 else f"{s / 3600:.1f}h"


def _anatomy(runs, bakeoff, now):
    done = [r for r in runs if now - r["t"] < 7 * DAY and r["status"] == "completed" and r["total"]]
    names = {k for r in done for k in r["span"]}
    nodes = {k: {"s50": _p50([r["span"][k][0] for r in done if k in r["span"]]),
                 "e50": _p50([r["span"][k][1] for r in done if k in r["span"]]),
                 "p50": _p50([r["span"][k][1] - r["span"][k][0] for r in done if k in r["span"]]),
                 "n": sum(k in r["span"] for r in done)} for k in names}
    skip7 = {}
    for r in runs:
        if now - r["t"] < 7 * DAY:
            for a in r["skipped"]:
                skip7[a] = skip7.get(a, 0) + 1
    return {"nodes": nodes, "skip7": skip7, "total50": _p50([r["total"] for r in done]),
            "specs": bakeoff["specs"] if bakeoff else None}


def _inflight(runs, fleet_started, total50, now):
    newest = {}
    for r in runs:
        if r["finished_at"] or now - r["t"] > WORKER_CEILING_S or r["t"] < fleet_started:
            continue
        k = (r["repo"], r["pr"])
        if k not in newest or r["t"] > newest[k]["t"]:
            newest[k] = r
    return [{"repo": r["repo"], "pr": r["pr"], "title": r["title"], "age": now - r["t"], "done": sorted(r["span"]),
             "stuck": bool(total50) and now - r["t"] > STUCK_FACTOR * total50}
            for r in sorted(newest.values(), key=lambda r: r["t"])]


def _slow(runs, now, n=5, min_reviews=3):
    by = {}
    for r in runs:
        if now - r["t"] < 7 * DAY and r["status"] == "completed" and r["total"]:
            by.setdefault(r["repo"], []).append(r)
    rows = [{"repo": repo, "p50": _p50([r["total"] for r in rs]), "n": len(rs),
             "wait50": _p50([r["t"] - _epoch(r["queued_since"]) for r in rs if r["queued_since"]])}
            for repo, rs in by.items() if len(rs) >= min_reviews]
    return sorted(rows, key=lambda s: -s["p50"])[:n]


def _level(a):
    if a["status"] in ("offline", "not running"):
        return "red"
    if a["status"] in ("throttled", "quota-paused") or (a.get("projected") or 0) > 100:
        return "amber"
    return "ok"


def _attention(m):
    """One {"panel","text","action"} per RED condition. Amber (auto-pacing,
    projection over 100%) is the system handling itself, so it never lands here."""
    out = [("Collection", f"{name} collection failed: {msg}",
            "check `journalctl -u pr-reviewer-status-page` (operator)") for name, msg in m["errors"].items()]
    for a in m["accounts"] or []:
        if a["status"] == "offline":
            out.append(("Reviewer containers", f"reviewer-{a['account']} is offline: its codex login expired",
                        f"codex re-login for reviewer-{a['account']} (operator)"))
        elif a["status"] == "not running":
            out.append(("Reviewer containers", f"reviewer-{a['account']} has not ticked for {_dur(a['tick_age'])}",
                        f"check why reviewer-{a['account']} stopped and restart it (operator)"))
    if m["queue"] and m["queue"]["red"]:
        q = max(m["queue"]["specs"], key=lambda s: s["wait"])
        out.append(("Queue", f"{q['repo']}#{q['pr']} has waited {_dur(q['wait'])} for a reviewer",
                    "no reviewer is claiming: check the reviewer containers panel (operator)"))
    for k, b in (m["gh"] or {}).items():
        if b["red"]:
            out.append(("GitHub quota", f"{k} quota at {round(100 * b['remaining'] / b['limit'])}%",
                        "reviews stall at zero: find the heavy caller before the next window (operator)"))
    for f in m["inflight"] or []:
        if f["stuck"]:
            out.append(("In progress", f"{f['repo']}#{f['pr']} has run {_dur(f['age'])}, likely stuck",
                        "inspect its run dir and kill the worker if it is hung (operator)"))
    for r in m["repos"] or []:
        if r["red"]:
            out.append(("Repo config", f"{r['repo']} keepitdry index is stale",
                        "check `journalctl -u pr-reviewer-kid-refresh` for why the refresh fails (operator)"))
    return [{"panel": p, "text": t, "action": a} for p, t, a in out]


def build(src, errors, now):
    snap, bake = src.get("snapshot"), src.get("bakeoff")
    runs = snap["runs"] if snap else []
    anatomy = _anatomy(runs, bake, now) if snap else None
    inflight = (_inflight(runs, src["fleet_started"], anatomy["total50"], now)
                if snap and "fleet_started" in src else None)
    queue = None
    if snap:
        specs = [{"repo": s["repo"], "pr": s["pr_num"], "title": s["title"], "wait": now - _epoch(s["since"])}
                 for s in snap["queue"]["specs"]]
        queue = {"specs": sorted(specs, key=lambda s: -s["wait"]), "red": any(s["wait"] > QUEUE_RED_S for s in specs)}
    feedback = None
    if bake and "prompt_changed" in src:
        changed = src["prompt_changed"]
        feedback = {"rows": bake["rows"], "crit": bake["crit"], "loved": bake["loved"],
                    "unaddressed": [c for c in bake["critiques"] if c["ran_at_epoch"] > (changed.get(c["spec"]) or 0)]}
    gh = ({k: {**src["gh"][k], "red": src["gh"][k]["remaining"] / src["gh"][k]["limit"] < GH_RED}
           for k in ("core", "graphql")} if "gh" in src else None)
    accounts = [{**a, "level": _level(a)} for a in snap["accounts"]] if snap else None
    repos = [{**r, "red": r.get("kid") == "stale"} for r in src["repos"]] if "repos" in src else None
    tiles = None
    if snap:
        recent = [r for r in runs if now - r["t"] < 7 * DAY]
        tiles = {"reviews7": len(recent), "total50": anatomy["total50"],
                 "repos30": len({r["repo"] for r in runs}), "queued": len(queue["specs"]),
                 "inflight": len(inflight) if inflight is not None else None,
                 "working": sum(a["level"] != "red" for a in accounts), "fleet": len(accounts)}
    m = {"generated_at": now, "errors": errors, "tiles": tiles, "anatomy": anatomy, "inflight": inflight,
         "queue": queue, "accounts": accounts, "gh": gh, "slow": _slow(runs, now) if snap else None,
         "feedback": feedback, "repos": repos}
    m["attention"] = _attention(m)
    return m
