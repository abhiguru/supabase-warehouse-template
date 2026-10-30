# SPDX-License-Identifier: GPL-3.0-or-later
"""The only module that talks to python-kasa. Everything it returns is plain data.

Every error from python-kasa (or a timeout) leaves this module as HubError, with a
message that has been cleared of the login.
"""

from __future__ import annotations

import asyncio
import math
from dataclasses import asdict, dataclass


class HubError(Exception):
    """The hub could not be reached, refused the login, or answered something unusable."""


@dataclass(frozen=True)
class ChildReading:
    external_id: str
    name: str | None
    model: str | None
    temperature: float | None  # degrees Celsius
    humidity: float | None  # percent
    battery_low: bool | None
    battery_percent: int | None
    signal_level: int | None
    report_interval_s: int | None
    # The hub's own status for the sensor: True "online", False "offline", None when absent or unknown.
    # An offline sensor still has cached values on the hub; they are not a measurement.
    online: bool | None = None


@dataclass(frozen=True)
class HubSnapshot:
    hub_id: str
    model: str | None
    firmware: str | None
    children: tuple[ChildReading, ...]


def _get(obj, name):
    """An attribute of a kasa object, or None: kasa raises KeyError for fields a device lacks."""
    try:
        return getattr(obj, name)
    except Exception:  # noqa: BLE001 - any failure means "not reported"
        return None


def _number(value, digits: int = 2) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return round(float(value), digits)


def _int(value) -> int | None:
    return int(value) if isinstance(value, int) and not isinstance(value, bool) else None


def to_celsius(value, unit) -> float | None:
    number = _number(value, 4)
    if number is None:
        return None
    if isinstance(unit, str) and unit.lower().startswith("f"):
        number = (number - 32) * 5 / 9
    return round(number, 2)


def status_of(child) -> str | None:
    """The raw `status` of a sensor ("online" / "offline"), or None when not reported as text."""
    value = (_get(child, "sys_info") or {}).get("status")
    return value if isinstance(value, str) else None


def read_child(child, names) -> ChildReading | None:
    """One sensor of the hub, or None when it reports neither temperature nor humidity."""
    temp_name, humidity_name, battery_name, report_name = names
    modules = _get(child, "modules") or {}
    temp, humidity = modules.get(temp_name), modules.get(humidity_name)
    if temp is None and humidity is None:
        return None
    battery, report = modules.get(battery_name), modules.get(report_name)
    features = _get(child, "features") or {}
    signal = features.get("signal_level")
    signal = _get(signal, "value") if signal is not None else (_get(child, "sys_info") or {}).get("signal_level")
    low = _get(battery, "battery_low") if battery is not None else None
    return ChildReading(
        external_id=str(_get(child, "device_id") or ""),
        name=_get(child, "alias"),
        model=_get(child, "model"),
        temperature=to_celsius(_get(temp, "temperature"), _get(temp, "temperature_unit")) if temp is not None else None,
        humidity=_number(_get(humidity, "humidity")) if humidity is not None else None,
        battery_low=low if isinstance(low, bool) else None,
        battery_percent=_int(_get(battery, "battery")) if battery is not None else None,
        signal_level=_int(signal),
        report_interval_s=_int(_get(report, "report_interval")) if report is not None else None,
        online={"online": True, "offline": False}.get(status_of(child)),
    )


def hub_id_of(device, host: str) -> str:
    value = _get(device, "device_id")
    return str(value) if value not in (None, "", "None") else host


def snapshot_of(device, host: str, names) -> HubSnapshot:
    children = tuple(c for c in (read_child(ch, names) for ch in (_get(device, "children") or [])) if c and c.external_id)
    hw = _get(device, "hw_info") or {}
    return HubSnapshot(hub_id_of(device, host), _get(device, "model"), hw.get("sw_ver"), children)


def dump_of(device, host: str, names) -> dict:
    """What --dump prints: identities, values and the names of the fields (never their raw values)."""
    snap = snapshot_of(device, host, names)
    readings = {c.external_id: asdict(c) for c in snap.children}
    children = []
    for child in _get(device, "children") or []:
        cid = str(_get(child, "device_id") or "")
        children.append({
            "external_id": cid,
            "alias": _get(child, "alias"),
            "model": _get(child, "model"),
            "rssi": _int(_get(child, "rssi")),
            "status": status_of(child),
            "sys_info_keys": sorted(str(k) for k in (_get(child, "sys_info") or {})),
            "modules": sorted(str(k) for k in (_get(child, "modules") or {})),
            "reading": readings.get(cid),
        })
    return {"host": host, "hub_id": snap.hub_id, "model": snap.model, "firmware": snap.firmware, "children": children}


class KasaHub:
    """A Tapo hub (H100/H200) reached with python-kasa's SMART protocol over AES, login v3, HTTPS."""

    def __init__(self, host: str, username: str, password: str, timeout: float = 30):
        self.host, self._username, self._password, self.timeout = host, username, password, timeout
        self._device = None

    def _error(self, exc: BaseException) -> HubError:
        # python-kasa puts the readable message first and the wrapped error's repr after it.
        first = exc.args[0] if exc.args and isinstance(exc.args[0], str) else str(exc)
        text = f"{type(exc).__name__}: {first}"
        for secret in (self._password, self._username):
            if len(secret) >= 4:  # a shorter value would mangle ordinary words (the log filter still has it)
                text = text.replace(secret, "***")
        return HubError(text[:200])

    async def _call(self, make):
        try:
            return await asyncio.wait_for(make(), self.timeout)
        except HubError:
            raise
        except Exception as exc:  # noqa: BLE001 - every kasa error becomes HubError
            raise self._error(exc) from None

    @staticmethod
    def _names():
        from kasa import Module

        return (Module.TemperatureSensor, Module.HumiditySensor, Module.BatterySensor, Module.ReportMode)

    async def connect(self) -> None:
        async def go():
            from kasa import (Credentials, Device, DeviceConfig, DeviceConnectionParameters,
                              DeviceEncryptionType, DeviceFamily)

            config = DeviceConfig(
                host=self.host,
                credentials=Credentials(self._username, self._password),
                connection_type=DeviceConnectionParameters(
                    DeviceFamily.SmartTapoHub, DeviceEncryptionType.Aes, login_version=3, https=True),
            )
            return await Device.connect(config=config)

        await self.close()
        self._device = await self._call(go)

    async def identify(self) -> str:
        """Log in and return the hub's id, then disconnect. Raises HubError when it is not a hub of this account."""
        try:
            await self.connect()
            return hub_id_of(self._device, self.host)
        finally:
            await self.close()

    async def poll(self) -> HubSnapshot:
        if self._device is None:
            raise HubError("not connected")
        await self._call(self._device.update)
        try:
            return snapshot_of(self._device, self.host, self._names())
        except Exception as exc:  # noqa: BLE001
            raise self._error(exc) from None

    def dump(self) -> dict:
        if self._device is None:
            raise HubError("not connected")
        return dump_of(self._device, self.host, self._names())

    async def reboot(self) -> None:
        if self._device is None:
            raise HubError("not connected")
        await self._call(self._device.reboot)

    async def close(self) -> None:
        device, self._device = self._device, None
        if device is not None:
            try:
                await asyncio.wait_for(device.disconnect(), 10)
            except Exception:  # noqa: BLE001 - closing a dead connection may fail; nothing to do
                pass
