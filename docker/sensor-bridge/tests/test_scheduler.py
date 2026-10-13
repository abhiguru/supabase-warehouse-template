# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import json
import os
import tempfile
import unittest

from sensor_bridge.__main__ import build
from sensor_bridge.poster import Delivery
from sensor_bridge.queue import Queue, open_db
from sensor_bridge.scheduler import OFFLINE, POLLING, REBOOTING, Bridge, HubRunner
from sensor_bridge.state import ChangeDetector

from .fakes import T0, Clock, FakeHub, FakePoster, child, cid, config, run_inline

HOST = "192.0.2.10"


class Harness:
    def __init__(self, hub: FakeHub | None = None, poster: FakePoster | None = None, db=None, **settings):
        self.config = config(**settings)
        self.clock = Clock()
        self.db = db or open_db(":memory:")
        self.queue = Queue(self.db)
        self.detector = ChangeDetector(self.db, self.config.heartbeat_seconds)
        self.hub = hub or FakeHub(children=[child(1), child(2)])
        self.runner = HubRunner(HOST, self.hub, self.detector, self.queue, self.config)
        self.poster = poster or FakePoster()
        delivery = Delivery(self.queue, self.poster, self.config.bridge_id, self.config.max_batch, run_inline)
        self.bridge = Bridge([self.runner], delivery, self.queue, self.clock)

    def run(self, start: float, end: float | None = None, every: float = 1) -> None:
        """Tick at start (and every `every` seconds up to end), seconds after T0."""
        async def go():
            at = start
            while True:
                self.clock.now = T0 + at
                await self.bridge.tick()
                at += every
                if end is None or at > end:
                    return
        asyncio.run(go())

    def sent(self) -> list[tuple[str, str]]:
        """(external_id, kind) of every reading posted so far."""
        return [(r["external_id"], r["kind"]) for p in self.poster.payloads for r in p["readings"]]

    def hub_posts(self) -> list[bool]:
        return [p["hub"]["online"] for p in self.poster.payloads]


class ChangeAndHeartbeatTest(unittest.TestCase):
    def test_first_poll_posts_every_sensor_and_the_hub(self):
        h = Harness()
        h.run(0)
        payload = h.poster.payloads[0]
        self.assertEqual(payload["hub"], {"id": h.hub.hub_id, "host": HOST, "online": True, "firmware": "1.4.0"})
        self.assertEqual(payload["readings"][0], {
            "external_id": cid(1), "name": "TH1", "model": "T310", "temperature": 21.5, "humidity": 60.0,
            "measured_at": "2026-10-03T04:00:00Z", "battery_low": False, "battery_percent": None,
            "signal_level": 3, "report_interval_s": 16, "kind": "change"})
        self.assertEqual(h.sent(), [(cid(1), "change"), (cid(2), "change")])

    def test_only_changes_until_the_heartbeat_falls_due(self):
        h = Harness()
        h.run(0, 299)
        self.assertEqual(len(h.hub.calls), 1 + 10, "one connect, then a poll every 30 s")
        self.assertEqual(len(h.sent()), 2, "unchanged values are not sent again")
        h.hub.update(1, temperature=21.7)
        h.run(300, 899)
        self.assertEqual(h.sent()[2:], [(cid(1), "change")])
        self.assertEqual(h.poster.payloads[-1]["readings"][0]["measured_at"], "2026-10-03T04:05:00Z")
        h.run(900, 1199)
        self.assertEqual(h.sent()[3:], [(cid(2), "heartbeat")], "sensor 2 unchanged for 15 minutes")
        h.run(1200, 1800)
        self.assertEqual(h.sent()[4:], [(cid(1), "heartbeat"), (cid(2), "heartbeat")])

    def test_battery_flip_is_sent_at_once(self):
        h = Harness()
        h.run(0)
        h.hub.update(2, battery_low=True)
        h.run(30)
        self.assertEqual(h.sent()[2:], [(cid(2), "change")])
        self.assertTrue(h.poster.readings()[0]["battery_low"])

    def test_a_sensor_with_no_values_is_not_sent(self):
        h = Harness(FakeHub(children=[child(1, temperature=None, humidity=None), child(2)]))
        h.run(0)
        self.assertEqual(h.sent(), [(cid(2), "change")])

    def test_restart_re_emits_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = {"SENSOR_BRIDGE_QUEUE_PATH": os.path.join(tmp, "b.sqlite3")}
            first = Harness(db=open_db(settings["SENSOR_BRIDGE_QUEUE_PATH"]), **settings)
            first.run(0, 60, 30)
            self.assertEqual(len(first.sent()), 2)
            first.db.close()
            second = Harness(db=open_db(settings["SENSOR_BRIDGE_QUEUE_PATH"]), **settings)
            second.run(90, 600, 30)
            self.assertEqual(second.poster.payloads, [], "same values, same hub status: nothing to send")
            second.run(900)
            self.assertEqual(second.sent(), [(cid(1), "heartbeat"), (cid(2), "heartbeat")])
            second.db.close()

    def test_readings_wait_in_the_queue_while_the_backend_is_down(self):
        h = Harness(poster=FakePoster(*([503] * 4)))
        h.run(0)
        h.hub.update(1, temperature=22.0)
        h.run(30, 239)  # posts fail at 0, 30, 60 and 120; the next try is at 240
        self.assertEqual(h.queue.size(), 3)
        h.run(240)
        self.assertEqual(h.queue.size(), 0)
        self.assertEqual(h.sent()[-3:], [(cid(1), "change"), (cid(2), "change"), (cid(1), "change")])
        self.assertEqual(len(h.poster.payloads), 5)


class ConnectionStateTest(unittest.TestCase):
    def connect_times(self, h: Harness, start: float, end: float) -> list[float]:
        times = []
        for at in range(int(start), int(end) + 1):
            before = h.hub.calls.count("connect")
            h.run(at)
            if h.hub.calls.count("connect") > before:
                times.append(at)
        return times

    def test_connect_backs_off_from_5_s_to_5_min(self):
        h = Harness()
        h.hub.down = True
        self.assertEqual(self.connect_times(h, 0, 1000), [0, 5, 15, 35, 75, 155, 315, 615, 915])
        h.hub.down = False
        self.assertEqual(self.connect_times(h, 1001, 1300), [1215])
        self.assertEqual(h.runner.state, POLLING)

    def test_a_hub_never_reached_is_reported_offline_under_its_host(self):
        h = Harness()
        h.hub.down = True
        h.run(0, 15)
        self.assertEqual(h.runner.state, OFFLINE)
        self.assertEqual(h.poster.payloads[0]["hub"], {"id": HOST, "host": HOST, "online": False, "firmware": None})
        self.assertEqual(h.poster.payloads[0]["readings"], [])

    def test_three_failed_polls_go_offline_then_offline_heartbeats_then_back_online(self):
        h = Harness()
        h.run(0)
        h.hub.down = True
        h.run(1, 89)
        self.assertEqual(h.runner.state, POLLING, "two failed polls are tolerated")
        self.assertEqual(h.hub.calls.count("connect"), 1, "and retried on the same connection")
        h.run(90)
        self.assertEqual(h.runner.state, OFFLINE)
        self.assertEqual(h.hub_posts(), [True, False])
        self.assertEqual(h.poster.payloads[1]["hub"]["id"], h.hub.hub_id, "the id learnt while online")
        h.run(91, 1900, 5)
        self.assertEqual(h.hub_posts(), [True, False, False, False], "heartbeats at 990 and 1890")
        h.hub.down = False
        h.run(1901, 2300, 5)
        self.assertEqual(h.runner.state, POLLING)
        self.assertEqual(h.hub_posts(), [True, False, False, False, True])

    def test_a_single_failure_does_not_reach_the_backend(self):
        h = Harness()
        h.run(0)
        h.hub.fail_next = 2
        h.run(1, 120)
        self.assertEqual(h.runner.state, POLLING)
        self.assertEqual(h.hub_posts(), [True])

    def test_hub_status_is_repeated_every_heartbeat_while_online(self):
        h = Harness(FakeHub(children=[]))
        h.run(0, 1800, 30)
        self.assertEqual(h.hub_posts(), [True, True, True])

    def test_the_hub_id_learnt_once_is_used_after_a_restart_while_the_hub_is_down(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "b.sqlite3")
            first = Harness(db=open_db(path))
            first.run(0)
            first.db.close()
            second = Harness(FakeHub(hub_id="other"), db=open_db(path))
            second.hub.down = True
            second.run(60, 80)
            self.assertEqual(second.poster.payloads[-1]["hub"]["id"], first.hub.hub_id)
            second.db.close()


class RebootTest(unittest.TestCase):
    CRON = {"SENSOR_BRIDGE_REBOOT_CRON": "30 21 * * 6"}  # Saturday 21:30 UTC; T0 is Saturday 04:00
    AT = (17 * 60 + 30) * 60  # seconds from T0 to that minute

    def test_reboot_on_the_cron_once_then_reconnect(self):
        h = Harness(**self.CRON)
        h.run(0)
        h.run(self.AT - 30, self.AT + 59, 1)
        self.assertEqual(h.hub.calls.count("reboot"), 1, "once, although the minute had two poll slots")
        self.assertEqual(h.runner.state, REBOOTING)
        h.run(self.AT + 60, self.AT + 119)
        self.assertEqual(h.hub.calls.count("connect"), 1, "no reconnect before 2 minutes")
        h.run(self.AT + 120)
        self.assertEqual(h.runner.state, POLLING)
        self.assertNotIn(False, h.hub_posts(), "a planned reboot is not reported as an outage")

    def test_reboot_happens_once_a_week(self):
        h = Harness(FakeHub(children=[]), **self.CRON)
        h.run(0, 15 * 86400, 30)
        self.assertEqual(h.hub.calls.count("reboot"), 3, "Saturdays 3, 10 and 17 October")

    def test_failures_right_after_the_reboot_are_not_counted(self):
        h = Harness(**self.CRON)
        h.run(0)
        h.run(self.AT)
        h.hub.down = True
        h.run(self.AT + 1, self.AT + 299)
        self.assertEqual((h.runner.state, h.runner.failures), (REBOOTING, 0))
        h.run(self.AT + 300, self.AT + 400)
        self.assertEqual(h.runner.state, OFFLINE, "after the grace a dead hub is reported")
        self.assertEqual(h.hub_posts()[-1], False)

    def test_no_cron_no_reboot(self):
        h = Harness(FakeHub(children=[]))
        h.run(0, 8 * 86400, 60)
        self.assertEqual(h.hub.calls.count("reboot"), 0)


class BridgeTest(unittest.TestCase):
    def test_health_file_is_rewritten_every_tick(self):
        with tempfile.TemporaryDirectory() as tmp:
            h = Harness()
            h.bridge.health_path = os.path.join(tmp, "health.json")
            h.run(0)
            with open(h.bridge.health_path) as f:
                first = json.load(f)
            self.assertEqual(first["hubs"][HOST]["state"], POLLING)
            self.assertEqual((first["time"], first["queued"], first["delivery"]), ("2026-10-03T04:00:00Z", 0, "ok"))
            h.run(1)
            with open(h.bridge.health_path) as f:
                self.assertEqual(json.load(f)["time"], "2026-10-03T04:00:01Z")

    def test_once_polls_posts_and_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = config(SENSOR_BRIDGE_QUEUE_PATH=os.path.join(tmp, "b.sqlite3"))
            hub, poster = FakeHub(children=[child(1)]), FakePoster()
            bridge = build(cfg, lambda host: hub, poster, Clock())
            bridge.delivery.run_blocking = run_inline
            self.assertTrue(asyncio.run(bridge.once()))
            self.assertEqual(len(poster.readings()), 1)
            self.assertEqual(hub.calls[-1], "close")
            hub.down = True
            again = build(cfg, lambda host: hub, poster, Clock(T0 + 60))
            again.delivery.run_blocking = run_inline
            self.assertFalse(asyncio.run(again.once()))

    def test_an_unexpected_error_does_not_stop_the_loop(self):
        h = Harness()

        async def broken(now):
            raise RuntimeError("boom")

        h.runner.step = broken
        with self.assertLogs("sensor_bridge", "ERROR") as logs:
            h.run(0)
        self.assertIn("event=internal_error error=RuntimeError", logs.output[0])


if __name__ == "__main__":
    unittest.main()
