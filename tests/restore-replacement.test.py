"""Failure gates for the v4 replacement-host restore helpers."""

import io
from collections import Counter
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
restore = SourceFileLoader("restore_replacement", str(ROOT / "scripts/restore-replacement.py")).load_module()


class RestoreFailureGates(unittest.TestCase):
    def test_realtime_partition_grants_require_archived_pattern_and_daily_bounds(self):
        today = datetime.now(timezone.utc).date()
        archived = Counter()
        peers = {}
        catalog = {}
        def row(name, day, owner="realtime_admin", is_partition=True):
            return {"name": name, "kind": "r", "is_partition": is_partition,
                    "owner": owner, "parent_schema": "realtime" if is_partition else None,
                    "parent_name": "messages" if is_partition else None,
                    "bound": (f"FOR VALUES FROM ('{day.isoformat()} 00:00:00') "
                              f"TO ('{(day + timedelta(days=1)).isoformat()} 00:00:00')") if is_partition else None,
                    "row_security": False, "force_row_security": False,
                    "persistence": "p", "replica_identity": "d", "options": None}
        for day in (today - timedelta(days=2), today - timedelta(days=1)):
            name = "messages_" + day.strftime("%Y_%m_%d")
            table = "realtime." + name
            peers[name] = "realtime_admin"
            catalog[name] = row(name, day)
            for role in ("postgres", "realtime_admin"):
                archived[f"GRANT ALL ON TABLE {table} TO {role};"] += 1
        partition_day = today + timedelta(days=3)
        name = "messages_" + partition_day.strftime("%Y_%m_%d")
        table = "realtime." + name
        catalog[name] = row(name, partition_day)
        extra = Counter({f"GRANT ALL ON TABLE {table} TO {role};": 1
                         for role in ("postgres", "realtime_admin")})
        check = restore.reviewed_realtime_partition_grants
        self.assertEqual(check(archived, archived + extra, peers, catalog), 2)
        for unexpected in (
                Counter({"GRANT ALL ON TABLE public.orders TO anon;": 1}),
                Counter({"REVOKE ALL ON TABLE public.orders FROM anon;": 1}),
                Counter({f"GRANT ALL ON TABLE {table} TO anon;": 1})):
            with self.assertRaises(ValueError):
                check(archived, archived + extra + unexpected, peers, catalog)
        # An unexecuted function-body ATTACH string cannot supply a catalog link.
        with self.assertRaises(ValueError):
            check(archived, archived + extra, peers,
                  catalog | {name: row(name, partition_day, is_partition=False)})
        with self.assertRaises(ValueError):
            check(archived, archived + extra, peers,
                  catalog | {name: row(name, partition_day, owner="anon")})
        with self.assertRaises(ValueError):
            check(archived, archived + extra, peers,
                  catalog | {name: row(name, partition_day) | {"bound": "FOR VALUES IN ('wrong')"}})
        one_peer = next(iter(peers))
        with self.assertRaises(ValueError):
            check(archived + Counter({f"GRANT SELECT ON TABLE realtime.{one_peer} TO anon;": 1}),
                  archived + extra + Counter({f"GRANT SELECT ON TABLE realtime.{one_peer} TO anon;": 1}),
                  peers, catalog)

    def test_storage_catalog_matches_multiple_versions_and_rejects_strays(self):
        with tempfile.TemporaryDirectory() as empty:
            self.assertEqual(restore.match_storage_catalog(Path(empty), []), [])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = [
                {"bucket_id": "documents", "name": "a/first.pdf", "version": "version-1"},
                {"bucket_id": "documents", "name": "b/second.pdf", "version": "version-2"},
            ]
            for row in rows:
                path = root / "tenant" / "stub" / row["bucket_id"] / row["name"] / row["version"]
                path.parent.mkdir(parents=True)
                path.write_bytes(b"private document")
            self.assertEqual(len(restore.match_storage_catalog(root, rows)), 2)
            stray = root / "tenant" / "stub" / "documents" / "stray"
            stray.write_bytes(b"unaccounted")
            with self.assertRaises(ValueError):
                restore.match_storage_catalog(root, rows)
            with self.assertRaises(ValueError):
                restore.match_storage_catalog(root, [{"bucket_id": "documents", "name": "../escape", "version": "v"}])
            stray.unlink()
            stray.symlink_to("/etc/passwd")
            with self.assertRaises(ValueError):
                restore.match_storage_catalog(root, rows)

    def test_saved_environment_rejects_duplicates_and_interpolation(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "compose.env"
            for text in ("A=one\nA=two\n", "A=$(unsafe)\n", "A=`unsafe`\n"):
                source.write_text(text)
                with self.assertRaises(ValueError):
                    restore.read_env(source)

    def test_data_comparison_detects_missing_rows_and_sequence_change(self):
        with tempfile.TemporaryDirectory() as directory:
            original = Path(directory) / "source.sql"
            actual = Path(directory) / "target.sql"
            original.write_text("COPY public.items (id) FROM stdin;\n1\n2\n\\.\nSELECT pg_catalog.setval('public.items_id_seq', 2, true);\n")
            actual.write_text("COPY public.items (id) FROM stdin;\n2\n1\n\\.\nSELECT pg_catalog.setval('public.items_id_seq', 2, true);\n")
            self.assertEqual(restore.compare_data(original, actual), {"tables": 1, "rows": 2, "sequences": 1})
            actual.write_text("COPY public.items (id) FROM stdin;\n1\n\\.\nSELECT pg_catalog.setval('public.items_id_seq', 2, true);\n")
            with self.assertRaises(ValueError):
                restore.compare_data(original, actual)
            actual.write_text("COPY public.items (id) FROM stdin;\n1\n2\n\\.\nSELECT pg_catalog.setval('public.items_id_seq', 3, true);\n")
            with self.assertRaises(ValueError):
                restore.compare_data(original, actual)

    def test_intake_rejects_traversal_and_links(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("secret-link", tarfile.SYMTYPE)):
            with self.subTest(name=name):
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode="w") as archive:
                    entry = tarfile.TarInfo(name)
                    entry.type = kind
                    entry.linkname = "outside" if kind == tarfile.SYMTYPE else ""
                    archive.addfile(entry, io.BytesIO() if kind == tarfile.REGTYPE else None)
                data.seek(0)
                with tarfile.open(fileobj=data, mode="r:") as archive:
                    with self.assertRaises(ValueError):
                        restore.prep.safe_members(archive)


if __name__ == "__main__":
    unittest.main()
