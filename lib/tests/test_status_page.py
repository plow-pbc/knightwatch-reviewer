"""Tests for the status page: collector, model builder, renderer."""
import json
import os
import sys
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import status_collect  # noqa: E402

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
