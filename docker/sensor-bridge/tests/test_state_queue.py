# SPDX-License-Identifier: GPL-3.0-or-later
import os
import tempfile
import unittest

from sensor_bridge.queue import Queue, open_db
from sensor_bridge.state import ChangeDetector

from .fakes import T0, child, cid


def reading(n: int, measured_at: str = "2026-10-03T04:00:00Z", **extra) -> dict:
    return {"external_id": cid(n), "measured_at": measured_at, "temperature": 21.5, **extra}


class ChangeDetectorTest(unittest.TestCase):
    def setUp(self):
        self.db = open_db(":memory:")
        self.detector = ChangeDetector(self.db, heartbeat_seconds=900)

    def observe(self, c, at):
        kind = self.detector.observe(c, at)
        self.db.commit()
        return kind

    def test_first_sight_is_a_change_then_nothing_until_a_value_changes(self):
        self.assertEqual(self.observe(child(1), T0), "change")
        self.assertIsNone(self.observe(child(1), T0 + 30))
        self.assertIsNone(self.observe(child(1), T0 + 899))
        self.assertEqual(self.observe(child(1, temperature=21.6), T0 + 900 - 1), "change")
        self.assertEqual(self.observe(child(1, temperature=21.6, humidity=61.0), T0 + 930), "change")

    def test_heartbeat_when_nothing_changed_for_the_interval(self):
        self.assertEqual(self.observe(child(1), T0), "change")
        self.assertIsNone(self.observe(child(1), T0 + 899))
        self.assertEqual(self.observe(child(1), T0 + 900), "heartbeat")
        # The heartbeat restarts the interval.
        self.assertIsNone(self.observe(child(1), T0 + 1500))
        self.assertEqual(self.observe(child(1), T0 + 1800), "heartbeat")

    def test_a_change_restarts_the_heartbeat_interval(self):
        self.observe(child(1), T0)
        self.assertEqual(self.observe(child(1, temperature=22.0), T0 + 600), "change")
        self.assertIsNone(self.observe(child(1, temperature=22.0), T0 + 900))
        self.assertEqual(self.observe(child(1, temperature=22.0), T0 + 1500), "heartbeat")

    def test_battery_flip_is_a_change_both_ways(self):
        self.observe(child(1, battery_low=False), T0)
        self.assertEqual(self.observe(child(1, battery_low=True), T0 + 30), "change")
        self.assertIsNone(self.observe(child(1, battery_low=True), T0 + 60))
        self.assertEqual(self.observe(child(1, battery_low=False), T0 + 90), "change")

    def test_a_value_that_disappears_is_a_change(self):
        self.observe(child(1), T0)
        self.assertEqual(self.observe(child(1, humidity=None), T0 + 30), "change")
        self.assertIsNone(self.observe(child(1, humidity=None), T0 + 60))

    def test_sensors_are_independent(self):
        self.observe(child(1), T0)
        self.assertEqual(self.observe(child(2), T0 + 30), "change")
        self.assertIsNone(self.observe(child(1), T0 + 30))

    def test_uncommitted_decision_is_lost_with_a_crash(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "b.sqlite3")
            db = open_db(path)
            ChangeDetector(db, 900).observe(child(1), T0)
            db.close()  # no commit: as if the process died before Queue.put
            again = open_db(path)
            self.assertEqual(ChangeDetector(again, 900).observe(child(1), T0 + 30), "change")
            again.close()

    def test_restart_re_emits_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "b.sqlite3")
            db = open_db(path)
            detector = ChangeDetector(db, 900)
            self.assertEqual(detector.observe(child(1), T0), "change")
            Queue(db).put("h", [reading(1)], T0)  # commits
            db.close()
            db = open_db(path)
            detector = ChangeDetector(db, 900)
            self.assertIsNone(detector.observe(child(1), T0 + 60))
            self.assertEqual(detector.observe(child(1), T0 + 900), "heartbeat")
            db.close()

    def test_meta_values_persist(self):
        self.detector.set("reboot:h", "1")
        self.detector.set("reboot:h", "2")
        self.assertEqual(self.detector.get("reboot:h"), "2")
        self.assertIsNone(self.detector.get("other"))


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.queue = Queue(open_db(":memory:"))

    def test_same_reading_twice_is_kept_once(self):
        self.assertEqual(self.queue.put("h", [reading(1), reading(2)], T0), 2)
        self.assertEqual(self.queue.put("h", [reading(1)], T0), 0)
        self.assertEqual(self.queue.size(), 2)

    def test_take_is_oldest_first_and_removes_nothing_until_ack(self):
        self.queue.set_hub("h", {"id": "H"})
        self.queue.put("h", [reading(n, f"2026-10-03T04:00:0{n}Z") for n in range(1, 6)], T0)
        hub, version, rows = self.queue.take("h", 3)
        self.assertEqual(hub, {"id": "H"})
        self.assertEqual(version, 1)
        self.assertEqual([r["external_id"] for _, r in rows], [cid(1), cid(2), cid(3)])
        self.assertEqual(self.queue.size(), 5)
        self.queue.ack("h", [i for i, _ in rows], version)
        hub, version, rows = self.queue.take("h", 3)
        self.assertEqual(version, 0, "the hub status was sent")
        self.assertEqual([r["external_id"] for _, r in rows], [cid(4), cid(5)])

    def test_queue_survives_a_restart(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "b.sqlite3")
            db = open_db(path)
            queue = Queue(db)
            queue.set_hub("h", {"id": "H", "online": True})
            queue.put("h", [reading(1), reading(2)], T0)
            db.close()
            queue = Queue(open_db(path))
            self.assertEqual(queue.size(), 2)
            self.assertEqual(queue.pending_hubs(), ["h"])
            hub, version, rows = queue.take("h", 10)
            self.assertEqual((hub, version, len(rows)), ({"id": "H", "online": True}, 1, 2))
            self.assertEqual(rows[0][1], reading(1))
            queue.db.close()

    def test_hub_status_is_pending_only_when_it_changed_or_is_forced(self):
        self.assertTrue(self.queue.set_hub("h", {"online": True}))
        self.queue.ack("h", [], self.queue.take("h", 1)[1])
        self.assertEqual(self.queue.pending_hubs(), [])
        self.assertFalse(self.queue.set_hub("h", {"online": True}))
        self.assertEqual(self.queue.pending_hubs(), [])
        self.assertTrue(self.queue.set_hub("h", {"online": True}, force=True))
        self.assertEqual(self.queue.pending_hubs(), ["h"])

    def test_a_status_change_during_a_send_is_not_lost(self):
        self.queue.set_hub("h", {"online": True})
        _, version, _ = self.queue.take("h", 1)
        self.queue.set_hub("h", {"online": False})  # while the post was on its way
        self.queue.ack("h", [], version)
        self.assertEqual(self.queue.take("h", 1)[:2], ({"online": False}, 2))

    def test_refusals_drop_after_the_limit(self):
        self.queue.set_hub("h", {"id": "H"})
        self.queue.put("h", [reading(1)], T0)
        ids = [i for i, _ in self.queue.take("h", 10)[2]]
        self.assertEqual(self.queue.fail("h", ids, 1), 0)
        self.assertEqual(self.queue.fail("h", ids, 1), 0)
        self.assertEqual(self.queue.fail("h", ids, 1), 1)
        self.assertEqual(self.queue.size(), 0)
        self.assertEqual(self.queue.pending_hubs(), [], "the hub status is given up too")

    def test_prune_drops_old_rows_and_the_oldest_over_the_cap(self):
        self.queue.max_rows = 3
        self.queue.put("h", [reading(1)], T0 - 40 * 86400)
        self.queue.put("h", [reading(n) for n in range(2, 7)], T0)
        self.assertEqual(self.queue.prune(T0, 29 * 86400), 3)
        self.assertEqual([r["external_id"] for _, r in self.queue.take("h", 10)[2]], [cid(4), cid(5), cid(6)])


if __name__ == "__main__":
    unittest.main()


class RekeyTest(unittest.TestCase):
    def test_rekey_moves_readings_and_drops_the_old_status(self):
        queue = Queue(open_db(":memory:"))
        queue.set_hub("10.0.0.5", {"id": "10.0.0.5"})
        queue.put("10.0.0.5", [{"external_id": "S1", "measured_at": "2026-10-03T04:00:00Z"}], 1.0)
        queue.rekey("10.0.0.5", "HUBID")
        self.assertEqual(queue.pending_hubs(), ["HUBID"])
        self.assertEqual(queue.take("10.0.0.5", 10)[0], None)
        self.assertEqual(len(queue.take("HUBID", 10)[2]), 1)
        queue.rekey("HUBID", "HUBID")  # same key: nothing happens
        self.assertEqual(queue.size(), 1)
