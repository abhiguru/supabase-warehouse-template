# SPDX-License-Identifier: GPL-3.0-or-later
"""Settings from the environment. Nothing here ever puts a secret into a message."""

from __future__ import annotations

import os
import re
import time
from dataclasses import dataclass, field
from urllib.parse import urlsplit

EX_CONFIG = 78  # sysexits.h: configuration error; the container stops instead of looping

PREFIX = "SENSOR_BRIDGE_"
REQUIRED = ("SENSOR_BRIDGE_HUBS", "TAPO_USERNAME", "TAPO_PASSWORD")
REQUIRED_FOR_POSTING = ("SENSOR_INGEST_URL", "SENSOR_INGEST_KEY")
HOST = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
BRIDGE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
KEY = re.compile(r"^[0-9a-f]{64}$")
# name: (default, minimum, maximum)
NUMBERS = {
    "POLL_SECONDS": (300, 5, 3600),
    "POST_SECONDS": (60, 5, 3600),
    "HEARTBEAT_SECONDS": (300, 60, 86400),
    "MAX_BATCH": (200, 1, 500),
}


class ConfigError(Exception):
    """A missing or invalid setting. The message names the variable, never its value."""


class Cron:
    """Five-field cron (minute hour day-of-month month day-of-week), evaluated in UTC.

    Minute and hour must be single numbers, so a hub is rebooted at most once on a matching day.
    """

    RANGES = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))

    def __init__(self, text: str):
        parts = text.split()
        if len(parts) != 5:
            raise ConfigError("SENSOR_BRIDGE_REBOOT_CRON must have five fields")
        if not (parts[0].isdigit() and parts[1].isdigit()):
            raise ConfigError("SENSOR_BRIDGE_REBOOT_CRON minute and hour must be single numbers")
        self.text = " ".join(parts)
        self.sets = [self._field(p, lo, hi) for p, (lo, hi) in zip(parts, self.RANGES)]
        if 7 in self.sets[4]:
            self.sets[4] = self.sets[4] | {0}
        self.dom_any, self.dow_any = parts[2] == "*", parts[4] == "*"

    @staticmethod
    def _field(text: str, lo: int, hi: int) -> frozenset[int]:
        values: set[int] = set()
        for item in text.split(","):
            base, _, step = item.partition("/")
            if base == "*":
                start, end = lo, hi
            elif re.fullmatch(r"\d+-\d+", base):
                start, end = (int(x) for x in base.split("-"))
            elif base.isdigit():
                start = end = int(base)
            else:
                raise ConfigError("SENSOR_BRIDGE_REBOOT_CRON has an unreadable field")
            if step and not step.isdigit() or step == "0":
                raise ConfigError("SENSOR_BRIDGE_REBOOT_CRON has an unreadable step")
            if not lo <= start <= end <= hi:
                raise ConfigError("SENSOR_BRIDGE_REBOOT_CRON has a value out of range")
            values.update(range(start, end + 1, int(step or 1)))
        return frozenset(values)

    def matches(self, now: float) -> bool:
        t = time.gmtime(now)
        minute, hour, dom, month, dow = self.sets
        if t.tm_min not in minute or t.tm_hour not in hour or t.tm_mon not in month:
            return False
        dom_ok, dow_ok = t.tm_mday in dom, (t.tm_wday + 1) % 7 in dow
        if self.dom_any or self.dow_any:
            return dom_ok and dow_ok
        return dom_ok or dow_ok  # cron's rule when both day fields are restricted


@dataclass(frozen=True)
class Config:
    hubs: tuple[str, ...]
    username: str = field(repr=False)
    password: str = field(repr=False)
    ingest_url: str = field(default="", repr=False)
    ingest_key: str = field(default="", repr=False)
    bridge_id: str = "sensor-bridge"
    poll_seconds: int = 300
    post_seconds: int = 60
    heartbeat_seconds: int = 300
    max_batch: int = 200
    reboot_cron: Cron | None = None
    queue_path: str = "/data/bridge.sqlite3"
    health_path: str = "/data/health.json"
    log_level: str = "INFO"

    def secrets(self) -> list[str]:
        """Strings that must never appear in a log line or in printed output."""
        query = urlsplit(self.ingest_url).query if self.ingest_url else ""
        return [s for s in (self.password, self.ingest_key, query) if s]

    def summary(self) -> dict:
        return {
            "hubs": list(self.hubs),
            "bridge_id": self.bridge_id,
            "ingest_url": safe_url(self.ingest_url) if self.ingest_url else None,
            "ingest_key": "set" if self.ingest_key else "not set",
            "tapo_login": "set",
            "poll_seconds": self.poll_seconds,
            "post_seconds": self.post_seconds,
            "heartbeat_seconds": self.heartbeat_seconds,
            "max_batch": self.max_batch,
            "reboot_cron_utc": self.reboot_cron.text if self.reboot_cron else None,
            "queue_path": self.queue_path,
            "health_path": self.health_path,
        }


def safe_url(url: str) -> str:
    """The URL without user information, query or fragment: what a log may show."""
    parts = urlsplit(url)
    host = parts.hostname or ""
    port = f":{parts.port}" if parts.port else ""
    return f"{parts.scheme}://{host}{port}{parts.path}"


def load(env: dict | None = None, need_ingest: bool = True) -> Config:
    env = dict(os.environ if env is None else env)
    get = lambda name: (env.get(name) or "").strip()  # noqa: E731
    missing = [n for n in REQUIRED + (REQUIRED_FOR_POSTING if need_ingest else ()) if not get(n)]
    if missing:
        raise ConfigError("not configured: " + ", ".join(missing))

    hubs = tuple(dict.fromkeys(h.strip() for h in get("SENSOR_BRIDGE_HUBS").split(",") if h.strip()))
    if not hubs or not all(HOST.match(h) for h in hubs):
        raise ConfigError("SENSOR_BRIDGE_HUBS must be a comma-separated list of host names or IPv4 addresses")

    url, key = get("SENSOR_INGEST_URL"), get("SENSOR_INGEST_KEY")
    if url:
        parts = urlsplit(url)
        if parts.scheme not in ("http", "https") or not parts.hostname or "@" in parts.netloc:
            raise ConfigError("SENSOR_INGEST_URL must be an http(s) URL without user information")
    if key and not KEY.match(key):
        raise ConfigError("SENSOR_INGEST_KEY must be 64 lowercase hex characters")

    bridge_id = get("SENSOR_BRIDGE_ID") or "sensor-bridge"
    if not BRIDGE_ID.match(bridge_id):
        raise ConfigError("SENSOR_BRIDGE_ID must be 1-64 letters, digits, '.', '_' or '-'")

    numbers = {}
    for name, (default, low, high) in NUMBERS.items():
        raw = get(PREFIX + name)
        if not raw:
            numbers[name.lower()] = default
            continue
        if not raw.isdigit() or not low <= int(raw) <= high:
            raise ConfigError(f"{PREFIX}{name} must be a whole number from {low} to {high}")
        numbers[name.lower()] = int(raw)

    cron_text = get("SENSOR_BRIDGE_REBOOT_CRON")
    level = (get("SENSOR_BRIDGE_LOG_LEVEL") or "INFO").upper()
    if level not in ("DEBUG", "INFO", "WARNING", "ERROR"):
        raise ConfigError("SENSOR_BRIDGE_LOG_LEVEL must be DEBUG, INFO, WARNING or ERROR")
    return Config(
        hubs=hubs,
        username=get("TAPO_USERNAME"),
        password=env.get("TAPO_PASSWORD", "").strip(),
        ingest_url=url,
        ingest_key=key,
        bridge_id=bridge_id,
        reboot_cron=Cron(cron_text) if cron_text else None,
        queue_path=get("SENSOR_BRIDGE_QUEUE_PATH") or "/data/bridge.sqlite3",
        health_path=get("SENSOR_BRIDGE_HEALTH_PATH") or "/data/health.json",
        log_level=level,
        **numbers,
    )
