# SPDX-License-Identifier: GPL-3.0-or-later
import contextlib
import io
import json
import logging
import os
import tempfile
import unittest

from sensor_bridge.__main__ import main, setup_logging
from sensor_bridge.config import EX_CONFIG

from .fakes import FAKE_KEY, FAKE_PASSWORD, FAKE_QUERY, FakeHub, FakePoster, child, cid, env

SECRETS = (FAKE_KEY, FAKE_PASSWORD, FAKE_QUERY)


def run(argv, environment, **kwargs) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stderr(err):
        code = main(argv, environment, out=out, **kwargs)
    logging.getLogger().handlers[:] = []
    return code, out.getvalue(), err.getvalue()


class MainTest(unittest.TestCase):
    def assertNoSecret(self, text: str):
        for secret in SECRETS:
            self.assertNotIn(secret, text)

    def test_unconfigured_exits_78(self):
        for argv in ([], ["--once"], ["--check-config"], ["--dump"]):
            with self.subTest(argv=argv):
                code, out, err = run(argv, {})
                self.assertEqual(code, EX_CONFIG)
                self.assertIn("event=config_error", err)
                self.assertEqual(out, "")

    def test_invalid_setting_exits_78_without_echoing_it(self):
        code, _, err = run(["--check-config"], env(SENSOR_INGEST_KEY="not-a-key-" + FAKE_PASSWORD))
        self.assertEqual(code, EX_CONFIG)
        self.assertIn("SENSOR_INGEST_KEY", err)
        self.assertNoSecret(err)

    def test_check_config_prints_the_settings_without_secrets(self):
        code, out, err = run(["--check-config"], env(SENSOR_BRIDGE_REBOOT_CRON="30 21 * * 6"))
        self.assertEqual(code, 0)
        summary = json.loads(out)
        self.assertEqual(summary["hubs"], ["192.0.2.10"])
        self.assertEqual(summary["reboot_cron_utc"], "30 21 * * 6")
        self.assertEqual(summary["ingest_key"], "set")
        self.assertNoSecret(out + err)

    def test_dump_prints_every_child_and_posts_nothing(self):
        hubs = {"192.0.2.10": FakeHub(children=[child(1), child(2)]), "192.0.2.11": FakeHub()}
        hubs["192.0.2.11"].down = True
        poster = FakePoster()
        environment = env(SENSOR_BRIDGE_HUBS="192.0.2.10,192.0.2.11", SENSOR_INGEST_URL=None, SENSOR_INGEST_KEY=None)
        code, out, err = run(["--once", "--dump"], environment, hub_factory=hubs.get, poster=poster)
        self.assertEqual(code, 1, "one hub could not be read")
        self.assertIn(cid(1), out)
        self.assertIn(cid(2), out)
        self.assertIn('"temperature": 21.5', out)
        self.assertIn('"report_interval_s": 16', out)
        self.assertIn('"host": "192.0.2.11"', out)
        self.assertIn('"error": "connect failed: TimeoutError"', out)
        self.assertEqual(poster.payloads, [])
        self.assertNoSecret(out + err)
        self.assertEqual(hubs["192.0.2.10"].calls[-1], "close")

    def test_once_twice_sends_the_readings_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            environment = env(SENSOR_BRIDGE_QUEUE_PATH=os.path.join(tmp, "b.sqlite3"))
            poster = FakePoster()
            factory = lambda host: FakeHub(children=[child(1), child(2)])  # noqa: E731 - a new connection per run
            code, _, err = run(["--once"], environment, hub_factory=factory, poster=poster)
            self.assertEqual(code, 0)
            self.assertIn("event=once hubs_ok=1/1 posts=1 accepted=2", err)
            code, _, err = run(["--once"], environment, hub_factory=factory, poster=poster)
            self.assertEqual(code, 0)
            self.assertIn("event=once hubs_ok=1/1 posts=0 accepted=0", err)
            self.assertEqual(len(poster.payloads), 1)
            self.assertNoSecret(err)

    def test_once_exits_1_when_the_backend_refuses_and_keeps_the_readings(self):
        with tempfile.TemporaryDirectory() as tmp:
            environment = env(SENSOR_BRIDGE_QUEUE_PATH=os.path.join(tmp, "b.sqlite3"))
            factory = lambda host: FakeHub(children=[child(1)])  # noqa: E731
            code, _, err = run(["--once"], environment, hub_factory=factory, poster=FakePoster(401))
            self.assertEqual(code, 1)
            self.assertIn("event=auth_refused", err)
            self.assertIn("queued=1", err)
            poster = FakePoster()
            self.assertEqual(run(["--once"], environment, hub_factory=factory, poster=poster)[0], 0)
            self.assertEqual([r["external_id"] for r in poster.readings()], [cid(1)])


class LoggingTest(unittest.TestCase):
    def tearDown(self):
        logging.getLogger().handlers[:] = []

    def test_secrets_are_replaced_in_every_line(self):
        stream = io.StringIO()
        setup_logging(list(SECRETS), "INFO", stream)
        log = logging.getLogger("sensor_bridge")
        log.info("event=x url=https://h/f?%s key=%s", FAKE_QUERY, FAKE_KEY)
        log.warning("event=y error=%s\nsecond line", FAKE_PASSWORD)
        text = stream.getvalue()
        self.assertNoSecret = MainTest.assertNoSecret.__get__(self)
        self.assertNoSecret(text)
        self.assertEqual(text.count("***"), 3)
        self.assertEqual(len(text.strip().split("\n")), 2, "one line per event")
        self.assertRegex(text, r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ INFO event=x")


class ForgetHubTest(unittest.TestCase):
    def test_it_clears_what_was_learned_for_one_entry_and_nothing_else(self):
        from sensor_bridge.queue import open_db
        from sensor_bridge.state import ChangeDetector

        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "bridge.sqlite3")
            db = open_db(path)
            detector = ChangeDetector(db, 300)
            for key, value in (("hub_id:192.0.2.10", "HUB-A"), ("host_of:HUB-A", "192.0.2.10 192.0.2.34"),
                               ("hub_id:192.0.2.11", "HUB-B")):
                detector.set(key, value)
            db.close()
            settings = env(SENSOR_BRIDGE_HUBS="192.0.2.10,192.0.2.11", SENSOR_BRIDGE_QUEUE_PATH=path,
                           SENSOR_INGEST_URL=None, SENSOR_INGEST_KEY=None)
            code, out, _ = run(["--forget-hub", "192.0.2.10"], settings)
            self.assertEqual((code, "HUB-A" in out), (0, True))
            db = open_db(path)
            detector = ChangeDetector(db, 300)
            self.assertFalse(detector.get("hub_id:192.0.2.10"))
            self.assertFalse(detector.get("host_of:HUB-A"))
            self.assertEqual(detector.get("hub_id:192.0.2.11"), "HUB-B")
            db.close()
            code, out, _ = run(["--forget-hub", "192.0.2.99"], settings)
            self.assertEqual(code, 1)
            self.assertIn("not in SENSOR_BRIDGE_HUBS", out)


if __name__ == "__main__":
    unittest.main()
