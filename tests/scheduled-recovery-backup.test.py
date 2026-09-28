import importlib.machinery
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timedelta, timezone


ROOT = Path(__file__).resolve().parents[1]
job = importlib.machinery.SourceFileLoader(
    "scheduled_recovery_backup", str(ROOT / "scripts/scheduled-recovery-backup.py")
).load_module()


class ScheduledBackupGates(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.archives = root / "archives"
        self.locals = root / "local"
        self.archives.mkdir(mode=0o700)
        self.locals.mkdir(mode=0o700)
        self.config = {
            "archive_dir": self.archives,
            "local_backup_dir": self.locals,
            "mount_uuid": "f6e91b05-8797-48c7-ab07-96da97bcb11c",
            "minimum_generations": 2,
            "retention_hours": 48,
            "freshness_minutes": 50,
        }
        self.now = datetime.now(timezone.utc)

    def add(self, hours_ago, suffix):
        when = self.now - timedelta(hours=hours_ago)
        # Keep the production basename shape while varying seconds for fixtures.
        name = "warehouse-" + (when + timedelta(seconds=suffix)).strftime("%Y%m%dT%H%M%SZ")
        archive = self.archives / (name + ".tar")
        archive.write_bytes(b"backup-" + str(suffix).encode())
        archive.chmod(0o600)
        receipt = self.archives / (name + ".tar.receipt.json")
        receipt.write_text(json.dumps({
            "backup_name": name,
            "created_at": when.isoformat(),
            "mount_uuid": self.config["mount_uuid"],
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        }))
        receipt.chmod(0o600)
        (self.locals / name).mkdir()
        return archive, receipt, self.locals / name

    def test_expiry_only_prunes_recorded_old_generation_after_two_verified_newer(self):
        old = self.add(72, 1)
        recent = self.add(0.5, 2)
        newest = self.add(0.05, 3)
        unrelated = self.archives / "Archive.zip"
        unrelated.write_bytes(b"keep")
        with patch.object(job, "check_mount"):
            self.assertEqual(job.prune(self.config, self.now), 1)
        self.assertTrue(all(not path.exists() for path in old))
        self.assertTrue(all(path.exists() for path in recent + newest))
        self.assertEqual(unrelated.read_bytes(), b"keep")

    def test_stale_latest_backup_blocks_pruning(self):
        old = self.add(72, 1)
        self.add(3, 2)
        self.add(2, 3)
        with patch.object(job, "check_mount"):
            with self.assertRaisesRegex(RuntimeError, "stale"):
                job.prune(self.config, self.now)
        self.assertTrue(all(path.exists() for path in old))

    def test_missing_mount_fails_before_writes(self):
        self.config["mountpoint"] = self.archives
        self.config["archive_dir"] = self.archives / "subdir"
        self.config["archive_dir"].mkdir()
        with self.assertRaisesRegex(RuntimeError, "not mounted"):
            job.check_mount(self.config)

    def test_receipt_write_remains_private_with_permissive_caller_umask(self):
        path = self.archives / "receipt.json"
        original = os.umask(0o022)
        try:
            job.atomic_json(path, {"ok": True})
        finally:
            os.umask(original)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
