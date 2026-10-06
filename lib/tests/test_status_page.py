"""Tests for the status page: collector, model builder, renderer."""
import json
import os
import sys
import time
import unittest
import unittest.mock
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import status_collect  # noqa: E402
import status_page  # noqa: E402

NOW = 1_791_000_000.0


def _w(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(obj if isinstance(obj, str) else json.dumps(obj))


def run_name(repo, pr, epoch, sha="abc1234"):
    ts = time.strftime("%Y%m%dT%H%M%S000Z", time.gmtime(epoch))
    return f"{repo.replace('/', '_')}__{pr}__{ts}__{sha}"


class TestCollect(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.shared = Path(self.tmp.name)
        pool = self.shared / "pool"
        for acct in ("1", "2", "3", "4", "10"):
            (pool / acct).mkdir(parents=True)
        _w(pool / "1" / "usage.json", {"used_percent": 20.0, "resets_at": int(NOW) + 4 * 86400})
        _w(pool / "2" / "auth-offline", "")
        _w(pool / "3" / "throttle-paused-until", str(int(NOW) + 3600))
        _w(pool / "4" / "usage.json", {"used_percent": 12.0, "resets_at": int(NOW) - 86400})
        for acct in ("1", "2", "3", "4"):
            os.utime(pool / acct, (NOW - 60, NOW - 60))
        os.utime(pool / "10", (NOW - 3 * 3600, NOW - 3 * 3600))
        _w(self.shared / "queue.json", {"refreshed_at": NOW, "specs": [{"repo": "o/r", "pr_num": 1, "title": "t", "since": "2026-10-05T23:10:24Z"}]})
        runs = self.shared / "runs"
        good = runs / run_name("o/r", 7, NOW - 3600)
        _w(good / "meta.json", {"repo": "o/r", "pr_num": 7, "title": "x", "status": "completed",
                                "finished_at": "z", "timings": {"total": 450}})
        _w(good / "timings.json", {"intent": {"start": 100.0, "end": 114.0, "rc": 0},
                                   "security": {"start": 114.0, "end": 236.0, "rc": 0}})
        _w(good / "_skipped_angles.txt", "consumers\n")
        _w(runs / run_name("o/r", 8, NOW - 31 * 86400) / "meta.json", {"repo": "o/r"})  # outside 30d
        (runs / run_name("o/r", 9, NOW - 60)).mkdir()                                     # no meta.json
        _w(runs / run_name("o/r", 10, NOW - 60) / "meta.json", "{corrupt")                # corrupt meta
        _w(runs / run_name("o/r", 11, NOW - 60) / "meta.json", {"repo": "o/r", "pr_num": 11})
        _w(runs / run_name("o/r", 11, NOW - 60) / "timings.json", "{corrupt")             # corrupt timings
        (runs / "not-a-run-dir").mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def snap(self):
        return status_collect.collect(self.shared, NOW, "America/Los_Angeles", 0.2)

    def test_account_status_precedence(self):
        status = {a["account"]: a["status"] for a in self.snap()["accounts"]}
        self.assertEqual(status, {"1": "active", "2": "offline", "3": "throttled",
                                  "4": "active", "10": "not running"})

    def test_stale_or_missing_usage_reports_a_note_not_a_percentage(self):
        acct = {a["account"]: a for a in self.snap()["accounts"]}
        self.assertEqual(acct["1"]["used"], 20.0)
        for a in ("2", "4"):
            self.assertNotIn("used", acct[a])
            self.assertTrue(acct[a]["note"])

    def test_runs_window_and_malformed_dirs(self):
        runs = {r["pr"]: r for r in self.snap()["runs"]}
        self.assertEqual(sorted(runs), [7, 11])   # 8 too old; 9/10 no usable meta; junk name skipped
        self.assertEqual(runs[7]["span"], {"intent": [0, 14], "security": [14, 136]})
        self.assertEqual(runs[7]["skipped"], ["consumers"])
        self.assertEqual(runs[11]["span"], {})

    def test_queue_passthrough(self):
        self.assertEqual(self.snap()["queue"]["specs"][0]["pr_num"], 1)


def run(pr, age, repo="o/r", total=450, finished=True, span=None, queued=None):
    return {"t": NOW - age, "repo": repo, "pr": pr, "title": f"pr {pr}", "status": "completed" if finished else None,
            "finished_at": "z" if finished else None, "queued_since": queued, "total": total if finished else None,
            "span": span or {"intent": [0, 14], "security": [14, 136], "aggregator": [246, 436]}, "skipped": []}


def src(runs, **over):
    base = {"snapshot": {"collected_at": NOW, "accounts": [], "queue": {"specs": []}, "runs": runs},
            "fleet_started": NOW - 1500,
            "bakeoff": {"specs": {"security": {"n": 10, "pub": 4, "app": 3}}, "critiques": [], "rows": 10, "crit": 0, "loved": 0},
            "prompt_changed": {"security": NOW - 86400},
            "gh": {"core": {"limit": 5000, "remaining": 900, "reset": NOW + 60}, "graphql": {"limit": 5000, "remaining": 4998, "reset": NOW + 60}},
            "repos": []}
    base.update(over)
    return base


class TestBuild(unittest.TestCase):
    def test_inflight_excludes_restart_orphans_and_stale_and_keeps_newest_per_pr(self):
        runs = [run(1, 2100, finished=False),                 # started before the fleet restart: orphan
                run(2, 600, finished=False), run(2, 300, finished=False),  # same PR twice: newest wins
                run(3, 120, finished=True),                   # finished
                run(4, 1400, finished=False),                 # after restart, under 90 min
                run(5, 600, finished=False), run(5, 300)]     # a killed run superseded by a finished one
        s = src(runs, fleet_started=NOW - 1500)
        s["snapshot"]["queue"]["specs"] = [{"repo": "o/r", "pr_num": p, "title": "t", "since": "2026-10-01T00:00:00Z"} for p in (4, 6)]
        m = status_page.build(s, {}, NOW)
        self.assertEqual([(f["pr"], round(f["age"])) for f in m["inflight"]], [(4, 1400), (2, 300)])
        self.assertEqual([q["pr"] for q in m["queue"]["specs"]], [6])   # a claimed PR left in the queue snapshot isn't waiting
        self.assertTrue(m["inflight"][0]["stuck"])            # 1400s > 3 × 450s median
        self.assertFalse(m["inflight"][1]["stuck"])

    def test_slowest_five_order_and_min_reviews(self):
        runs = [run(i, 3600, repo=f"o/r{k}", total=100 * k) for k in range(1, 8) for i in range(3)]
        runs += [run(99, 3600, repo="o/two-only", total=99999)] * 2
        slow = status_page.build(src(runs), {}, NOW)["slow"]
        self.assertEqual([s["repo"] for s in slow], ["o/r7", "o/r6", "o/r5", "o/r4", "o/r3"])

    def test_unaddressed_critique_is_one_newer_than_the_prompt(self):
        b = src([])["bakeoff"]
        b["critiques"] = [{"repo": "o/r", "pr": 1, "spec": "security", "ran_at_epoch": NOW - 3600},
                          {"repo": "o/r", "pr": 2, "spec": "security", "ran_at_epoch": NOW - 2 * 86400}]
        m = status_page.build(src([], bakeoff=b), {}, NOW)
        self.assertEqual([c["pr"] for c in m["feedback"]["unaddressed"]], [1])

    def test_red_rules(self):
        s = src([run(3, 120), run(4, 1400, finished=False)],
                repos=[{"repo": "o/r", "kid": "stale"}, {"repo": "o/fresh", "kid": "fresh"}, {"repo": "o/unindexed", "clone": False}])
        del s["bakeoff"]
        s["snapshot"]["queue"] = {"specs": [{"repo": "o/r", "pr_num": 5, "title": "t", "since": "2026-10-01T00:00:00Z"}]}
        s["snapshot"]["accounts"] = [
            {"account": "1", "status": "offline", "tick_age": 5, "state": "", "note": "x"},
            {"account": "2", "status": "active", "tick_age": 5, "state": "", "used": 50.0, "projected": 130.0, "resets_at": NOW + 9},
            {"account": "3", "status": "active", "tick_age": 5, "state": "", "used": 10.0, "projected": 40.0, "resets_at": NOW + 9},
            {"account": "4", "status": "not running", "tick_age": 9000, "state": "", "note": "x"}]
        m = status_page.build(s, {"bakeoff": "OperationalError: database is locked"}, NOW)
        self.assertTrue(m["queue"]["red"])
        self.assertEqual([a["level"] for a in m["accounts"]], ["red", "ok", "ok", "red"])  # projection >100% colors its own cell, not the status
        self.assertTrue(m["gh"]["core"]["red"])               # 900/5000 = 18%
        self.assertFalse(m["gh"]["graphql"]["red"])
        self.assertEqual([r["red"] for r in m["repos"]], [True, False, False])  # no clone is neutral, not red
        # Every red thing, and only red things, lands in "needs attention" with an action.
        self.assertEqual([(a["panel"], a["text"].split()[0]) for a in m["attention"]],
                         [("Collection", "bakeoff"), ("Reviewer containers", "reviewer-1"),
                          ("Reviewer containers", "reviewer-4"), ("Queue", "o/r#5"), ("GitHub quota", "core"),
                          ("In progress", "o/r#4"), ("Repo config", "o/r")])
        self.assertEqual(m["attention"][1]["action"], "codex re-login for reviewer-1 (operator)")
        self.assertTrue(all(a["action"] for a in m["attention"]))

    def test_late_queue_is_red_only_when_no_account_is_pacing(self):
        for status, red in (("active", True), ("throttled", False)):
            with self.subTest(status=status):
                s = src([])
                s["snapshot"]["queue"] = {"specs": [{"repo": "o/r", "pr_num": 5, "title": "t", "since": "2026-10-01T00:00:00Z"}]}
                s["snapshot"]["accounts"] = [{"account": "1", "status": status, "tick_age": 5, "state": "", "note": "x"}]
                m = status_page.build(s, {}, NOW)
                self.assertTrue(m["queue"]["late"])
                self.assertEqual(m["queue"]["red"], red)
                self.assertEqual(any(a["panel"] == "Queue" for a in m["attention"]), red)

    def test_failed_source_nulls_only_its_panels(self):
        s = src([run(1, 3600)])
        del s["gh"]
        m = status_page.build(s, {"gh": "CalledProcessError: gh exited 4"}, NOW)
        self.assertIsNone(m["gh"])
        self.assertIsNotNone(m["anatomy"])
        self.assertEqual(m["errors"], {"gh": "CalledProcessError: gh exited 4"})


class TestRender(unittest.TestCase):
    def test_hostile_title_is_inert(self):
        s = src([run(1, 600, finished=False)], fleet_started=NOW - 1500)
        s["snapshot"]["runs"][0]["title"] = '</script><img src=x onerror=alert(1)>'
        html = status_page.render(status_page.build(s, {}, NOW))
        self.assertNotIn("</script><img", html)
        self.assertEqual(html.count("</script>"), html.count("<script"))  # only the page's own tags close

    def test_main_isolates_a_failed_source_and_exits_nonzero(self):
        with TemporaryDirectory() as out, unittest.mock.patch.object(status_page, "source_gh", side_effect=RuntimeError("gh: not logged in")), \
             unittest.mock.patch.object(status_page, "gather_snapshot", return_value=(src([])["snapshot"], NOW - 1500)), \
             unittest.mock.patch.object(status_page, "source_bakeoff", return_value=src([])["bakeoff"]), \
             unittest.mock.patch.object(status_page, "source_prompt_changed", return_value={}), \
             unittest.mock.patch.object(status_page, "source_repos", return_value=[]):
            rc = status_page.main(["--out", out])
            model = json.loads(Path(out, "status.json").read_text())
            html = Path(out, "index.html").read_text()
        self.assertEqual(rc, 1)
        self.assertIsNone(model["gh"])
        self.assertIsNotNone(model["tiles"])
        self.assertIn("RuntimeError: gh: not logged in", html)
