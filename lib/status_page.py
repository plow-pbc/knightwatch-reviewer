"""Render the knightwatch status page (tailnet-only, ~/pages/knightwatch/).

build() turns collected sources into the page model: every number and every
red/amber rule lives here so it is testable; status_page.html only draws it.
"""
import argparse
import getpass
import json
import os
import shlex
import socket
import sqlite3
import statistics
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
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
MIN_WEEK_RUNS = 30
GATE_RED = 0.25
DELTA_WEEKS = 4
DELTA_FLAG_PT = 2
# $/1M tokens (input, cached input, output): OpenAI standard-tier, short-context
# rates (developers.openai.com/api/docs/pricing). Codex's 258K window never
# reaches the >272K long-context tier. An unlisted model is reported as unpriced.
PRICES = {"gpt-5.4-mini": (0.75, 0.075, 4.5), "gpt-5.5": (5, 0.5, 30), "gpt-5.6-luna": (0.2, 0.02, 1.2),
          "gpt-5.6-sol": (4, 0.4, 20), "gpt-5.6-terra": (2, 0.2, 12), "gpt-6-luna": (0.1, 0.01, 0.5),
          "gpt-6-sol": (2, 0.2, 10), "gpt-6.1-sol": (2, 0.1, 10)}


def _epoch(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() if iso else None


def _p50(xs):
    return round(statistics.median(xs)) if xs else None


def _dur(s):
    return f"{round(s)}s" if s < 90 else f"{round(s / 60)}m" if s < 5400 else f"{s / 3600:.1f}h"


def _monday(epoch):
    d = datetime.fromtimestamp(epoch, timezone.utc).date()
    return (d - timedelta(days=d.weekday())).isoformat()


def _pct(a, b):
    return round(100 * a / b, 1) if b else None


def _edit_delta(weeks, edits, now):
    """Edited-later yield over the DELTA_WEEKS complete weeks wholly after the newest prompt edit vs. wholly before it."""
    if not edits:
        return None
    edit = edits[0][0]

    def bounds(w):
        start = datetime.fromisoformat(w[0]).replace(tzinfo=timezone.utc).timestamp()
        return start, start + 7 * DAY

    def rate(ws):
        return _pct(sum(w[2] for w in ws), sum(w[1] for w in ws))
    before = rate([w for w in weeks if bounds(w)[1] <= edit][-DELTA_WEEKS:])
    after = rate([w for w in weeks if bounds(w)[0] >= edit and bounds(w)[1] <= now][:DELTA_WEEKS])
    if before is None or after is None:
        return None
    change = round(after - before, 1)
    return {"last": datetime.fromtimestamp(edit, timezone.utc).date().isoformat(), "before": before, "after": after,
            "change": change, "flag": "up" if change > DELTA_FLAG_PT else "down" if change < -DELTA_FLAG_PT else None}


def _scale(wins, days, now):
    """Header strip: the last 28 days and the 28 before, tokens and API-rate cost by day, reviews from runs."""
    def sum_days(lo, hi):
        t = {"input": 0, "cached": 0, "output": 0, "cost": 0.0, "unpriced": 0}
        for d, models in days.items():
            if not lo <= datetime.fromisoformat(d).replace(tzinfo=timezone.utc).timestamp() < hi:
                continue
            for model, (inp, cached, out, _) in models.items():
                t["input"] += inp
                t["cached"] += cached
                t["output"] += out
                if model in PRICES:
                    pin, pc, pout = PRICES[model]
                    t["cost"] += ((inp - cached) * pin + cached * pc + out * pout) / 1e6
                else:
                    t["unpriced"] += inp + out
        return t
    # Token days are UTC dates, so their windows end with today.
    end = datetime.fromtimestamp(now, timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0).timestamp() + DAY
    return {"runs": wins, "tokens": None if days is None else
            {"cur": sum_days(end - 28 * DAY, end), "prev": sum_days(end - 56 * DAY, end - 28 * DAY)}}


def _specialists(bake, edits, anatomy, now):
    nodes = anatomy["nodes"] if anatomy else {}
    rows = []
    for name, c in bake["specs"].items():
        weeks = bake["weekly"].get(name, [])
        es = None if edits is None else edits.get(name, [])
        rows.append({"name": name, "n": c["n"], "found": _pct(c["pub"], c["n"]), "edited": _pct(c["after"], c["n"]),
                     "edited_of_found": _pct(c["after"], c["pub"]), "p50": nodes.get(name, {}).get("p50"),
                     "yield_weekly": [[w, _pct(a, n)] for w, n, a in weeks if n >= MIN_WEEK_RUNS],
                     "edits": es, "delta": _edit_delta(weeks, es, now)})
    timed = [r for r in rows if r["p50"] is not None]
    axes = ({"yield": statistics.median(r["edited"] for r in timed), "runtime": statistics.median(r["p50"] for r in timed)}
            if timed else None)
    for r in rows:
        fast = axes and r["p50"] is not None and r["p50"] < axes["runtime"]
        r["zone"] = (None if not axes or r["p50"] is None else
                     ("keep" if fast else "worth") if r["edited"] >= axes["yield"] else ("noise" if fast else "cut"))
    return {"rows": sorted(rows, key=lambda r: -r["edited"]), "axes": axes}


def _anatomy(runs, now):
    done = [r for r in runs if now - r["t"] < 7 * DAY and r["status"] == "completed" and r["total"]]
    gates, slack = {}, {}
    for r in done:
        agg = r["span"].get("aggregator")
        if not agg:
            continue
        # The gate is whichever stage finished last before the aggregator could start.
        before = {k: v for k, v in r["span"].items() if k != "aggregator" and v[1] <= agg[0]}
        if before:
            g = max(before, key=lambda k: before[k][1])
            gates[g] = gates.get(g, 0) + 1
        for k, v in before.items():
            slack.setdefault(k, []).append(agg[0] - v[1])
    nodes = {}
    for k in {k for r in done for k in r["span"]}:
        ran = [r["span"][k] for r in done if k in r["span"]]
        gate = gates.get(k, 0) / len(ran)
        nodes[k] = {"s50": _p50([s for s, _ in ran]), "e50": _p50([e for _, e in ran]), "p50": _p50([e - s for s, e in ran]),
                    "n": len(ran), "gate": gate, "slack50": _p50(slack.get(k, [])), "critical": gate >= GATE_RED}
    skip7 = {}
    for r in runs:
        if now - r["t"] < 7 * DAY:
            for a in r["skipped"]:
                skip7[a] = skip7.get(a, 0) + 1
    weekly = {}
    for r in runs:
        if r["status"] == "completed":
            for k, (s, e) in r["span"].items():
                weekly.setdefault(k, {}).setdefault(_monday(r["t"]), []).append(e - s)
    runtime_weekly = {k: [[w, _p50(xs)] for w, xs in sorted(ws.items()) if len(xs) >= MIN_WEEK_RUNS]
                      for k, ws in weekly.items()}
    return {"nodes": nodes, "skip7": skip7, "total50": _p50([r["total"] for r in done]),
            "runtime_weekly": {k: v for k, v in runtime_weekly.items() if v}}


def _inflight(runs, total50, now):
    newest = {}   # newest run per PR first, so a finished rerun retires an older killed one
    for r in runs:
        k = (r["repo"], r["pr"])
        if k not in newest or r["t"] > newest[k]["t"]:
            newest[k] = r
    live = [r for r in newest.values() if r["live"]]   # a killed run's lock dies with its worker
    return [{"repo": r["repo"], "pr": r["pr"], "worker": r["worker"], "title": r["title"], "age": now - r["t"], "done": sorted(r["span"]), "skipped": r["skipped"],
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


def _ssh(cmd, tty=False):
    """A command the operator pastes from their laptop: the page's host runs everything."""
    return f"ssh{' -t' if tty else ''} {getpass.getuser()}@{socket.gethostname()} {shlex.quote(cmd)}"


def _attention(m):
    """One {"panel","text","cmd"} per RED condition. Amber (auto-pacing,
    projection over 100%) is the system handling itself, so it never lands here."""
    compose = f"cd {shlex.quote(str(REPO_DIR))} && docker compose logs"
    out = [(name, "Data unavailable", _ssh("journalctl -u pr-reviewer-status-page -n 50"))
           for name in m["errors"]]
    for a in m["accounts"] or []:
        c = f"{PROJECT}-reviewer-{a['account']}-1"
        if a["status"] == "offline":
            out.append((f"Reviewer {a['account']}", "Login required",
                        _ssh(f"docker exec -it {c} codex login --device-auth", tty=True)))
        elif a["status"] == "not running":
            out.append((f"Reviewer {a['account']}", f"No heartbeat · {_dur(a['tick_age'])}",
                        _ssh(f"docker logs --tail 100 {c}")))
    if m["queue"] and m["queue"]["red"]:
        q = max(m["queue"]["specs"], key=lambda s: s["wait"])
        out.append(("Queue", f"Stalled · oldest wait {_dur(q['wait'])}", _ssh(f"{compose} --tail 200")))
    for k, b in (m["gh"] or {}).items():
        if b["red"]:
            out.append((f"GitHub {k}", f"{round(100 * b['remaining'] / b['limit'])}% remaining",
                        _ssh("sort ~/.pr-reviewer/gh-call-tally | uniq -c | sort -nr | head")))
    for f in m["inflight"] or []:
        if f["stuck"]:
            pr = f"{f['repo']}#{f['pr']}"
            out.append((pr, f"Possibly stuck · {_dur(f['age'])}", _ssh(f"{compose} --since 3h | grep -F {shlex.quote(pr)}")))
    for r in m["repos"] or []:
        if r["red"]:
            out.append((r["repo"], "Prior-art index stale", _ssh("journalctl -u pr-reviewer-kid-refresh -n 100")))
    return [{"panel": p, "text": t, "cmd": c} for p, t, c in out]


def build(src, errors, now):
    snap, bake = src.get("snapshot"), src.get("bakeoff")
    runs = snap["runs"] if snap else []
    anatomy = _anatomy(runs, now) if snap else None
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
        # A long wait while reviews keep starting, every free reviewer is busy, or every account paces
        # is the fleet working (amber); red only when an active reviewer sits idle and nothing is claimed.
        idle = now - max((r["t"] for r in runs), default=0)
        queue = {"specs": sorted(specs, key=lambda s: -s["wait"]), "late": late, "idle": idle,
                 "red": late and idle > QUEUE_STALL_S and sum(a["status"] == "active" for a in accounts) > len(inflight)}
    feedback = None
    if bake and "prompt_edits" in src:
        last = {s: e[0][0] for s, e in src["prompt_edits"].items() if e}
        feedback = {"rows": bake["rows"], "crit": bake["crit"], "loved": bake["loved"],
                    "unaddressed": [c for c in bake["critiques"] if c["ran_at_epoch"] > last.get(c["spec"], 0)]}
    specialists = _specialists(bake, src.get("prompt_edits"), anatomy, now) if bake else None
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
    scale = _scale(snap and snap.get("windows"), src.get("tokens"), now)
    m = {"generated_at": now, "errors": errors, "tiles": tiles, "scale": scale, "anatomy": anatomy, "inflight": inflight,
         "queue": queue, "accounts": accounts, "image": snap["image"] if snap else None, "gh": gh, "slow": _slow(runs, now) if snap else None,
         "feedback": feedback, "specialists": specialists, "repos": repos}
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
    specs = {s: {"n": n, "pub": p, "after": a} for s, n, p, a in con.execute(
        "SELECT specialist, count(*), sum(published), sum(edited_after) FROM specialist_runs "
        "WHERE ran_at > datetime('now','-30 days') AND specialist NOT LIKE 'screened-%' "
        "AND specialist != 'aggregator' GROUP BY 1")}
    critiques = [{"repo": r, "pr": p, "spec": s, "ran_at_epoch": _epoch(t)} for r, p, s, t in con.execute(
        "SELECT repo, pr_number, specialist, ran_at FROM specialist_runs WHERE critiqued = 1")]
    rows, crit, loved = con.execute(
        "SELECT count(*), coalesce(sum(critiqued),0), coalesce(sum(loved_positive),0) FROM specialist_runs").fetchone()
    weekly = {}
    for s, w, n, a in con.execute(
            "SELECT specialist, date(ran_at, '-6 days', 'weekday 1'), count(*), sum(edited_after) FROM specialist_runs "
            "WHERE specialist NOT LIKE 'screened-%' AND specialist != 'aggregator' GROUP BY 1, 2 ORDER BY 1, 2"):
        weekly.setdefault(s, []).append([w, n, a])
    return {"specs": specs, "weekly": weekly, "critiques": critiques, "rows": rows, "crit": crit, "loved": loved}


def source_prompt_edits(specs):
    out = {}
    for s in specs:
        log = _run("git", "-C", str(REPO_DIR), "log", "--format=%ct%x09%s", "--", f"prompts/specialists/{s}.md")
        out[s] = [[float(ct), subj] for ct, _, subj in (line.partition("\t") for line in log.splitlines())]
    return out


def _rollout_usage(path):
    """(model, final cumulative token usage) of one codex rollout, else None."""
    def usage(lines):
        for line in reversed(lines):
            if b'"token_count"' not in line:
                continue
            try:
                return json.loads(line)["payload"]["info"]["total_token_usage"]
            except (ValueError, KeyError, TypeError):   # a cut first line, or tool text naming the event
                continue
        return None
    model = None
    with open(path, "rb") as fh:
        for line in fh:
            if b'"turn_context"' in line:
                model = json.loads(line)["payload"].get("model")
                break
        size = fh.seek(0, os.SEEK_END)
        fh.seek(max(0, size - 65536))
        u = usage(fh.read().splitlines())
        if u is None and size > 65536:   # a long final tool output can push the last count out of the tail
            fh.seek(0)
            u = usage(fh.read().splitlines())
    return u and (model, u)


def source_tokens(codex_root, cache_path, now):
    """{day: {model: [input, cached, output, sessions]}} over every account's codex rollouts.

    Days older than two are settled (a review is capped at 90m), so they come
    from cache_path; only the last few day dirs are rescanned each build."""
    if not Path(codex_root).is_dir():
        raise FileNotFoundError(f"codex root {codex_root}")
    try:
        days = json.loads(cache_path.read_text())
    except FileNotFoundError:
        days = {}
    settled = (datetime.fromtimestamp(now, timezone.utc).date() - timedelta(days=2)).isoformat()
    days = {d: v for d, v in days.items() if d < settled}
    cached = set(days)
    for daydir in Path(codex_root).glob("codex-account-*/sessions/*/*/*"):
        day = "-".join(daydir.parts[-3:])
        if day in cached:
            continue
        for f in daydir.glob("rollout-*.jsonl"):
            got = _rollout_usage(f)
            if not got:
                continue
            model, u = got
            row = days.setdefault(day, {}).setdefault(model or "unknown", [0, 0, 0, 0])
            for i, k in enumerate(("input_tokens", "cached_input_tokens", "output_tokens")):
                row[i] += u.get(k, 0)
            row[3] += 1
    _write(cache_path, json.dumps({d: v for d, v in days.items() if d < settled}))
    return days


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
            try:   # read, don't stat: kid-refresh deletes the marker when an index completes
                marker = (kid / ".stale").read_text().partition("\n")[0]
            except FileNotFoundError:
                marker = None
            row.update(review_md=has("REVIEW.md"), siblings=has(".knightwatch/siblings"),
                       kid="refreshing" if marker == "reason=refreshing" else "stale" if marker is not None
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
    ap.add_argument("--codex-root", default=str(Path.home() / "services/knightwatch-reviewer/docker/secrets"))
    ap.add_argument("--token-cache", type=Path, default=Path.home() / ".cache/knightwatch-token-days.json")
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
    for name, fn in (("bakeoff", lambda: source_bakeoff(args.bakeoff_db)), ("gh", source_gh),
                     ("tokens", lambda: source_tokens(args.codex_root, args.token_cache, now))):
        val = attempt(name, fn)
        if val is not None:
            src[name] = val
    if "bakeoff" in src:
        val = attempt("prompt_edits", lambda: source_prompt_edits(src["bakeoff"]["specs"]))
        if val is not None:
            src["prompt_edits"] = val
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
