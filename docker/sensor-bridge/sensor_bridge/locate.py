# SPDX-License-Identifier: GPL-3.0-or-later
"""Finds a hub whose IP address changed, by a unicast sweep of the configured networks.

Broadcast discovery does not leave a Docker network or cross WSL2 NAT; a TCP connect to a
hub's port 443 does. The sweep connects to every address, logs in to the ones that answer
(skipping addresses of hubs that are polling fine) and reads what the device is. It runs as
a background task owned by the Locator, so no runner waits for it: runners ask with
request() and read the result with result() on their next step. The result is kept for
CACHE_SECONDS so that several hubs that moved together share one sweep, and only one sweep
runs at a time. A hub is matched by its id; a runner that never reached its hub may claim a
hub of the H100/H200 family that logs in with the account, reports at least one temperature
or humidity sensor and that no other runner follows. An address whose login was refused is
skipped for the next FAIL_SKIP_SWEEPS sweeps so that a device of another account is not
locked out. Credentials are never logged: a failed login on a non-hub address is a debug line.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
from dataclasses import dataclass

from .hub import HubError, Identity

log = logging.getLogger("sensor_bridge")

PORT = 443
TCP_TIMEOUT = 1.0
TCP_CONCURRENCY = 32
LOGIN_CONCURRENCY = 8
CACHE_SECONDS = 60
FAIL_SKIP_SWEEPS = 6  # sweeps that skip an address whose login was refused


@dataclass(frozen=True)
class Found:
    host: str
    hub_id: str


async def tcp_open(host: str, port: int = PORT, timeout: float = TCP_TIMEOUT) -> bool:
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout)
    except (OSError, TimeoutError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except OSError:
        pass
    return True


def addresses(networks) -> list[str]:
    """Every host address of the networks, once each, in address order."""
    seen: dict[ipaddress.IPv4Address, None] = {}
    for net in networks:
        for ip in ipaddress.IPv4Network(net).hosts():
            seen[ip] = None
    return [str(ip) for ip in sorted(seen)]


class Locator:
    """Also the registry of runners, so a runner can tell which hub ids the others follow."""

    def __init__(self, networks=(), probe=None, tcp=tcp_open):
        self.networks, self.probe, self.tcp = tuple(networks), probe, tcp
        self.runners: list = []
        self.task: asyncio.Task | None = None
        self.found: dict[str, Identity] = {}  # host -> the hubs seen by the last sweep
        self.found_at: float | None = None
        self.skip: dict[str, int] = {}  # host -> sweeps left to skip it (its login was refused)

    @property
    def enabled(self) -> bool:
        return bool(self.networks and self.probe)

    @property
    def busy(self) -> bool:
        return self.task is not None and not self.task.done()

    def followed_by_others(self, runner) -> set[str]:
        return {r.learned_id for r in self.runners if r is not runner and r.learned_id}

    def request(self, now: float) -> None:
        """Start a sweep in the background unless one runs or a recent result can serve."""
        if not self.enabled or self.busy:
            return
        if self.found_at is not None and now - self.found_at < CACHE_SECONDS:
            return
        self.task = asyncio.ensure_future(self._sweep(now))

    def result(self, since: float) -> dict[str, Identity] | None:
        """The hubs seen by a sweep that finished for a request made at `since`, else None."""
        if self.found_at is None or self.found_at < since - CACHE_SECONDS or self.busy:
            return None
        return self.found

    def sees(self, hub_id: str) -> bool:
        return any(i.hub_id == hub_id for i in self.found.values())

    def pick(self, runner, found: dict[str, Identity]) -> Found | None:
        """Where the runner's hub is now (or, for a never-reached runner, a hub it may claim)."""
        others = [r for r in self.runners if r is not runner]
        if runner.learned_id:
            busy_hosts = {r.host for r in others if r.polling}  # never an address a runner is polling at
            hosts = [h for h, i in found.items() if i.hub_id == runner.learned_id and h not in busy_hosts]
            if not hosts:
                return None
            return Found(runner.host if runner.host in hosts else hosts[0], runner.learned_id)
        taken_ids, taken_hosts = self.followed_by_others(runner), {r.host for r in others}
        for host, ident in found.items():
            if ident.sensors >= 1 and ident.hub_id not in taken_ids and host not in taken_hosts:
                return Found(host, ident.hub_id)
        return None

    async def wait(self) -> None:
        """Until the running sweep (if any) is done."""
        if self.busy:
            await asyncio.wait([self.task])

    async def close(self) -> None:
        if self.busy:
            self.task.cancel()
            await asyncio.wait([self.task])

    async def _sweep(self, now: float) -> None:
        try:
            await self._run(now)
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 - a failed sweep gives no result; runners ask again later
            log.error("event=sweep_failed error=%s", type(exc).__name__)

    async def _run(self, now: float) -> None:
        busy_hosts, skipped = {r.host for r in self.runners if r.polling}, set(self.skip)
        hosts = [h for h in addresses(self.networks) if h not in busy_hosts and h not in skipped]
        tcp_gate, login_gate = asyncio.Semaphore(TCP_CONCURRENCY), asyncio.Semaphore(LOGIN_CONCURRENCY)
        refused: set[str] = set()

        async def reachable(host: str) -> bool:
            async with tcp_gate:
                try:
                    return bool(await self.tcp(host))
                except Exception:  # noqa: BLE001 - an address that cannot be tested is skipped
                    return False

        async def identify(host: str) -> tuple[str, Identity] | None:
            async with login_gate:
                try:
                    ident = await self.probe(host)
                except HubError as exc:
                    if exc.login:
                        refused.add(host)
                    log.debug("event=sweep_probe_failed host=%s error=%s", host, exc)
                    return None
                except Exception as exc:  # noqa: BLE001
                    log.debug("event=sweep_probe_failed host=%s error=%s", host, type(exc).__name__)
                    return None
                if not ident.is_hub:
                    log.debug("event=sweep_not_a_hub host=%s model=%s", host, ident.model)
                    return None
                return host, ident

        flags = await asyncio.gather(*(reachable(h) for h in hosts))
        open_hosts = [h for h, ok in zip(hosts, flags) if ok]
        results = await asyncio.gather(*(identify(h) for h in open_hosts))
        for host in skipped:
            self.skip[host] -= 1
            if self.skip[host] <= 0:
                del self.skip[host]
        for host in refused:
            self.skip[host] = FAIL_SKIP_SWEEPS
        self.found = dict(r for r in results if r)
        self.found_at = now
        log.info("event=sweep networks=%d scanned=%d open=%d hubs=%d login_refused=%d", len(self.networks),
                 len(hosts), len(open_hosts), len(self.found), len(refused))
