# SPDX-License-Identifier: GPL-3.0-or-later
"""Finds a hub whose IP address changed, by a unicast sweep of the configured networks.

Broadcast discovery does not leave a Docker network or cross WSL2 NAT; a TCP connect to a
hub's port 443 does. The sweep connects to every address, logs in to the ones that answer
(skipping addresses of hubs that are polling fine) and reads the hub id. The result is
kept for CACHE_SECONDS so that several hubs that moved together share one sweep, and only
one sweep runs at a time. A hub is matched by its id; a runner that never reached its hub
may claim a hub that logs in with the account and that no other runner follows.
Credentials are never logged: a failed login on a non-hub address is a debug line.
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
from dataclasses import dataclass

from .hub import HubError

log = logging.getLogger("sensor_bridge")

PORT = 443
TCP_TIMEOUT = 1.0
TCP_CONCURRENCY = 32
LOGIN_CONCURRENCY = 8
CACHE_SECONDS = 60


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
        self.busy = False
        self.found: dict[str, str] = {}  # host -> hub id, from the last sweep
        self.found_at: float | None = None

    @property
    def enabled(self) -> bool:
        return bool(self.networks and self.probe)

    def followed_by_others(self, runner) -> set[str]:
        return {r.learned_id for r in self.runners if r is not runner and r.learned_id}

    async def find(self, runner, now: float) -> Found | None:
        """Where the runner's hub is now (or, for a never-reached runner, a hub it may claim)."""
        if not self.enabled or self.busy:
            return None
        if self.found_at is None or now - self.found_at >= CACHE_SECONDS:
            await self._sweep(now)
        return self._pick(runner)

    def _pick(self, runner) -> Found | None:
        if runner.learned_id:
            hosts = [h for h, i in self.found.items() if i == runner.learned_id]
            if not hosts:
                return None
            return Found(runner.host if runner.host in hosts else hosts[0], runner.learned_id)
        taken_ids = self.followed_by_others(runner)
        taken_hosts = {r.host for r in self.runners if r is not runner}
        for host, hub_id in self.found.items():
            if hub_id not in taken_ids and host not in taken_hosts:
                return Found(host, hub_id)
        return None

    async def _sweep(self, now: float) -> None:
        self.busy = True
        try:
            skip = {r.host for r in self.runners if r.polling}
            hosts = [h for h in addresses(self.networks) if h not in skip]
            tcp_gate, login_gate = asyncio.Semaphore(TCP_CONCURRENCY), asyncio.Semaphore(LOGIN_CONCURRENCY)

            async def reachable(host: str) -> bool:
                async with tcp_gate:
                    try:
                        return bool(await self.tcp(host))
                    except Exception:  # noqa: BLE001 - an address that cannot be tested is skipped
                        return False

            async def identify(host: str) -> tuple[str, str] | None:
                async with login_gate:
                    try:
                        return host, await self.probe(host)
                    except HubError as exc:
                        log.debug("event=sweep_probe_failed host=%s error=%s", host, exc)
                    except Exception as exc:  # noqa: BLE001
                        log.debug("event=sweep_probe_failed host=%s error=%s", host, type(exc).__name__)
                    return None

            flags = await asyncio.gather(*(reachable(h) for h in hosts))
            open_hosts = [h for h, ok in zip(hosts, flags) if ok]
            results = await asyncio.gather(*(identify(h) for h in open_hosts))
            self.found = dict(r for r in results if r)
            self.found_at = now
            log.info("event=sweep networks=%d scanned=%d open=%d hubs=%d", len(self.networks), len(hosts),
                     len(open_hosts), len(self.found))
        finally:
            self.busy = False
