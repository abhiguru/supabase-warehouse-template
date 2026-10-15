# SPDX-License-Identifier: GPL-3.0-or-later
import asyncio
import importlib.util
import unittest
from types import SimpleNamespace

from sensor_bridge.hub import HubError, KasaHub, dump_of, read_child, snapshot_of, to_celsius

from .fakes import FAKE_PASSWORD, cid

HAVE_KASA = importlib.util.find_spec("kasa") is not None
# python-kasa's Module names are str subclasses equal to these, so the fakes key modules by plain strings.
NAMES = ("TemperatureSensor", "HumiditySensor", "BatterySensor", "ReportMode")


class Raising:
    """A kasa module whose properties fail like a field the device does not report."""

    def __getattr__(self, name):
        raise KeyError(name)


def t310(n: int, temp=21.5, unit="celsius", humidity=60, low=False, battery=None, signal=3, interval=16, status=None):
    modules = {
        "TemperatureSensor": SimpleNamespace(temperature=temp, temperature_unit=unit),
        "HumiditySensor": SimpleNamespace(humidity=humidity),
        "BatterySensor": SimpleNamespace(battery_low=low, battery=battery) if battery is not None
        else type("B", (Raising,), {"battery_low": low})(),
        "ReportMode": SimpleNamespace(report_interval=interval),
    }
    sys_info = {"device_id": cid(n), "nickname": "VEgy", "current_temp": temp}
    if status is not None:
        sys_info["status"] = status
    return SimpleNamespace(device_id=cid(n), alias=f"TH{n}", model="T310", rssi=-60, modules=modules,
                           features={"signal_level": SimpleNamespace(value=signal)}, sys_info=sys_info)


def h200(*children, device_id="HUB" + "1" * 37):
    return SimpleNamespace(device_id=device_id, model="H200", hw_info={"sw_ver": "1.4.0 Build 1"}, children=list(children))


class ReadChildTest(unittest.TestCase):
    def test_t310_in_celsius(self):
        r = read_child(t310(1), NAMES)
        self.assertEqual((r.external_id, r.name, r.model), (cid(1), "TH1", "T310"))
        self.assertEqual((r.temperature, r.humidity, r.battery_low, r.battery_percent), (21.5, 60.0, False, None))
        self.assertEqual((r.signal_level, r.report_interval_s), (3, 16))

    def test_fahrenheit_is_converted(self):
        self.assertEqual(read_child(t310(1, temp=70.7, unit="fahrenheit"), NAMES).temperature, 21.5)
        self.assertEqual(to_celsius(32, "fahrenheit"), 0.0)
        self.assertEqual(to_celsius(-40, "fahrenheit"), -40.0)
        self.assertEqual(to_celsius(21.456, "celsius"), 21.46)

    def test_unreported_and_unusable_values_become_none(self):
        child = t310(1, temp=float("nan"), humidity=True, low="yes", battery=87, signal=None, interval="16")
        r = read_child(child, NAMES)
        self.assertEqual((r.temperature, r.humidity, r.battery_low, r.battery_percent, r.signal_level,
                          r.report_interval_s), (None, None, None, 87, None, None))

    def test_signal_level_falls_back_to_sys_info(self):
        child = t310(1)
        child.features = {}
        child.sys_info["signal_level"] = 2
        self.assertEqual(read_child(child, NAMES).signal_level, 2)

    def test_a_child_without_temperature_or_humidity_is_skipped(self):
        button = SimpleNamespace(device_id=cid(9), alias="S200", model="S200B", modules={"BatterySensor": object()})
        self.assertIsNone(read_child(button, NAMES))

    def test_snapshot_uses_the_hub_device_id_or_the_host(self):
        snap = snapshot_of(h200(t310(1), t310(2)), "192.0.2.10", NAMES)
        self.assertEqual((snap.hub_id, snap.model, snap.firmware), ("HUB" + "1" * 37, "H200", "1.4.0 Build 1"))
        self.assertEqual([c.external_id for c in snap.children], [cid(1), cid(2)])
        for missing in (None, "", "None"):  # kasa returns str(None) when the hub sends no id
            self.assertEqual(snapshot_of(h200(device_id=missing), "192.0.2.10", NAMES).hub_id, "192.0.2.10")

    def test_status_online_offline_or_unknown(self):
        self.assertIs(read_child(t310(1, status="online"), NAMES).online, True)
        self.assertIs(read_child(t310(1, status="offline"), NAMES).online, False)
        self.assertIsNone(read_child(t310(1), NAMES).online, "older firmware: no status field")
        for other in ("Online", "unknown", "", 1, True):
            self.assertIsNone(read_child(t310(1, status=other), NAMES).online, repr(other))

    def test_dump_shows_the_status_and_no_other_raw_value(self):
        data = dump_of(h200(t310(1, status="offline"), t310(2, status="online"), t310(3)), "192.0.2.10", NAMES)
        self.assertEqual([c["status"] for c in data["children"]], ["offline", "online", None])
        self.assertIs(data["children"][0]["reading"]["online"], False)
        self.assertNotIn("VEgy", str(data))
        self.assertEqual(data["children"][0]["sys_info_keys"], ["current_temp", "device_id", "nickname", "status"])

    def test_dump_lists_field_names_not_raw_values(self):
        data = dump_of(h200(t310(1)), "192.0.2.10", NAMES)
        child = data["children"][0]
        self.assertEqual(child["sys_info_keys"], ["current_temp", "device_id", "nickname"])
        self.assertEqual(child["modules"], sorted(NAMES))
        self.assertEqual(child["reading"]["temperature"], 21.5)
        self.assertEqual(child["rssi"], -60)
        self.assertNotIn("VEgy", str(data))


class KasaHubTest(unittest.TestCase):
    def test_every_error_becomes_hub_error_without_the_login(self):
        hub = KasaHub("192.0.2.10", "owner@example.test", FAKE_PASSWORD, timeout=1)

        async def fails():
            raise RuntimeError(f"login owner@example.test/{FAKE_PASSWORD} refused")

        with self.assertRaises(HubError) as caught:
            asyncio.run(hub._call(fails))
        self.assertIn("RuntimeError", str(caught.exception))
        self.assertNotIn(FAKE_PASSWORD, str(caught.exception))
        self.assertNotIn("owner@example.test", str(caught.exception))
        self.assertIsNone(caught.exception.__cause__)

    def test_only_the_readable_part_of_a_kasa_error_is_kept(self):
        hub = KasaHub("192.0.2.10", "owner@example.test", FAKE_PASSWORD)

        async def fails():
            raise ConnectionError("Device connection error: 192.0.2.10: unreachable", OSError("a long repr " * 50))

        with self.assertRaises(HubError) as caught:
            asyncio.run(hub._call(fails))
        self.assertEqual(str(caught.exception), "ConnectionError: Device connection error: 192.0.2.10: unreachable")

    def test_a_hanging_call_times_out_as_hub_error(self):
        hub = KasaHub("192.0.2.10", "owner@example.test", FAKE_PASSWORD, timeout=0.05)
        with self.assertRaisesRegex(HubError, "TimeoutError"):
            asyncio.run(hub._call(lambda: asyncio.sleep(5)))

    def test_calls_before_connect_are_hub_errors(self):
        hub = KasaHub("192.0.2.10", "u", FAKE_PASSWORD)
        with self.assertRaises(HubError):
            asyncio.run(hub.poll())
        with self.assertRaises(HubError):
            hub.dump()
        asyncio.run(hub.close())  # closing a hub that never connected is fine

    @unittest.skipUnless(HAVE_KASA, "python-kasa is not installed")
    def test_python_kasa_names_match_what_the_bridge_uses(self):
        import kasa
        from kasa import (Credentials, DeviceConfig, DeviceConnectionParameters, DeviceEncryptionType,  # noqa: F401
                          DeviceFamily)

        self.assertEqual(tuple(KasaHub._names()), NAMES)
        self.assertEqual(kasa.Module.TemperatureSensor, "TemperatureSensor")
        params = DeviceConnectionParameters(DeviceFamily.SmartTapoHub, DeviceEncryptionType.Aes, login_version=3,
                                            https=True)
        config = DeviceConfig(host="192.0.2.10", credentials=Credentials("u", FAKE_PASSWORD), connection_type=params)
        self.assertEqual(config.connection_type.device_family.value, "SMART.TAPOHUB")
        self.assertNotIn(FAKE_PASSWORD, repr(config.connection_type))


if __name__ == "__main__":
    unittest.main()
