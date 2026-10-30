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
        # The state machine is tested with a 30 s poll and a 15-minute heartbeat (finer than the
        # 5-minute defaults); pass None for either to use the default.
        settings = {"SENSOR_BRIDGE_POLL_SECONDS": "30", "SENSOR_BRIDGE_HEARTBEAT_SECONDS": "900", **settings}
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

    def test_default_settings_sample_every_sensor_every_five_minutes(self):
        h = Harness(SENSOR_BRIDGE_POLL_SECONDS=None, SENSOR_BRIDGE_HEARTBEAT_SECONDS=None)
        self.assertEqual((h.config.poll_seconds, h.config.heartbeat_seconds), (300, 300))
        h.run(0, 899)
        self.assertEqual(len(h.hub.calls), 1 + 3, "one connect, then a poll at 0, 300 and 600 s only")
        self.assertEqual(h.sent(), [(cid(1), "change"), (cid(2), "change"),
                                    (cid(1), "heartbeat"), (cid(2), "heartbeat"),
                                    (cid(1), "heartbeat"), (cid(2), "heartbeat")],
                         "unchanged sensors still give one reading per poll")
        h.hub.update(1, temperature=21.9)
        h.run(900, 1199)
        self.assertEqual(h.sent()[6:], [(cid(1), "change"), (cid(2), "heartbeat")])
        self.assertEqual(sorted({r["measured_at"] for p in h.poster.payloads for r in p["readings"]}),
                         ["2026-10-03T04:00:00Z", "2026-10-03T04:05:00Z", "2026-10-03T04:10:00Z",
                          "2026-10-03T04:15:00Z"], "one row per sensor every 5 minutes")

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


class OfflineSensorTest(unittest.TestCase):
    def harness(self, **statuses):
        return Harness(FakeHub(children=[child(1, online=statuses.get("a")), child(2, online=statuses.get("b")),
                                         child(3, online=statuses.get("c"))]))

    def events(self, logs):
        return [m for m in logs.output if "event=sensor_" in m]

    def test_an_offline_sensor_is_never_posted_but_the_others_are(self):
        h = self.harness(a=False, b=True)  # c: status unknown
        h.run(0, 1800, 30)
        sent = h.sent()
        self.assertNotIn(cid(1), [i for i, _ in sent], "no change, no heartbeat, even after the heartbeat interval")
        self.assertEqual(sent[:2], [(cid(2), "change"), (cid(3), "change")])
        self.assertEqual(sent[2:], [(cid(2), "heartbeat"), (cid(3), "heartbeat")] * 2)
        self.assertIsNone(h.detector.db.execute("SELECT 1 FROM last_sent WHERE external_id=?", (cid(1),)).fetchone())

    def test_transitions_are_logged_once(self):
        h = self.harness(a=False)
        with self.assertLogs("sensor_bridge", "INFO") as logs:
            h.run(0, 120, 30)
            self.assertEqual(len(self.events(logs)), 1)
            self.assertIn(f"event=sensor_offline hub={h.hub.hub_id} sensor={cid(1)} name='TH1'", self.events(logs)[0])
            h.hub.update(1, online=True)
            h.run(150, 300, 30)
            h.hub.update(1, online=None)  # unknown status after online: nothing new
            h.run(330, 400, 30)
        events = self.events(logs)
        self.assertEqual(len(events), 2)
        self.assertIn(f"event=sensor_online hub={h.hub.hub_id} sensor={cid(1)} name='TH1'", events[1])

    def test_unknown_status_after_offline_counts_as_back_online(self):
        h = self.harness(a=False)
        with self.assertLogs("sensor_bridge", "INFO") as logs:
            h.run(0, 60, 30)
            h.hub.update(1, online=None)
            h.run(90, 150, 30)
        self.assertEqual([m.split("event=")[1].split()[0] for m in self.events(logs)], ["sensor_offline", "sensor_online"])

    def test_nothing_is_logged_for_a_sensor_that_was_never_offline(self):
        h = self.harness(a=True)
        with self.assertLogs("sensor_bridge", "INFO") as logs:
            h.run(0, 120, 30)
        self.assertEqual(self.events(logs), [])

    def test_back_online_with_the_same_value_sends_a_heartbeat_only_when_due(self):
        h = self.harness(a=True)
        h.run(0)
        h.hub.update(1, online=False)
        h.run(30, 1000, 30)  # the 900 s heartbeat interval passes while it is offline
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change"])
        h.hub.update(1, online=True)
        h.run(1020)
        self.assertEqual([(k, r["measured_at"]) for p in h.poster.payloads[-1:] for r in p["readings"]
                          for k in [r["kind"]] if r["external_id"] == cid(1)],
                         [("heartbeat", "2026-10-03T04:17:00Z")])
        h.run(1050, 1700, 30)
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change", "heartbeat"], "not due again yet")

    def test_back_online_before_the_interval_sends_nothing(self):
        h = self.harness(a=True)
        h.run(0)
        h.hub.update(1, online=False)
        h.run(30, 1000, 30)  # the 900 s heartbeat interval passes while it is offline
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change"], "no heartbeat while offline")
        h.hub.update(1, online=True)
        h.run(1020)
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change", "heartbeat"], "due on return")
        h.hub.update(1, online=False)
        h.run(1050, 1200, 30)
        h.hub.update(1, online=True)
        h.run(1230, 1700, 30)
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change", "heartbeat"], "not due yet on return")

    def test_back_online_with_a_new_value_is_a_change(self):
        h = self.harness(a=True)
        h.run(0)
        h.hub.update(1, online=False, temperature=25.0)  # the value changes while it is offline
        h.run(30, 120, 30)
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change"], "nothing sent while offline")
        h.hub.update(1, online=True)
        h.run(150)
        self.assertEqual([k for i, k in h.sent() if i == cid(1)], ["change", "change"])
        self.assertEqual(h.poster.readings()[0]["temperature"], 25.0)

    def test_restart_with_an_offline_sensor_re_emits_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            settings = {"SENSOR_BRIDGE_QUEUE_PATH": os.path.join(tmp, "b.sqlite3")}
            kids = [child(1, online=False), child(2, online=True)]
            first = Harness(FakeHub(children=kids), db=open_db(settings["SENSOR_BRIDGE_QUEUE_PATH"]), **settings)
            first.run(0, 60, 30)
            first.db.close()
            second = Harness(FakeHub(children=kids), db=open_db(settings["SENSOR_BRIDGE_QUEUE_PATH"]), **settings)
            second.run(90, 1000, 30)  # past the 900 s heartbeat interval
            self.assertEqual(second.sent(), [(cid(2), "heartbeat")], "only the online neighbour")
            second.db.close()


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


class NetHarness:
    """Several runners on a FakeNetwork, with the sweep switched on for 10.0.0.0/24."""

    def __init__(self, net: FakeNetwork, hosts: list[str], db=None, poster: FakePoster | None = None, **settings):
        from sensor_bridge.locate import Locator

        settings = {"SENSOR_BRIDGE_HUBS": ",".join(hosts), "SENSOR_BRIDGE_POLL_SECONDS": "30",
                    "SENSOR_BRIDGE_HEARTBEAT_SECONDS": "900", **settings}
        self.config = config(**settings)
        self.net, self.clock = net, Clock()
        self.db = db or open_db(":memory:")
        self.queue = Queue(self.db)
        self.detector = ChangeDetector(self.db, self.config.heartbeat_seconds)

        async def probe(host):
            return await net.factory(host).identify()

        self.locator = Locator(self.config.scan, probe, net.tcp)
        self.runners = [HubRunner(h, net.factory(h), self.detector, self.queue, self.config, self.locator, net.factory)
                        for h in hosts]
        self.locator.runners = self.runners
        self.poster = poster or FakePoster()
        delivery = Delivery(self.queue, self.poster, self.config.bridge_id, self.config.max_batch, run_inline)
        self.bridge = Bridge(self.runners, delivery, self.queue, self.clock)

    def run(self, start: float, end: float, every: float = 5) -> None:
        async def go():
            at = start
            while at <= end:
                self.clock.now = T0 + at
                await self.bridge.tick()
                at += every
        asyncio.run(go())

    def last_hub_post(self, hub_id: str) -> dict:
        return [p["hub"] for p in self.poster.payloads if p["hub"]["id"] == hub_id][-1]


class RelocateTest(unittest.TestCase):
    def test_a_hub_that_changed_address_is_found_and_reported_with_the_new_host(self):
        hub = FakeHub(hub_id="HUB-A", children=[child(1)])
        net = FakeNetwork(**{"10_0_0_10": hub})
        h = NetHarness(net, ["10.0.0.10"])
        h.run(0, 30)
        self.assertEqual(h.last_hub_post("HUB-A")["host"], "10.0.0.10")
        net.move(hub, "10.0.0.34")
        with self.assertLogs("sensor_bridge", "INFO") as logs:
            h.run(31, 300)
        self.assertIn("event=hub_moved hub=HUB-A old=10.0.0.10 new=10.0.0.34", "\n".join(logs.output))
        runner = h.runners[0]
        self.assertEqual((runner.host, runner.state), ("10.0.0.34", POLLING))
        self.assertEqual(h.last_hub_post("HUB-A"), {"id": "HUB-A", "host": "10.0.0.34", "online": True,
                                                    "firmware": "1.4.0"})
        self.assertEqual(h.detector.get("host_of:HUB-A"), "10.0.0.10 10.0.0.34")

    def test_the_move_survives_a_restart_and_the_outbox_is_kept(self):
        hub = FakeHub(hub_id="HUB-A", children=[child(1)])
        net = FakeNetwork(**{"10_0_0_10": hub})
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "b.sqlite3")
            first = NetHarness(net, ["10.0.0.10"], db=open_db(path), poster=FakePoster(500, 500, 500, 500, 500, 500))
            first.run(0, 30)
            net.move(hub, "10.0.0.34")
            first.run(31, 300)
            self.assertGreater(first.queue.size(), 0, "the backend is down: readings wait in the outbox")
            queued = first.queue.size()
            first.db.close()
            second = NetHarness(net, ["10.0.0.10"], db=open_db(path))
            self.assertEqual(second.runners[0].host, "10.0.0.34", "starts at the last known address")
            self.assertEqual(second.queue.size(), queued)
            second.run(400, 430)
            self.assertEqual(second.runners[0].state, POLLING)
            second.db.close()

    def test_a_changed_configuration_ignores_the_stored_move(self):
        hub = FakeHub(hub_id="HUB-A", children=[child(1)])
        net = FakeNetwork(**{"10_0_0_10": hub})
        h = NetHarness(net, ["10.0.0.10"])
        h.run(0, 30)
        net.move(hub, "10.0.0.34")
        h.run(31, 300)
        again = NetHarness(net, ["10.0.0.34"], db=h.db)
        self.assertEqual(again.runners[0].host, "10.0.0.34")
        other = NetHarness(net, ["10.0.0.77"], db=h.db)
        self.assertEqual(other.runners[0].host, "10.0.0.77")

    def test_two_hubs_that_swapped_addresses_end_up_on_each_others_address(self):
        a, b = FakeHub(hub_id="HUB-A", children=[child(1)]), FakeHub(hub_id="HUB-B", children=[child(2)])
        net = FakeNetwork(**{"10_0_0_10": a, "10_0_0_11": b})
        h = NetHarness(net, ["10.0.0.10", "10.0.0.11"])
        h.run(0, 30)
        net.hubs["10.0.0.10"], net.hubs["10.0.0.11"] = b, a
        h.run(31, 400)
        self.assertEqual([(r.hub_id, r.host, r.state) for r in h.runners],
                         [("HUB-A", "10.0.0.11", POLLING), ("HUB-B", "10.0.0.10", POLLING)])
        self.assertEqual(h.last_hub_post("HUB-A")["host"], "10.0.0.11")
        self.assertEqual(h.last_hub_post("HUB-B")["host"], "10.0.0.10")

    def test_without_a_sweep_a_swap_is_adopted_as_before(self):
        a, b = FakeHub(hub_id="HUB-A", children=[child(1)]), FakeHub(hub_id="HUB-B", children=[child(2)])
        net = FakeNetwork(**{"10_0_0_10": a, "10_0_0_11": b})
        h = NetHarness(net, ["10.0.0.10", "10.0.0.11"], SENSOR_BRIDGE_SCAN="off")
        h.run(0, 30)
        net.hubs["10.0.0.10"], net.hubs["10.0.0.11"] = b, a
        h.run(31, 100)
        self.assertEqual([(r.hub_id, r.host) for r in h.runners], [("HUB-B", "10.0.0.10"), ("HUB-A", "10.0.0.11")])

    def test_a_never_reached_hub_is_claimed_when_it_appears_and_keeps_one_owner(self):
        net = FakeNetwork(**{"10_0_0_10": FakeHub(hub_id="HUB-A", children=[child(1)])})
        h = NetHarness(net, ["10.0.0.10", "10.0.0.58"])
        h.run(0, 60)
        late = FakeHub(hub_id="HUB-C", children=[child(3)])
        self.assertEqual(h.runners[1].state, OFFLINE)
        self.assertEqual(h.last_hub_post("10.0.0.58")["online"], False, "reported under its address until found")
        net.hubs["10.0.0.200"] = late
        with self.assertLogs("sensor_bridge", "INFO") as logs:
            h.run(61, 900)
        self.assertIn("event=hub_moved hub=HUB-C old=10.0.0.58 new=10.0.0.200 claimed=true", "\n".join(logs.output))
        self.assertEqual([(r.hub_id, r.host) for r in h.runners], [("HUB-A", "10.0.0.10"), ("HUB-C", "10.0.0.200")])
        self.assertEqual(h.last_hub_post("HUB-C")["online"], True)
        self.assertEqual(h.detector.get("hub_id:10.0.0.58"), "HUB-C")

    def test_a_hub_that_appears_at_the_configured_address_is_simply_connected(self):
        net = FakeNetwork(**{"10_0_0_10": FakeHub(hub_id="HUB-A")})
        h = NetHarness(net, ["10.0.0.10", "10.0.0.58"])
        h.run(0, 30)
        net.hubs["10.0.0.58"] = FakeHub(hub_id="HUB-C", children=[child(3)])
        h.run(31, 100)
        self.assertEqual([(r.hub_id, r.host) for r in h.runners], [("HUB-A", "10.0.0.10"), ("HUB-C", "10.0.0.58")])

    def test_relocation_waits_for_the_interval_between_sweeps(self):
        net = FakeNetwork(**{"10_0_0_10": FakeHub(hub_id="HUB-A", children=[child(1)])})
        h = NetHarness(net, ["10.0.0.10"], SENSOR_BRIDGE_RELOCATE_SECONDS="600")
        h.run(0, 30)
        net.hubs.clear()
        h.run(31, 1500)
        sweeps = len(net.tcp_calls) // 254
        self.assertEqual(sweeps, 3, "first when OFFLINE, then every 600 s")
