import os
import stat
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from seed_secret import seed_secret  # noqa: E402


class TestSeedSecret(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.root.mkdir()
        self.source = Path(self.tmp.name) / "source"
        self.source.write_text("TOKEN=secret\n")
        self.source.chmod(0o644)

    def tearDown(self):
        self.tmp.cleanup()

    def test_seeds_private_file_and_replaces_final_symlink(self):
        outside = Path(self.tmp.name) / "outside"
        outside.write_text("unchanged")
        (self.root / "credential").symlink_to(outside)

        seed_secret(str(self.source), str(self.root), "credential")

        destination = self.root / "credential"
        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.read_text(), "TOKEN=secret\n")
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertEqual(outside.read_text(), "unchanged")

    def test_rejects_symlink_parent(self):
        outside = Path(self.tmp.name) / "outside-dir"
        outside.mkdir()
        (self.root / "api").symlink_to(outside, target_is_directory=True)

        with self.assertRaises(OSError):
            seed_secret(str(self.source), str(self.root), "api/credential")

        self.assertFalse((outside / "credential").exists())

    def test_rejects_parent_traversal(self):
        with self.assertRaises(ValueError):
            seed_secret(str(self.source), str(self.root), "../credential")


if __name__ == "__main__":
    unittest.main()
