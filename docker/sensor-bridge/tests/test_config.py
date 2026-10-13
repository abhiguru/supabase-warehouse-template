# SPDX-License-Identifier: GPL-3.0-or-later
import unittest

from sensor_bridge.config import Config, ConfigError, Cron, load, safe_url

from .fakes import FAKE_KEY, FAKE_PASSWORD, FAKE_QUERY, T0, env


class LoadTest(unittest.TestCase):
    def test_defaults(self):
        c = load(env(SENSOR_BRIDGE_QUEUE_PATH=None, SENSOR_BRIDGE_HEALTH_PATH=None))
        self.assertEqual(c.hubs, ("192.0.2.10",))
        self.assertEqual((c.poll_seconds, c.post_seconds, c.heartbeat_seconds, c.max_batch), (300, 60, 300, 200))
        self.assertEqual((c.queue_path, c.health_path, c.bridge_id), ("/data/bridge.sqlite3", "/data/health.json",
                                                                       "sensor-bridge"))
        self.assertIsNone(c.reboot_cron)

    def test_hubs_are_split_trimmed_and_deduplicated(self):
        self.assertEqual(load(env(SENSOR_BRIDGE_HUBS=" 192.0.2.10, hub-b.lan ,192.0.2.10,")).hubs,
                         ("192.0.2.10", "hub-b.lan"))

    def test_unconfigured_names_every_missing_variable(self):
        with self.assertRaises(ConfigError) as caught:
            load({})
        for name in ("SENSOR_BRIDGE_HUBS", "TAPO_USERNAME", "TAPO_PASSWORD", "SENSOR_INGEST_URL", "SENSOR_INGEST_KEY"):
            self.assertIn(name, str(caught.exception))

    def test_dump_needs_no_backend_settings(self):
        c = load(env(SENSOR_INGEST_URL=None, SENSOR_INGEST_KEY=None), need_ingest=False)
        self.assertEqual(c.ingest_key, "")
        with self.assertRaises(ConfigError):
            load(env(SENSOR_INGEST_URL=None, SENSOR_INGEST_KEY=None))

    def test_blank_counts_as_missing(self):
        with self.assertRaisesRegex(ConfigError, "TAPO_PASSWORD"):
            load(env(TAPO_PASSWORD="   "))

    def test_invalid_values_are_refused_without_echoing_them(self):
        cases = {
            "SENSOR_INGEST_KEY": FAKE_KEY.upper(),
            "SENSOR_BRIDGE_POLL_SECONDS": "4",
            "SENSOR_BRIDGE_POST_SECONDS": "ten",
            "SENSOR_BRIDGE_HEARTBEAT_SECONDS": "-900",
            "SENSOR_BRIDGE_MAX_BATCH": "501",
            "SENSOR_BRIDGE_HUBS": "192.0.2.10;rm -rf",
            "SENSOR_INGEST_URL": "ftp://backend.example.test/x",
            "SENSOR_BRIDGE_ID": "bridge with spaces",
            "SENSOR_BRIDGE_REBOOT_CRON": "* * * * *",
            "SENSOR_BRIDGE_LOG_LEVEL": "LOUD",
        }
        for name, value in cases.items():
            with self.subTest(name=name), self.assertRaises(ConfigError) as caught:
                load(env(**{name: value}))
            self.assertIn(name, str(caught.exception))
            self.assertNotIn(value, str(caught.exception))

    def test_url_with_user_information_is_refused(self):
        with self.assertRaisesRegex(ConfigError, "SENSOR_INGEST_URL"):
            load(env(SENSOR_INGEST_URL=f"https://user:{FAKE_PASSWORD}@backend.example.test/f"))

    def test_secrets_are_kept_out_of_repr_and_summary(self):
        c = load(env())
        self.assertEqual(sorted(c.secrets()), sorted([FAKE_PASSWORD, FAKE_KEY, FAKE_QUERY]))
        for text in (repr(c), str(c.summary())):
            for secret in c.secrets() + ["owner@example.test"]:
                self.assertNotIn(secret, text)
        self.assertEqual(c.summary()["ingest_url"], "https://backend.example.test/functions/v1/ingest-sensor-readings")

    def test_safe_url_drops_query_fragment_and_user(self):
        self.assertEqual(safe_url("https://a:b@host.test:8443/p/q?x=1#f"), "https://host.test:8443/p/q")

    def test_config_is_immutable(self):
        c = load(env())
        self.assertIsInstance(c, Config)
        with self.assertRaises(AttributeError):
            c.poll_seconds = 1  # type: ignore[misc]


class CronTest(unittest.TestCase):
    def matches_in(self, cron: Cron, days: int) -> list[float]:
        return [T0 + m * 60 for m in range(days * 1440) if cron.matches(T0 + m * 60)]

    def test_weekly_cron_fires_once_a_week(self):
        hits = self.matches_in(Cron("30 21 * * 6"), 28)  # Saturday 21:30 UTC = Sunday 03:00 IST
        self.assertEqual(len(hits), 4)
        self.assertEqual([hits[i + 1] - hits[i] for i in range(3)], [7 * 86400] * 3)
        self.assertEqual(hits[0], T0 + (17 * 60 + 30) * 60, "the same Saturday as T0 (04:00), at 21:30")

    def test_sunday_is_0_or_7(self):
        self.assertEqual(self.matches_in(Cron("0 3 * * 0"), 14), self.matches_in(Cron("0 3 * * 7"), 14))

    def test_lists_ranges_and_steps(self):
        self.assertEqual(len(self.matches_in(Cron("0 2 * * 1-5"), 7)), 5)
        self.assertEqual(len(self.matches_in(Cron("0 2 */10 * *"), 31)), 4)  # 11, 21, 31 October and 1 November
        self.assertEqual(len(self.matches_in(Cron("0 2 * * 1,3"), 7)), 2)

    def test_both_day_fields_restricted_means_either(self):
        # cron's rule: day-of-month 1 OR any Monday: 5, 12, 19, 26 October, 1 November (a Sunday), 2 November.
        self.assertEqual(len(self.matches_in(Cron("0 2 1 * 1"), 31)), 6)

    def test_unreadable_crons_are_refused(self):
        for text in ("", "0 3 * *", "*/5 3 * * 0", "0 * * * 0", "61 3 * * 0", "0 3 * * 8", "0 3 * * mon", "0 3 */0 * *"):
            with self.subTest(text=text), self.assertRaises(ConfigError):
                Cron(text)


if __name__ == "__main__":
    unittest.main()
