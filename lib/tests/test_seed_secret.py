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

    def test_updates_existing_regular_file(self):
        destination = self.root / "credential"
        for mode in (0o644, 0o000, 0o004):
            with self.subTest(mode=oct(mode)):
                destination.unlink(missing_ok=True)
                destination.write_text("old")
                destination.chmod(mode)

                seed_secret(str(self.source), str(self.root), "credential")

                self.assertEqual(destination.read_text(), "TOKEN=secret\n")
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)

    def test_replaces_fifo_without_blocking(self):
        destination = self.root / "credential"
        os.mkfifo(destination)

        seed_secret(str(self.source), str(self.root), "credential")

        self.assertTrue(destination.is_file())
        self.assertEqual(destination.read_text(), "TOKEN=secret\n")

    def test_replacement_does_not_mutate_hardlink_target(self):
        outside = Path(self.tmp.name) / "outside"
        outside.write_text("unchanged")
        outside.chmod(0o644)
        destination = self.root / "credential"
        os.link(outside, destination)

        seed_secret(str(self.source), str(self.root), "credential")

        self.assertEqual(outside.read_text(), "unchanged")
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode), 0o644)
        self.assertEqual(destination.read_text(), "TOKEN=secret\n")

    def test_rejects_parent_traversal(self):
        with self.assertRaises(ValueError):
            seed_secret(str(self.source), str(self.root), "../credential")


if __name__ == "__main__":
    unittest.main()
