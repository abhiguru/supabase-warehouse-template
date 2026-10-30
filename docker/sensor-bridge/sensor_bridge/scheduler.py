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
OFFLINE --relocate interval elapsed--> the runner asks the locator for a sweep (a background task; the
          runner keeps retrying meanwhile) and reads the result on a later step; when the hub is found at
          another address the runner switches to it (event=hub_moved) and reconnects at once
Every heartbeat interval the hub status is queued again (online or not), so the backend
sees the bridge even when no sensor changes and a hub is unreachable.
"""

from __future__ import annotations

import asyncio
import logging
import time

from . import __version__, health
from .hub import HubError, HubSnapshot
from .locate import Locator
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
    def __init__(self, host: str, client, detector: ChangeDetector, queue: Queue, config,
                 locator: Locator | None = None, hub_factory=None, known_ids: set[str] | None = None):
        self.configured = self.host = host  # `configured` is the address in SENSOR_BRIDGE_HUBS; `host` the current one
        self.client, self.detector, self.queue, self.config = client, detector, queue, config
        self.locator, self.hub_factory = locator, hub_factory
        self.relocate_at = 0.0
        self.awaiting: float | None = None  # when this runner asked for a sweep whose result it has not read
        self.old_missed = False  # a sweep finished and did not see the learned hub anywhere
        self.state = DISCONNECTED
        self.failures = 0
        self.next_at = 0.0
        self.connect_wait = 0
        self.rebooted_at: float | None = None
        self.hub_status_at: float | None = None
        self.learned_id: str | None = detector.get(f"hub_id:{host}") or None
        if self.learned_id and known_ids is not None:
            if self.learned_id in known_ids:  # two entries cannot follow one hub: the later one starts again
                log.warning("event=duplicate_hub_id hub=%s host=%s dropped=true", self.learned_id, host)
                detector.set(f"hub_id:{host}", "")
                self.learned_id = None
            else:
                known_ids.add(self.learned_id)
        self._restore_move()
        if self.learned_id:  # state written before hubs were keyed by id used the address
            self.queue.rekey(self.configured, self.learned_id, keep_status=True)
        self.firmware: str | None = None
        self.last_error = ""
        self.offline_sensors: set[str] = set()  # sensors logged offline, to log each change once

    @property
    def hub_id(self) -> str:
        """The hub's own id once learned; until then its address (that is what the backend shows)."""
        return self.learned_id or self.host

    @property
    def hub_key(self) -> str:
        return self.learned_id or self.host

    @property
    def polling(self) -> bool:
        return self.state == POLLING

    def _restore_move(self) -> None:
        """After a restart, start at the address the hub was last found at (if the configuration is unchanged).

        Only with the sweep on: without it a stored move could never be corrected by a search.
        """
        if not (self.locator and self.locator.enabled and self.hub_factory and self.learned_id):
            return
        saved = (self.detector.get(f"host_of:{self.learned_id}") or "").split()
        if len(saved) == 2 and saved[0] == self.configured and saved[1] != self.host:
            self.host, self.client = saved[1], self.hub_factory(saved[1])

    async def _use_address(self, host: str) -> None:
        """Point the runner at another address, closing the old connection."""
        await self.client.close()
        self.host, self.client = host, self.hub_factory(host)

    def _learn(self, hub_id: str) -> None:
        old_key = self.hub_key
        self.learned_id = hub_id
        self.detector.set(f"hub_id:{self.configured}", hub_id)
        if self.host != self.configured:
            self.detector.set(f"host_of:{hub_id}", f"{self.configured} {self.host}")
        self.queue.rekey(old_key, hub_id)

    def hub_payload(self, online: bool) -> dict:
        return {"id": self.hub_id, "host": self.host, "online": online, "firmware": self.firmware}

    def _queue_hub(self, online: bool, now: float, force: bool = False) -> None:
        if self.queue.set_hub(self.hub_key, self.hub_payload(online), force) or force:
            self.hub_status_at = now

    async def step(self, now: float) -> None:
        if self.hub_status_at is not None and now - self.hub_status_at >= self.config.heartbeat_seconds:
            self._queue_hub(self.state != OFFLINE, now, force=True)
            if self.state == OFFLINE:
                log.info("event=offline_heartbeat hub=%s host=%s", self.hub_id, self.host)
        if self.state == OFFLINE and await self._relocate(now):
            return
        if now < self.next_at:
            return
        if self.state == POLLING and self._reboot_due(now):
            await self._reboot(now)
            return
        try:
            if self.state != POLLING:
                await self.client.connect()
            snapshot = await self.client.poll()
            self._check_identity(snapshot)
        except HubError as exc:
            await self._failed(now, exc)
            return
        self._polled(now, snapshot)

    def _check_identity(self, snap: HubSnapshot) -> None:
        """With the sweep on, a hub that is not ours at this address is a failed poll, not a replacement.

        That covers a hub another runner follows (two hubs swapped addresses) and an unknown hub: the
        learned one may only have moved, and the sweep will say. A replacement is adopted only at the
        configured address and only after a sweep did not find the old hub anywhere. Without the sweep
        the answering hub is simply adopted.
        """
        loc = self.locator
        if not (loc and loc.enabled and self.learned_id and snap.hub_id != self.learned_id):
            return
        if snap.hub_id in loc.followed_by_others(self):
            raise HubError("another hub answers at this address")
        if not (self.host == self.configured and self.old_missed):
            raise HubError("a different hub answers at this address")

    async def _relocate(self, now: float) -> bool:
        """Ask for a sweep, later read its result; True when the runner moved (it then reconnects at once)."""
        loc = self.locator
        if not (loc and loc.enabled):
            return False
        if self.awaiting is not None:
            found = loc.result(self.awaiting)
            if found is None:
                if not loc.busy:
                    self.awaiting = None  # the sweep failed; ask again after the interval
                return False
            self.awaiting = None
            pick = loc.pick(self, found)
            self.old_missed = bool(self.learned_id) and not loc.sees(self.learned_id)
            if pick is None or pick.host == self.host:
                return False
            return await self._move(pick, now)
        if now < self.relocate_at:
            return False
        self.relocate_at = now + self.config.relocate_seconds
        self.awaiting = now
        loc.request(now)
        if self.host != self.configured and not any(r.host == self.configured for r in loc.runners if r is not self):
            # The address restored from a stored move may be dead: try the configured one meanwhile.
            await self._use_address(self.configured)
            if self.learned_id:
                self.detector.set(f"host_of:{self.learned_id}", f"{self.configured} {self.configured}")
            self.next_at = min(self.next_at, now)
        return False

    async def _move(self, found, now: float) -> bool:
        old = self.host
        was_learned = self.learned_id
        self._learn(found.hub_id)  # before the address changes, so a claimed hub's queue is re-keyed from the old one
        self.detector.set(f"host_of:{found.hub_id}", f"{self.configured} {found.host}")
        if self.hub_factory:
            await self._use_address(found.host)
        else:
            self.host = found.host
        self.state, self.failures, self.connect_wait, self.next_at = DISCONNECTED, 0, 0, now
        self.old_missed = False
        text = "event=hub_moved hub=%s old=%s new=%s%s"
        args = (found.hub_id, old, found.host, "" if was_learned else " claimed=true")
        (log.info if was_learned else log.warning)(text, *args)  # a claim is a decision worth a warning
        return True

    def _polled(self, now: float, snap: HubSnapshot) -> None:
        if self.state != POLLING:
            log.info("event=hub_online hub=%s host=%s model=%s firmware=%s sensors=%d was=%s",
                     snap.hub_id, self.host, snap.model, snap.firmware, len(snap.children), self.state)
        self.state, self.failures, self.connect_wait, self.rebooted_at = POLLING, 0, 0, None
        self.old_missed, self.awaiting = False, None
        self.next_at = now + self.config.poll_seconds
        if snap.hub_id != self.learned_id:
            if self.learned_id:
                log.info("event=hub_replaced old=%s new=%s host=%s", self.learned_id, snap.hub_id, self.host)
            self._learn(snap.hub_id)
        self.firmware = snap.firmware
        self._queue_hub(True, now)
        measured_at, readings = iso(now), []
        for child in snap.children:
            if self._offline(snap.hub_id, child):
                continue  # the hub only has cached values for a sensor it cannot hear
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
        self.queue.put(self.hub_key, readings, now)  # commits the detector's records with the readings
        if readings:
            log.info("event=readings hub=%s sensors=%d changes=%d heartbeats=%d", self.hub_id, len(snap.children),
                     sum(r["kind"] == "change" for r in readings), sum(r["kind"] == "heartbeat" for r in readings))

    def _offline(self, hub_id: str, child) -> bool:
        """True when the hub reports the sensor offline; logs each transition once."""
        if child.online is False:
            if child.external_id not in self.offline_sensors:
                self.offline_sensors.add(child.external_id)
                log.info("event=sensor_offline hub=%s sensor=%s name=%r", hub_id, child.external_id, child.name)
            return True
        if child.external_id in self.offline_sensors:
            self.offline_sensors.discard(child.external_id)
            log.info("event=sensor_online hub=%s sensor=%s name=%r", hub_id, child.external_id, child.name)
        return False

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
        minute = str(int(now // 60))
        done = (self.detector.get(f"reboot:{self.hub_key}"), self.detector.get(f"reboot:{self.host}"))
        return bool(cron and cron.matches(now) and minute not in done)

    async def _reboot(self, now: float) -> None:
        self.detector.set(f"reboot:{self.hub_key}", str(int(now // 60)))  # first, so a crash cannot repeat it
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
        return {"hub_id": self.hub_id, "host": self.host, "state": self.state, "failures": self.failures, "last_error": self.last_error}


class Bridge:
    def __init__(self, runners: list[HubRunner], delivery: Delivery, queue: Queue, clock=time.time,
                 health_path: str | None = None, locator: Locator | None = None):
        self.runners, self.delivery, self.queue, self.clock = runners, delivery, queue, clock
        self.locator = locator
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
                "delivery": self.delivery.last_status, "hubs": {r.configured: r.status() for r in self.runners}})

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
        if self.locator:
            await self.locator.close()
        for runner in self.runners:
            await runner.client.close()
