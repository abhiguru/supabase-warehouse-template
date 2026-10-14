# SPDX-License-Identifier: GPL-3.0-or-later
"""Stand-ins for a Tapo hub, the backend and the clock. No network, no python-kasa."""

from __future__ import annotations

import dataclasses

from sensor_bridge.config import load
from sensor_bridge.hub import ChildReading, HubError, HubSnapshot
from sensor_bridge.poster import PostResult

# Fictional values, assembled at run time so no literal looks like a credential.
FAKE_KEY = "ab" * 32
FAKE_PASSWORD = "fake-pass-" + "x" * 6
FAKE_QUERY = "token=" + "q" * 8
T0 = 1_791_000_000.0  # 2026-10-03T04:00:00Z, a Saturday


def cid(n: int) -> str:
    return f"{n:040X}"


def env(**overrides) -> dict:
    values = {
        "SENSOR_BRIDGE_HUBS": "192.0.2.10",
        "TAPO_USERNAME": "owner@example.test",
        "TAPO_PASSWORD": FAKE_PASSWORD,
        "SENSOR_INGEST_URL": f"https://backend.example.test/functions/v1/ingest-sensor-readings?{FAKE_QUERY}",
        "SENSOR_INGEST_KEY": FAKE_KEY,
        "SENSOR_BRIDGE_QUEUE_PATH": ":memory:",
        "SENSOR_BRIDGE_HEALTH_PATH": "",
    }
    values.update(overrides)
    return {k: v for k, v in values.items() if v is not None}


def config(**overrides):
    return load(env(**overrides))


def child(n: int, temperature=21.5, humidity=60.0, battery_low=False, **extra) -> ChildReading:
    return ChildReading(external_id=cid(n), name=f"TH{n}", model="T310", temperature=temperature, humidity=humidity,
                        battery_low=battery_low, battery_percent=extra.get("battery_percent"),
                        signal_level=extra.get("signal_level", 3), report_interval_s=extra.get("report_interval_s", 16))


class FakeHub:
    """Same interface as hub.KasaHub."""

    def __init__(self, hub_id: str = "HUB" + "0" * 37, children=(), firmware: str = "1.4.0"):
        self.hub_id, self.firmware = hub_id, firmware
        self.children = {c.external_id: c for c in children}
        self.down = False  # every call fails while True
        self.fail_next = 0  # the next n connect/poll calls fail
        self.connected = False
        self.calls: list[str] = []

    def update(self, n: int, **changes) -> None:
        self.children[cid(n)] = dataclasses.replace(self.children[cid(n)], **changes)

    def _check(self, what: str) -> None:
        self.calls.append(what)
        if self.down or self.fail_next > 0:
            self.fail_next = max(0, self.fail_next - 1)
            raise HubError(f"{what} failed: TimeoutError")

    async def connect(self) -> None:
        self._check("connect")
        self.connected = True

    async def poll(self) -> HubSnapshot:
        if not self.connected:
            raise HubError("not connected")
        self._check("poll")
        return HubSnapshot(self.hub_id, "H200", self.firmware, tuple(self.children.values()))

    def dump(self) -> dict:
        return {"host": "fake", "hub_id": self.hub_id, "firmware": self.firmware,
                "children": [{"external_id": c.external_id, "alias": c.name, "reading": dataclasses.asdict(c)}
                             for c in self.children.values()]}

    async def reboot(self) -> None:
        self._check("reboot")

    async def close(self) -> None:
        self.calls.append("close")
        self.connected = False


class FakePoster:
    """Answers with the queued statuses (then 200), and records every payload it was given."""

    def __init__(self, *statuses: int | None):
        self.statuses = list(statuses)
        self.payloads: list[dict] = []

    def post(self, payload: dict) -> PostResult:
        self.payloads.append(payload)
        status = self.statuses.pop(0) if self.statuses else 200
        if status == 200:
            n = len(payload["readings"])
            return PostResult(200, {"success": True, "accepted": n, "duplicates": 0, "rejected": 0, "devices": n})
        return PostResult(status, {"success": False}, "" if status else "TimeoutError")

    def readings(self, index: int = -1) -> list[dict]:
        return self.payloads[index]["readings"]


async def run_inline(func, *args):
    return func(*args)


class Clock:
    def __init__(self, start: float = T0):
        self.now = start

    def __call__(self) -> float:
        return self.now
