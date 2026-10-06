"""Render the knightwatch status page (tailnet-only, ~/pages/knightwatch/).

build() turns collected sources into the page model: every number and every
red/amber rule lives here so it is testable; status_page.html only draws it.
"""
import argparse
import json
import os
import sqlite3
import statistics
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

LIB = Path(__file__).resolve().parent
REPO_DIR = LIB.parent
PROJECT = "knightwatch-reviewer"

DAY = 86400
STUCK_FACTOR = 3
QUEUE_RED_S = 3600
QUEUE_STALL_S = 1800
PACING = ("throttled", "quota-paused")
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


def _inflight(runs, total50, now):
    newest = {}   # newest run per PR first, so a finished rerun retires an older killed one
    for r in runs:
        k = (r["repo"], r["pr"])
        if k not in newest or r["t"] > newest[k]["t"]:
            newest[k] = r
    live = [r for r in newest.values() if r["live"]]   # a killed run's lock dies with its worker
    return [{"repo": r["repo"], "pr": r["pr"], "title": r["title"], "age": now - r["t"], "done": sorted(r["span"]),
             "stuck": bool(total50) and now - r["t"] > STUCK_FACTOR * total50}
            for r in sorted(live, key=lambda r: r["t"])]


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
    if a["status"] in PACING:
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
        out.append(("Queue", f"{q['repo']}#{q['pr']} has waited {_dur(q['wait'])} and no review has started in {_dur(m['queue']['idle'])}",
                    "the fleet has stopped claiming: check the reviewer containers panel and `docker compose logs` (operator)"))
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
    inflight = _inflight(runs, anatomy["total50"], now) if snap else None
    accounts = None
    queue = None
    if snap:
        accounts = [{**a, "over": (a.get("projected") or 0) > 100} for a in snap["accounts"]]
        accounts = [{**a, "level": _level(a)} for a in accounts]
        # queue.json is a per-window snapshot, so it can still list a PR a worker has since claimed.
        running = {(f["repo"], f["pr"]) for f in inflight or []}
        specs = [{"repo": s["repo"], "pr": s["pr_num"], "title": s["title"], "wait": now - _epoch(s["since"])}
                 for s in snap["queue"]["specs"] if (s["repo"], s["pr_num"]) not in running]
        late = any(s["wait"] > QUEUE_RED_S for s in specs)
        # A long wait while reviews keep starting, or while every account paces, is the fleet working
        # (amber); red only when an active account exists yet nothing has been claimed.
        idle = now - max((r["t"] for r in runs), default=0)
        queue = {"specs": sorted(specs, key=lambda s: -s["wait"]), "late": late, "idle": idle,
                 "red": late and idle > QUEUE_STALL_S and any(a["status"] == "active" for a in accounts)}
    feedback = None
    if bake and "prompt_changed" in src:
        changed = src["prompt_changed"]
        feedback = {"rows": bake["rows"], "crit": bake["crit"], "loved": bake["loved"],
                    "unaddressed": [c for c in bake["critiques"] if c["ran_at_epoch"] > (changed.get(c["spec"]) or 0)]}
    gh = ({k: {**src["gh"][k], "red": src["gh"][k]["remaining"] / src["gh"][k]["limit"] < GH_RED}
           for k in ("core", "graphql")} if "gh" in src else None)
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


def _run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120, **kw).stdout


def gather_snapshot():
    """The fleet's /shared snapshot, collected inside a running reviewer."""
    names = sorted(n for n in _run("docker", "ps", "--filter", f"label=com.docker.compose.project={PROJECT}",
                                   "--format", "{{.Names}}").split() if n.startswith(f"{PROJECT}-reviewer-"))
    if not names:
        raise RuntimeError("no running reviewer container")
    with open(LIB / "status_collect.py") as script:
        return json.loads(_run("docker", "exec", "-i", names[0], "python3", "-", stdin=script))


def source_bakeoff(db):
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    specs = {s: {"n": n, "pub": p, "app": a} for s, n, p, a in con.execute(
        "SELECT specialist, count(*), sum(published), sum(applied) FROM specialist_runs "
        "WHERE ran_at > datetime('now','-30 days') AND specialist NOT LIKE 'screened-%' "
        "AND specialist != 'aggregator' GROUP BY 1")}
    critiques = [{"repo": r, "pr": p, "spec": s, "ran_at_epoch": _epoch(t)} for r, p, s, t in con.execute(
        "SELECT repo, pr_number, specialist, ran_at FROM specialist_runs WHERE critiqued = 1")]
    rows, crit, loved = con.execute(
        "SELECT count(*), coalesce(sum(critiqued),0), coalesce(sum(loved_positive),0) FROM specialist_runs").fetchone()
    return {"specs": specs, "critiques": critiques, "rows": rows, "crit": crit, "loved": loved}


def source_prompt_changed(specs):
    out = {}
    for s in specs:
        ct = _run("git", "-C", str(REPO_DIR), "log", "-1", "--format=%ct", "--", f"prompts/specialists/{s}.md").strip()
        out[s] = float(ct) if ct else None
    return out


def source_gh():
    return json.loads(_run("gh", "api", "rate_limit"))["resources"]


def source_repos(runs, clone_root):
    last = {}
    for r in runs:
        last[r["repo"]] = max(last.get(r["repo"], 0), r["t"])
    rows = []
    for repo, t in sorted(last.items(), key=lambda kv: -kv[1]):
        clone = Path(clone_root) / repo.split("/")[1]
        row = {"repo": repo, "last": t, "reviews30": sum(r["repo"] == repo for r in runs), "clone": (clone / ".git").exists()}
        if row["clone"]:
            def has(p):
                return subprocess.run(["git", "-C", str(clone), "cat-file", "-e", f"HEAD:{p}"],
                                      capture_output=True).returncode == 0
            kid = clone / ".keepitdry"
            # plow-kid-refresh marks a healthy in-progress index "refreshing": amber, not a failure.
            marker = kid / ".stale"
            reason = marker.read_text().partition("\n")[0].removeprefix("reason=") if marker.exists() else ""
            row.update(review_md=has("REVIEW.md"), siblings=has(".knightwatch/siblings"),
                       kid="refreshing" if reason == "refreshing" else "stale" if reason
                       else "fresh" if (kid / ".indexed-sha").exists() else "none")
        rows.append(row)
    return rows


def render(model):
    data = json.dumps(model).replace("<", "\\u003c")   # no title can open or close a tag inside the data <script>
    return (LIB / "status_page.html").read_text().replace("__DATA__", data)


def _write(path, text):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=Path.home() / "pages/knightwatch")
    ap.add_argument("--clone-root", default=str(Path.home() / "services/kwr-repos"))
    ap.add_argument("--bakeoff-db", default=str(Path.home() / ".pr-reviewer/bakeoff.db"))
    args = ap.parse_args(argv)
    now, src, errors = time.time(), {}, {}

    # Each source is isolated on purpose: one failure becomes a red card on its
    # own panel plus a non-zero exit (journalctl), never a blank page.
    def attempt(name, fn):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 — reported per panel, and exit 1 below
            errors[name] = f"{type(exc).__name__}: {exc}"
            return None

    snap = attempt("snapshot", gather_snapshot)
    if snap:
        src["snapshot"] = snap
    for name, fn in (("bakeoff", lambda: source_bakeoff(args.bakeoff_db)), ("gh", source_gh)):
        val = attempt(name, fn)
        if val is not None:
            src[name] = val
    if "bakeoff" in src:
        val = attempt("prompt_changed", lambda: source_prompt_changed(src["bakeoff"]["specs"]))
        if val is not None:
            src["prompt_changed"] = val
    if "snapshot" in src:
        val = attempt("repos", lambda: source_repos(src["snapshot"]["runs"], args.clone_root))
        if val is not None:
            src["repos"] = val
    model = build(src, errors, now)
    args.out.mkdir(parents=True, exist_ok=True)
    _write(args.out / "status.json", json.dumps(model))
    _write(args.out / "index.html", render(model))
    for name, msg in errors.items():
        print(f"status-page: {name} failed: {msg}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
