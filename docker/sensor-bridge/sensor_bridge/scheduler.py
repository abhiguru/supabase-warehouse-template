# SPDX-License-Identifier: GPL-3.0-or-later
"""One state machine per hub, and the loop that runs them beside the delivery.

Per hub:
  DISCONNECTED --connect+poll ok--> POLLING (hub status online=true is queued)
  DISCONNECTED/OFFLINE --connect fails--> retry after 5 s, doubling to 5 min
  POLLING --poll fails--> retried at the poll interval on the same connection
  any state --3rd failure in a row--> OFFLINE (online=false queued, connection closed)
  OFFLINE --connect+poll ok--> POLLING (online=true queued)
  POLLING --reboot cron matches--> reboot, REBOOTING: reconnect after 2 min, retried at most a
          minute apart; failures in the first 5 min do not count
Every heartbeat interval the hub status is queued again (online or not), so the backend
sees the bridge even when no sensor changes and a hub is unreachable.
"""

from __future__ import annotations

import asyncio
import logging
import time

from . import __version__, health
from .hub import HubError, HubSnapshot
from .poster import Delivery
from .queue import Queue
from .state import ChangeDetector

log = logging.getLogger("sensor_bridge")

DISCONNECTED, POLLING, OFFLINE, REBOOTING = "DISCONNECTED", "POLLING", "OFFLINE", "REBOOTING"
OFFLINE_AFTER = 3
CONNECT_FIRST, CONNECT_MAX = 5, 300
REBOOT_WAIT, REBOOT_GRACE, REBOOT_RETRY_MAX = 120, 300, 60
QUEUE_MAX_AGE = 29 * 86400  # the backend refuses readings older than 30 days
PRUNE_EVERY = 3600


def iso(now: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))


class HubRunner:
    def __init__(self, host: str, client, detector: ChangeDetector, queue: Queue, config):
        self.host, self.client, self.detector, self.queue, self.config = host, client, detector, queue, config
        self.state = DISCONNECTED
        self.failures = 0
        self.next_at = 0.0
        self.connect_wait = 0
        self.rebooted_at: float | None = None
        self.hub_status_at: float | None = None
        self.hub_id = detector.get(f"hub_id:{host}") or host
        self.firmware: str | None = None
        self.last_error = ""

    def hub_payload(self, online: bool) -> dict:
        return {"id": self.hub_id, "host": self.host, "online": online, "firmware": self.firmware}

    def _queue_hub(self, online: bool, now: float, force: bool = False) -> None:
        if self.queue.set_hub(self.host, self.hub_payload(online), force) or force:
            self.hub_status_at = now

    async def step(self, now: float) -> None:
        if self.hub_status_at is not None and now - self.hub_status_at >= self.config.heartbeat_seconds:
            self._queue_hub(self.state != OFFLINE, now, force=True)
            if self.state == OFFLINE:
                log.info("event=offline_heartbeat hub=%s host=%s", self.hub_id, self.host)
        if now < self.next_at:
            return
        if self.state == POLLING and self._reboot_due(now):
            await self._reboot(now)
            return
        try:
            if self.state != POLLING:
                await self.client.connect()
            snapshot = await self.client.poll()
        except HubError as exc:
            await self._failed(now, exc)
            return
        self._polled(now, snapshot)

    def _polled(self, now: float, snap: HubSnapshot) -> None:
        if self.state != POLLING:
            log.info("event=hub_online hub=%s host=%s model=%s firmware=%s sensors=%d was=%s",
                     snap.hub_id, self.host, snap.model, snap.firmware, len(snap.children), self.state)
        self.state, self.failures, self.connect_wait, self.rebooted_at = POLLING, 0, 0, None
        self.next_at = now + self.config.poll_seconds
        if snap.hub_id != self.hub_id:
            self.hub_id = snap.hub_id
            self.detector.set(f"hub_id:{self.host}", snap.hub_id)
        self.firmware = snap.firmware
        self._queue_hub(True, now)
        measured_at, readings = iso(now), []
        for child in snap.children:
            if child.temperature is None and child.humidity is None:
                continue
            kind = self.detector.observe(child, now)
            if kind:
                readings.append({
                    "external_id": child.external_id, "name": child.name, "model": child.model,
                    "temperature": child.temperature, "humidity": child.humidity, "measured_at": measured_at,
                    "battery_low": child.battery_low, "battery_percent": child.battery_percent,
                    "signal_level": child.signal_level, "report_interval_s": child.report_interval_s, "kind": kind,
                })
        self.queue.put(self.host, readings, now)  # commits the detector's records with the readings
        if readings:
            log.info("event=readings hub=%s sensors=%d changes=%d heartbeats=%d", self.hub_id, len(snap.children),
                     sum(r["kind"] == "change" for r in readings), sum(r["kind"] == "heartbeat" for r in readings))

    async def _failed(self, now: float, exc: HubError) -> None:
        self.last_error = str(exc)
        in_grace = self.state == REBOOTING and now - (self.rebooted_at or now) < REBOOT_GRACE
        if not in_grace:
            self.failures += 1
            if self.state == REBOOTING:  # the grace is over: count from here, retrying quickly
                self.state, self.connect_wait = DISCONNECTED, 0
        log.warning("event=hub_error hub=%s host=%s state=%s failures=%d error=%s",
                    self.hub_id, self.host, self.state, self.failures, self.last_error)
        if self.failures >= OFFLINE_AFTER and self.state != OFFLINE:
            log.error("event=hub_offline hub=%s host=%s failures=%d", self.hub_id, self.host, self.failures)
            self.state = OFFLINE
            self._queue_hub(False, now)
        if self.state == POLLING:
            self.next_at = now + self.config.poll_seconds
            return
        await self.client.close()
        ceiling = REBOOT_RETRY_MAX if self.state == REBOOTING else CONNECT_MAX
        self.connect_wait = CONNECT_FIRST if not self.connect_wait else min(ceiling, self.connect_wait * 2)
        self.next_at = now + self.connect_wait

    def _reboot_due(self, now: float) -> bool:
        cron = self.config.reboot_cron
        return bool(cron and cron.matches(now) and self.detector.get(f"reboot:{self.host}") != str(int(now // 60)))

    async def _reboot(self, now: float) -> None:
        self.detector.set(f"reboot:{self.host}", str(int(now // 60)))  # first, so a crash cannot repeat it
        log.info("event=hub_reboot hub=%s host=%s", self.hub_id, self.host)
        try:
            await self.client.reboot()
        except HubError as exc:
            log.warning("event=hub_reboot_failed hub=%s host=%s error=%s", self.hub_id, self.host, exc)
            self.next_at = now + self.config.poll_seconds
            return
        await self.client.close()
        self.state, self.rebooted_at, self.failures, self.connect_wait = REBOOTING, now, 0, 0
        self.next_at = now + REBOOT_WAIT

    def status(self) -> dict:
        return {"hub_id": self.hub_id, "state": self.state, "failures": self.failures, "last_error": self.last_error}


class Bridge:
    def __init__(self, runners: list[HubRunner], delivery: Delivery, queue: Queue, clock=time.time,
                 health_path: str | None = None):
        self.runners, self.delivery, self.queue, self.clock = runners, delivery, queue, clock
        self.health_path = health_path
        self.pruned_at = 0.0

    async def tick(self) -> None:
        now = self.clock()
        jobs = [r.step(now) for r in self.runners] + [self.delivery.tick(now)]
        for result in await asyncio.gather(*jobs, return_exceptions=True):
            if isinstance(result, Exception):
                log.error("event=internal_error error=%s", type(result).__name__)
        if now - self.pruned_at >= PRUNE_EVERY:
            self.pruned_at = now
            dropped = self.queue.prune(now, QUEUE_MAX_AGE)
            if dropped:
                log.warning("event=queue_pruned dropped=%d", dropped)
        if self.health_path:
            health.write(self.health_path, {
                "time": iso(now), "version": __version__, "queued": self.queue.size(),
                "delivery": self.delivery.last_status, "hubs": {r.host: r.status() for r in self.runners}})

    async def run(self, stop: asyncio.Event) -> None:
        log.info("event=bridge_started version=%s hubs=%d", __version__, len(self.runners))
        try:
            while not stop.is_set():
                await self.tick()
                try:
                    await asyncio.wait_for(stop.wait(), 1.0)
                except TimeoutError:
                    pass
        finally:
            await self.close()
            log.info("event=bridge_stopped queued=%d", self.queue.size())

    async def once(self) -> bool:
        """One poll of every hub and one delivery attempt. True when both fully succeeded."""
        try:
            now = self.clock()
            await asyncio.gather(*(r.step(now) for r in self.runners))
            delivered = await self.delivery.tick(now)
        finally:
            await self.close()
        totals = self.delivery.totals
        polled = sum(r.state == POLLING for r in self.runners)
        log.info("event=once hubs_ok=%d/%d posts=%d accepted=%d duplicates=%d rejected=%d queued=%d",
                 polled, len(self.runners), totals["posts"], totals["accepted"], totals["duplicates"],
                 totals["rejected"], self.queue.size())
        return delivered and polled == len(self.runners)

    async def close(self) -> None:
        for runner in self.runners:
            await runner.client.close()
